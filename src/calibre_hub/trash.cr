require "db"
require "json"
require "xml"
require "./calibre"
require "./command"
require "./covers"
require "./writer"

module CalibreHub
  # calibre's trash: deleted books move to <library>/.caltrash/b/<id> with
  # their files, cover.jpg and metadata.opf. calibre-server can move books
  # there but has no command to list or restore them, so the hub reads the
  # folder (read-only) and restores by adding the book again through
  # calibre-server: metadata from metadata.opf (parsed by calibre itself, so
  # custom columns survive), then the files and the cover. The restored book
  # gets a new id. The hub can't write the library, so the folder stays in
  # the trash; restored entries are remembered in the state db and hidden.
  # calibre's own expiry is disabled by the NixOS module (init.sh); entries
  # only go away when someone empties the trash in calibre.
  class Trash
    DIR  = ".caltrash"
    SKIP = {"metadata.opf", "cover.jpg"}

    # metadata.opf -> calibre's JSON serialization of a Metadata object
    alias MetadataReader = Proc(String, JSON::Any)

    record Entry, id : Int64, title : String, authors : Array(String), formats : Array(String),
      deleted_at : Time, dir : String do
      def to_json(json : JSON::Builder)
        json.object do
          json.field "id", id
          json.field "title", title
          json.field "authors", authors
          json.field "formats", formats
          json.field "deletedAt", deleted_at.to_rfc3339
        end
      end

      # format file paths with their extension
      def files : Array({String, String})
        Dir.children(dir).sort.compact_map do |name|
          next if SKIP.includes?(name)
          path = File.join(dir, name)
          ext = File.extname(name).lchop('.').downcase
          {path, ext} if File.file?(path) && !ext.empty?
        end
      end
    end

    SCRIPT = <<-PY
      import os, sys
      from calibre.db.restore import read_opf
      from calibre.utils.serialize import json_dumps
      mi = read_opf(os.environ['BOOK_DIR'], read_annotations=False)[0]
      mi.cover, mi.cover_data = None, (None, None)
      sys.stdout.buffer.write(json_dumps(mi))
      PY

    def self.read_metadata(dir : String) : JSON::Any
      output = IO::Memory.new
      error = IO::Memory.new
      status = Command.run("calibre-debug", ["-c", SCRIPT], 2.minutes, env: {"BOOK_DIR" => dir, "QT_QPA_PLATFORM" => "offscreen"},
        output: output, error: error)
      raise Calibre::Error.new("reading metadata.opf failed: #{error.to_s.strip.lines.last?}") unless status.success?
      JSON.parse(output.to_s)
    rescue ex : Command::Timeout
      raise Calibre::Error.new("reading metadata.opf failed: #{ex.message}")
    end

    # called with the trash id and the new id after a restore (lists)
    property on_restore : Proc(Int64, Int64, Nil)?

    def initialize(@calibre : Calibre, @writer : Writer, @library : String?, @db : DB::Database,
                   @read_metadata : MetadataReader = ->Trash.read_metadata(String))
      @mutex = Mutex.new
      @db.exec <<-SQL
        create table if not exists trash_restored (
          trash_id integer not null,
          deleted_at integer not null,
          book_id integer not null,
          restored_at integer not null,
          primary key (trash_id, deleted_at)
        )
        SQL
    end

    # Deleted books, newest first
    def list : Array(Entry)
      base = @library.try { |l| File.join(l, DIR, "b") }
      return [] of Entry unless base && Dir.exists?(base)
      restored = Set({Int64, Int64}).new
      @db.query_each("select trash_id, deleted_at from trash_restored") { |rs| restored << {rs.read(Int64), rs.read(Int64)} }
      Dir.children(base).compact_map do |name|
        id = name.to_i64? || next
        entry(id, File.join(base, name))
      end.reject { |e| restored.includes?({e.id, e.deleted_at.to_unix}) }.sort_by! { |e| {-e.deleted_at.to_unix, -e.id} }
    end

    def []?(id : Int64) : Entry?
      list.find { |e| e.id == id }
    end

    # Adds the book again; returns the new book
    def restore(id : Int64) : Book
      restore_with_warning(id)[0]
    end

    # The new book, and what went wrong after it was back (it is, but e.g.
    # not in its lists again)
    def restore_with_warning(id : Int64) : {Book, String?}
      @mutex.synchronize do
        entry = self[id]? || raise Writer::NotFound.new
        book_id = @calibre.add_empty(@read_metadata.call(entry.dir))
        begin
          entry.files.each { |file, ext| @calibre.add_format(book_id, file, ext) }
          cover = File.join(entry.dir, "cover.jpg")
          if File.file?(cover)
            data = File.open(cover, &.getb_to_end)
            Covers.image_type(data).try { |type| @calibre.set_cover(book_id, data, type) if {"jpeg", "png"}.includes?(type) }
          end
        rescue ex
          # no half restored book; the entry stays in the trash
          begin
            @calibre.remove([book_id], permanent: true)
          rescue cleanup : Calibre::Error
            STDERR.puts "removing half restored book #{book_id} failed: #{cleanup.message}"
          end
          raise ex
        end
        @db.exec "insert or replace into trash_restored (trash_id, deleted_at, book_id, restored_at) values (?, ?, ?, ?)",
          id, entry.deleted_at.to_unix, book_id, Time.utc.to_unix
        @writer.written([book_id])
        warning = nil
        begin
          @on_restore.try(&.call(id, book_id))
        rescue ex
          STDERR.puts "after restoring #{id} as #{book_id}: #{ex.message}"
          warning = "restored, but not back in its lists: #{ex.message}"
        end
        {@calibre.book(book_id) || raise(Writer::NotFound.new), warning}
      end
    end

    private def entry(id : Int64, dir : String) : Entry?
      opf = File.join(dir, "metadata.opf")
      return nil unless File.file?(opf)
      doc = XML.parse(File.read(opf))
      ns = {"dc" => "http://purl.org/dc/elements/1.1/"}
      title = doc.xpath_node("//dc:title", ns).try(&.content.strip).presence || "?"
      authors = doc.xpath_nodes("//dc:creator", ns).select { |n| (n["role"]? || "aut") == "aut" }.map(&.content.strip).reject(&.empty?)
      formats = Dir.children(dir).compact_map do |name|
        next if SKIP.includes?(name)
        File.extname(name).lchop('.').upcase.presence if File.file?(File.join(dir, name))
      end.uniq.sort
      Entry.new(id, title, authors, formats, File.info(dir).modification_time, dir)
    rescue ex : XML::Error | File::Error
      STDERR.puts "trash entry #{id} unreadable: #{ex.message}"
      nil
    end
  end
end
