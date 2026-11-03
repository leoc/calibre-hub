require "json"
require "file_utils"
require "../calibre"
require "../library_db"
require "../lists"
require "../secret"
require "../command"

module CalibreHub
  # Handler: mirrors the synced reading lists (lists.cr) into a folder,
  # e.g. one synced to an e-reader, one subfolder per list:
  # <target>/<list name>/<Author - Series NN - Title>.epub. Nested lists
  # nest their folders (<target>/Urlaub/2026/...), a synced list takes its
  # sublists along. A book in two synced lists is in both folders. Preferred
  # formats in order (default epub, then pdf); without them a convertible
  # format is converted to the first one and added to calibre. Files of
  # books that left a list (or of lists no longer synced) are removed; a
  # renamed list renames its folder (with its sublists' folders inside).
  #
  # Only files the handler copied itself are ever removed: it records them
  # in <target>/.calibre-hub-files (one path per line, relative to the
  # target). Everything else in the folder stays, above all what the
  # e-reader writes next to the books, such as KOReader's "<book>.sdr"
  # folders with progress, highlights and notes: when a book leaves the
  # list its sidecar stays where it is (and finds the book again when it
  # comes back), and so does the list's folder while anything else is in
  # it. A file the record doesn't know (put there by hand, or from before
  # the record existed) is never touched. The record lives in the target,
  # not in the hub's state DB, which the handler only reads, and so it
  # never claims files of another target.
  #
  # Reads the hub's state DB (lists) and metadata.db (paths) read-only;
  # writes only via calibre-server. Environment: LESELISTE_TARGET,
  # LESELISTE_FORMATS, CALIBRE_HUB_STATE_DB, CALIBRE_HUB_LIBRARY and the
  # calibre-server settings of the hub (for adding converted formats).
  module Leseliste
    CONVERTIBLE = %w(AZW3 MOBI AZW KEPUB FB2 LIT DOCX RTF HTMLZ TXT)
    # the files the handler copied, relative to the target
    MANIFEST = ".calibre-hub-files"
    # below the dispatcher's handler timeout, which doesn't reach the
    # handler's own child processes
    CONVERT_TIMEOUT = 5.minutes
    RELEVANT = %w(title authors authorSort series seriesIndex formats)

    record Wanted, rel : String, src : String
    # own: synced itself, not only as a sublist of a synced list
    record SyncedList, id : Int64, name : String, books : Array(Int64), owner : String = "", own : Bool = true

    # synced: the books in synced lists; lists: the synced lists
    def self.relevant?(event : JSON::Any?, synced : Set(Int64), lists = [] of SyncedList) : Bool
      return true unless event
      case event["type"]?.try(&.as_s?)
      when "list"
        before_after = {event["list"]?, event["previous"]?}
        # a synced list, or one that was synced before the change
        return true if before_after.any? { |l| l.try(&.["sync"]?.try(&.as_bool?)) }
        # a sublist of a synced list, now or before it was renamed or deleted
        return true if (id = event["listId"]?.try(&.as_i64?)) && lists.any? { |l| l.id == id }
        before_after.any? do |l|
          name = l.try(&.["name"]?.try(&.as_s?))
          owner = l.try(&.["owner"]?.try(&.as_s?))
          name && lists.any? { |r| r.own && r.owner == owner && Lists.below?(r.name, name) }
        end
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
      return 0 unless relevant?(event, lists.flat_map(&.books).to_set, lists)
      rename(event, target, lists)

      db = LibraryDB.open_read_only(File.join(library, "metadata.db"))
      with_tmpdir do |tmp|
        mirror(wanted(db, library, lists, formats, tmp, env), target)
      end
      db.close
      0
    end

    # The synced lists and the sublists of synced lists (same owner), no
    # magic shelves (their books come from a search, not the list); nil
    # until the lists exist (migration done)
    def self.synced_lists(state) : Array(SyncedList)?
      return nil if state.query_one?("select value from meta where key = 'lists_migrated'", as: String).nil?
      all = [] of SyncedList
      state.query_each("select id, name, owner, sync from lists where rule is null order by id") do |rs|
        all << SyncedList.new(rs.read(Int64), rs.read(String), [] of Int64, rs.read(String), rs.read(Int64) == 1)
      end
      roots = all.select(&.own)
      all.select { |l| l.own || roots.any? { |r| r.owner == l.owner && Lists.below?(r.name, l.name) } }.map do |l|
        ids = [] of Int64
        state.query_each("select book_id from list_items where list_id = ? order by book_id", l.id) { |rs| ids << rs.read(Int64) }
        l.copy_with(books: ids)
      end
    rescue ex : SQLite3::Exception
      # no list tables yet
      nil
    end

    # "Urlaub/2026" -> "Urlaub/2026", each level cleaned for file systems
    def self.folder(name : String) : String
      levels = Lists.levels(name).map { |s| clean(s, 60) }
      levels.empty? ? "_" : levels.join('/')
    end

    # Folder paths, unique among the lists
    def self.folders(lists : Array(SyncedList)) : Hash(Int64, String)
      used = Set(String).new
      lists.to_h do |l|
        name = folder(l.name)
        name = "#{name} (#{l.id})" if used.includes?(name.downcase)
        used << name.downcase
        {l.id, name}
      end
    end

    # A renamed synced list keeps its files: the folder moves along, with
    # the folders of its sublists inside. Their own rename events find the
    # old folder gone then.
    def self.rename(event : JSON::Any?, target : String, lists = [] of SyncedList)
      return unless event && event["type"]? == "list" && event["action"]? == "updated"
      before = event["previous"]?.try(&.["name"]?).try(&.as_s?)
      after = event["list"]?.try(&.["name"]?).try(&.as_s?)
      return unless before && after && before != after
      id = event["listId"]?.try(&.as_i64?)
      return unless event["list"]["sync"]?.try(&.as_bool?) || lists.any? { |l| l.id == id }
      from = File.join(target, folder(before))
      to = File.join(target, folder(after))
      return if from == to || !Dir.exists?(from) || File.exists?(to)
      Dir.mkdir_p(File.dirname(to))
      File.rename(from, to)
      # the copied files moved along, and stay the handler's
      prefix = folder(before) + "/"
      moved = manifest(target).map { |r| r.starts_with?(prefix) ? folder(after) + "/" + r.lchop(prefix) : r }
      write_manifest(target, moved) if File.exists?(File.join(target, MANIFEST))
      puts "#{folder(before)} -> #{folder(after)}"
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

      prune(target, wanted.map(&.rel).to_set)
    end

    def self.series_number(idx : Float64) : String
      idx == idx.floor ? "%02d" % idx.to_i : idx.to_s
    end

    def self.clean(s : String, limit = 120) : String
      c = s.gsub(/[\\\/:*?"<>|\x00-\x1f]/, "_").strip.rstrip('.')
      c = c[0, limit].strip
      c.empty? ? "_" : c
    end

    # Removes the files the handler copied that are no longer wanted, and
    # the folders that leaves empty; then records what it copied now
    private def self.prune(target : String, wanted : Set(String))
      kept = [] of String
      manifest(target).each do |rel|
        next if wanted.includes?(rel)
        path = File.join(target, rel)
        begin
          if File.file?(path) && !File.symlink?(path)
            File.delete(path)
            puts "- #{rel}"
          end
          remove_empty_parents(File.dirname(path), target)
        rescue ex : File::Error
          # stays recorded, the next run tries again
          puts "removing #{rel} failed: #{ex.message}"
          kept << rel
        end
      end
      write_manifest(target, (wanted.to_a + kept).sort)
    end

    def self.manifest(target : String) : Array(String)
      path = File.join(target, MANIFEST)
      return [] of String unless File.exists?(path)
      # relative paths inside the target only
      File.read_lines(path).map(&.strip).reject { |l| l.empty? || l.starts_with?('/') || l.split('/').includes?("..") }
    end

    private def self.write_manifest(target : String, rels : Array(String))
      tmp = File.join(target, ".syncthing.#{MANIFEST}.tmp")
      File.write(tmp, rels.join("\n") + (rels.empty? ? "" : "\n"))
      File.rename(tmp, File.join(target, MANIFEST))
    end

    private def self.remove_empty_parents(dir : String, target : String)
      root = File.expand_path(target)
      d = File.expand_path(dir)
      while d.starts_with?(root + "/") && Dir.exists?(d) && Dir.empty?(d)
        Dir.delete(d)
        d = File.dirname(d)
      end
    end

    # temporary directory, removed afterwards
    private def self.with_tmpdir(&)
      path = File.join(Dir.tempdir, "calibre-hub-#{Random::Secure.hex(6)}")
      Dir.mkdir(path)
      begin
        yield path
      ensure
        FileUtils.rm_rf(path)
      end
    end

    private def self.convert(id : Int64, src : String, fmt : String, tmp : String, env) : String
      dst = File.join(tmp, "#{id}.#{fmt.downcase}")
      log = IO::Memory.new
      status = Command.run("ebook-convert", [src, dst], CONVERT_TIMEOUT, output: log, error: log)
      raise(log.to_s.lines.last? || "ebook-convert exit #{status.exit_code}") unless status.success?
      calibre = Calibre.new(env["CALIBRE_HUB_CALIBRE_URL"], env["CALIBRE_HUB_CALIBRE_USER"],
        Secret.read(env["CALIBRE_HUB_CALIBRE_PASSWORD_FILE"]), env["CALIBRE_HUB_LIBRARY_ID"]?)
      calibre.add_format(id, dst, fmt.downcase)
      dst
    end
  end
end
