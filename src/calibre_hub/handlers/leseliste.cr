require "json"
require "file_utils"
require "../calibre"
require "../library_db"

module CalibreHub
  # Handler: mirrors the synced reading lists (lists.cr) into a folder,
  # e.g. one synced to an e-reader, one subfolder per list:
  # <target>/<list name>/<Author - Series NN - Title>.epub. A book in two
  # synced lists is in both folders. Preferred formats in order (default
  # epub, then pdf); without them a convertible format is converted to the
  # first one and added to calibre. Files of books that left a list (or of
  # lists no longer synced) are removed; a renamed list renames its folder.
  #
  # Reads the hub's state DB (lists) and metadata.db (paths) read-only;
  # writes only via calibre-server. Environment: LESELISTE_TARGET,
  # LESELISTE_FORMATS, CALIBRE_HUB_STATE_DB, CALIBRE_HUB_LIBRARY and the
  # calibre-server settings of the hub (for adding converted formats).
  module Leseliste
    CONVERTIBLE = %w(AZW3 MOBI AZW KEPUB FB2 LIT DOCX RTF HTMLZ TXT)
    KEEP        = {".stfolder", ".stignore", ".stversions"}
    RELEVANT    = %w(title authors authorSort series seriesIndex formats)

    record Wanted, rel : String, src : String
    record SyncedList, id : Int64, name : String, books : Array(Int64)

    # synced: the books in synced lists
    def self.relevant?(event : JSON::Any?, synced : Set(Int64)) : Bool
      return true unless event
      case event["type"]?.try(&.as_s?)
      when "list"
        # a synced list, or one that was synced before the change
        {event["list"]?, event["previous"]?}.any? { |l| l.try(&.["sync"]?.try(&.as_bool?)) }
      when "changed"
        keys = event["changes"]?.try(&.as_h.keys) || [] of String
        keys.any? { |k| RELEVANT.includes?(k) } && synced.includes?(event["bookId"].as_i64)
      when "added", "deleted"
        synced.includes?(event["bookId"].as_i64)
      else
        true
      end
    end

    def self.run(env = ENV, input : IO = STDIN) : Int32
      target = env["LESELISTE_TARGET"]? || abort "LESELISTE_TARGET is not set"
      library = env["CALIBRE_HUB_LIBRARY"]? || abort "CALIBRE_HUB_LIBRARY is not set"
      state_path = env["CALIBRE_HUB_STATE_DB"]? || abort "CALIBRE_HUB_STATE_DB is not set"
      formats = (env["LESELISTE_FORMATS"]? || "epub,pdf").split(',', remove_empty: true).map(&.strip.upcase)

      raw = input.gets_to_end.strip
      event = raw.empty? ? nil : JSON.parse(raw)

      state = LibraryDB.open_read_only(state_path)
      lists = begin
        synced_lists(state)
      ensure
        state.close
      end
      # before the tag became a list nothing is touched
      unless lists
        puts "lists not migrated yet, skipped"
        return 0
      end
      return 0 unless relevant?(event, lists.flat_map(&.books).to_set)
      rename(event, target)

      db = LibraryDB.open_read_only(File.join(library, "metadata.db"))
      Dir.mktmpdir_compat do |tmp|
        mirror(wanted(db, library, lists, formats, tmp, env), target)
      end
      db.close
      0
    end

    # nil until the lists exist (migration done)
    def self.synced_lists(state) : Array(SyncedList)?
      return nil if state.query_one?("select value from meta where key = 'lists_migrated'", as: String).nil?
      lists = [] of SyncedList
      state.query_each("select id, name from lists where sync = 1 order by id") do |rs|
        lists << SyncedList.new(rs.read(Int64), rs.read(String), [] of Int64)
      end
      lists.map do |l|
        ids = [] of Int64
        state.query_each("select book_id from list_items where list_id = ? order by book_id", l.id) { |rs| ids << rs.read(Int64) }
        SyncedList.new(l.id, l.name, ids)
      end
    rescue ex : SQLite3::Exception
      # no list tables yet
      nil
    end

    # Folder names, unique among the lists
    def self.folders(lists : Array(SyncedList)) : Hash(Int64, String)
      used = Set(String).new
      lists.to_h do |l|
        name = clean(l.name, 60)
        name = "#{name} (#{l.id})" if used.includes?(name.downcase)
        used << name.downcase
        {l.id, name}
      end
    end

    # A renamed synced list keeps its files: the folder moves along
    def self.rename(event : JSON::Any?, target : String)
      return unless event && event["type"]? == "list" && event["action"]? == "updated"
      before = event["previous"]?.try(&.["name"]?).try(&.as_s?)
      after = event["list"]?.try(&.["name"]?).try(&.as_s?)
      return unless before && after && before != after
      return unless event["list"]["sync"]?.try(&.as_bool?)
      from = File.join(target, clean(before, 60))
      to = File.join(target, clean(after, 60))
      return if from == to || !Dir.exists?(from) || File.exists?(to)
      File.rename(from, to)
      puts "#{clean(before, 60)} -> #{clean(after, 60)}"
    rescue ex : File::Error
      puts "renaming the folder of #{before} failed: #{ex.message}"
    end

    def self.wanted(db, library, lists : Array(SyncedList), formats, tmp, env) : Array(Wanted)
      folders = folders(lists)
      ids = lists.flat_map(&.books).uniq
      rows = {} of Int64 => {String, String, Float64, String?, String?}
      ids.each_slice(500) do |slice|
        db.query_each(<<-SQL) do |rs|
          select b.id, b.title, b.path, b.series_index,
                 (select s.name from series s join books_series_link l on l.series = s.id where l.book = b.id),
                 (select a.sort from authors a join books_authors_link l on l.author = a.id
                   where l.book = b.id order by l.id limit 1)
            from books b
           where b.id in (#{slice.join(",")})
          SQL
          rows[rs.read(Int64)] = {rs.read(String), rs.read(String), rs.read(Float64), rs.read(String?), rs.read(String?)}
        end
      end

      # one source file and name per book, also when it is in two lists
      files_of = {} of Int64 => {String, String}?
      result = {} of String => Wanted
      lists.each do |list|
        list.books.each do |id|
          # deleted from the library meanwhile
          row = rows[id]? || next
          source = files_of.fetch(id) { files_of[id] = source(db, library, id, row, formats, tmp, env) }
          next unless source
          src, name = source
          folder = folders[list.id]
          rel = File.join(folder, name)
          rel = File.join(folder, "#{File.basename(name, File.extname(name))} (#{id})#{File.extname(name)}") if result.has_key?(rel)
          result[rel] = Wanted.new(rel, src)
        end
      end
      result.values
    end

    # {source file, file name} or nil when there is nothing to copy
    private def self.source(db, library, id, row, formats, tmp, env) : {String, String}?
      title, path, idx, series, author = row
      files = {} of String => String
      db.query_each("select format, name from data where book = ?", id) do |rs|
        fmt = rs.read(String).upcase
        files[fmt] = File.join(library, path, "#{rs.read(String)}.#{fmt.downcase}")
      end
      fmt = formats.find { |f| files.has_key?(f) }
      src = fmt.try { |f| files[f] }
      unless src
        from = CONVERTIBLE.find { |f| files.has_key?(f) }
        if from.nil?
          puts "##{id} #{title}: no #{formats.join("/")} and nothing to convert (#{files.keys.join(", ")})"
          return nil
        end
        fmt = formats.first
        begin
          src = convert(id, files[from], fmt, tmp, env)
          puts "##{id} #{title}: #{from} -> #{fmt}, added to calibre"
        rescue ex
          puts "##{id} #{title}: #{from} -> #{fmt} failed: #{ex.message}"
          return nil
        end
      end
      name = series ? "#{author || "Unknown"} - #{series} #{series_number(idx)} - #{title}" : "#{author || "Unknown"} - #{title}"
      {src, "#{clean(name)}.#{fmt.not_nil!.downcase}"}
    end

    def self.mirror(wanted : Array(Wanted), target : String)
      Dir.mkdir_p(target)
      wanted.each do |w|
        dst = File.join(target, w.rel)
        src_info = File.info(w.src)
        if (d = File.info?(dst)) && d.size == src_info.size && d.modification_time >= src_info.modification_time
          next
        end
        Dir.mkdir_p(File.dirname(dst))
        # Syncthing ignores .syncthing.*.tmp, so it never sees half a file
        tmp = File.join(File.dirname(dst), ".syncthing.#{File.basename(dst)}.tmp")
        File.copy(w.src, tmp)
        File.utime(src_info.modification_time, src_info.modification_time, tmp)
        File.rename(tmp, dst)
        puts "+ #{w.rel}"
      end

      keep = wanted.map { |w| File.join(target, w.rel) }.to_set
      prune(target, target, keep)
    end

    def self.series_number(idx : Float64) : String
      idx == idx.floor ? "%02d" % idx.to_i : idx.to_s
    end

    def self.clean(s : String, limit = 120) : String
      c = s.gsub(/[\\\/:*?"<>|\x00-\x1f]/, "_").strip.rstrip('.')
      c = c[0, limit].strip
      c.empty? ? "_" : c
    end

    private def self.prune(dir : String, root : String, keep : Set(String))
      Dir.each_child(dir) do |name|
        next if KEEP.includes?(name)
        path = File.join(dir, name)
        if File.directory?(path)
          prune(path, root, keep)
          Dir.delete(path) if Dir.empty?(path)
        elsif !keep.includes?(path)
          File.delete(path)
          puts "- #{path.lchop(root).lchop('/')}"
        end
      end
    end

    private def self.convert(id : Int64, src : String, fmt : String, tmp : String, env) : String
      dst = File.join(tmp, "#{id}.#{fmt.downcase}")
      log = IO::Memory.new
      status = Process.run("ebook-convert", [src, dst], output: log, error: log)
      raise (log.to_s.lines.last? || "ebook-convert exit #{status.exit_code}") unless status.success?
      calibre = Calibre.new(env["CALIBRE_HUB_CALIBRE_URL"], env["CALIBRE_HUB_CALIBRE_USER"],
        File.read(env["CALIBRE_HUB_CALIBRE_PASSWORD_FILE"]).sub(/\n+\z/, ""), env["CALIBRE_HUB_LIBRARY_ID"]?)
      calibre.add_format(id, dst, fmt.downcase)
      dst
    end
  end
end

class Dir
  # temporary directory, removed afterwards
  def self.mktmpdir_compat(&)
    path = File.join(Dir.tempdir, "calibre-hub-#{Random::Secure.hex(6)}")
    Dir.mkdir(path)
    begin
      yield path
    ensure
      FileUtils.rm_rf(path)
    end
  end
end
