require "http"
require "./calibre"
require "./detector"
require "./edit"
require "./api"

module CalibreHub
  # Write side of the API. Every write goes to calibre-server and is then
  # run through the detector, so handlers see it right away.
  class Writer
    class NotFound < Exception
    end

    class Conflict < Exception
      getter book : Book

      def initialize(@book)
        super("changed in the meantime")
      end
    end

    class Duplicates < Exception
      getter books : Array(Book)
      getter titles : Array(String)

      def initialize(@books, @titles)
        super("duplicate")
      end
    end

    class Unsupported < Exception
    end

    class TooLarge < Exception
    end

    MAX_UPLOAD = 200_i64 * 1024 * 1024
    # calibre's BOOK_EXTENSIONS (9.14); recipes are refused by calibre anyway
    EXTENSIONS = %w(lrf rar zip rtf lit txt txtz text htm xhtm html htmlz xhtml pdf pdb updb pdr prc
      mobi azw doc epub fb2 fbz djv djvu lrx cbr cb7 cbz cbc oebzip rb imp odt chm tpz azw1 pml pmlz
      mbp tan snb xps oxps azw4 book zbf pobi docx docm md textile markdown ibook ibooks iba azw3 ps
      kepub kfx kpf)

    record Upload, file : String, filename : String, tags : Array(String), kategorie : String?,
      force : Bool, add_format_to : Int64?

    def initialize(@calibre : Calibre, @detector : Detector?, @wake : Channel(Nil)?,
                   @category_column : String?)
    end

    def update(id : Int64, body : Hash(String, JSON::Any)) : Book
      current = @calibre.book(id) || raise NotFound.new
      raise Conflict.new(current) if Edit.conflict?(body, current)
      changes = Edit.changes(body, current, @category_column)
      @calibre.set_fields(id, changes) unless changes.empty?
      written([id])
      @calibre.book(id) || raise NotFound.new
    end

    # Reads a multipart upload into a temp file; the caller deletes it
    def self.read_upload(request : HTTP::Request, dir = Dir.tempdir) : Upload
      if (len = request.headers["Content-Length"]?.try(&.to_i64?)) && len > MAX_UPLOAD + 1024 * 1024
        raise TooLarge.new
      end
      file = nil
      filename = ""
      tags = [] of String
      kategorie = nil
      force = false
      add_to = nil
      HTTP::FormData.parse(request) do |part|
        case part.name
        when "file"
          raise Edit::Invalid.new("file", "only one file per request") if file
          filename = File.basename(part.filename.presence || raise Edit::Invalid.new("file", "file name missing"))
          tmp = File.tempfile("upload", File.extname(filename), dir: dir)
          file = tmp.path
          copied = IO.copy(part.body, tmp, MAX_UPLOAD + 1)
          tmp.close
          raise TooLarge.new if copied > MAX_UPLOAD
        when "tags"
          part.body.gets_to_end.strip.presence.try { |t| tags << t }
        when "kategorie"
          kategorie = part.body.gets_to_end.strip.presence
        when "force"
          force = {"1", "true", "yes"}.includes?(part.body.gets_to_end.strip)
        when "addFormatTo"
          add_to = part.body.gets_to_end.strip.to_i64? || raise Edit::Invalid.new("addFormatTo", "book id expected")
        else
          raise Edit::Invalid.new(part.name, "unknown field")
        end
      end
      Upload.new(file || raise(Edit::Invalid.new("file", "file missing")), filename, tags.uniq, kategorie, force, add_to)
    rescue ex : HTTP::FormData::Error | IO::Error
      file.try { |f| File.delete?(f) }
      raise Edit::Invalid.new("file", "multipart/form-data expected: #{ex.message}")
    rescue ex
      file.try { |f| File.delete?(f) }
      raise ex
    end

    def self.extension(filename : String) : String
      ext = File.extname(filename).lchop('.').downcase
      raise Unsupported.new("unsupported format: #{ext.presence || "none"}") unless EXTENSIONS.includes?(ext)
      ext
    end

    # {book, created}
    def upload(u : Upload) : {Book, Bool}
      ext = Writer.extension(u.filename)
      if id = u.add_format_to
        @calibre.book(id) || raise NotFound.new
        @calibre.add_format(id, u.file, ext)
        written([id])
        return {@calibre.book(id) || raise(NotFound.new), false}
      end

      raise Edit::Invalid.new("kategorie", "no category column configured") if u.kategorie && !@category_column
      added = @calibre.add_book(u.file, u.filename, duplicates: u.force)
      id = added.book_id || raise Duplicates.new(duplicate_books(added.duplicates), added.duplicates.map(&.to_s))
      # embedded tags are dropped, like in the inbox
      changes = {"tags" => JSON.parse(u.tags.to_json)}
      if (k = u.kategorie) && (col = @category_column)
        changes["##{col}"] = JSON::Any.new(k)
      end
      @calibre.set_fields(id, changes)
      written([id])
      {@calibre.book(id) || raise(NotFound.new), true}
    end

    # calibre only names title and authors of the books it matched
    def duplicate_books(dups : Array(Calibre::Duplicate)) : Array(Book)
      ids = dups.flat_map do |d|
        query = %(title:"=#{Api.escape(d.title)}")
        query += d.authors.map { |a| %( and authors:"=#{Api.escape(a)}") }.join
        @calibre.search(query, "id", true, 0, 20).ids
      end
      @calibre.books(ids.uniq, Calibre::DETAIL_FIELDS)
    rescue ex : Calibre::Error
      STDERR.puts "duplicate lookup failed: #{ex.message}"
      [] of Book
    end

    private def written(ids : Array(Int64))
      if d = @detector
        d.touch(ids).each { |e| puts e.to_json }
      end
      if w = @wake
        select
        when w.send(nil)
        else
        end
      end
    end
  end
end
