require "json"
require "file_utils"
require "../calibre"
require "../library_db"

module CalibreHub
  # Handler: mirrors every book with a tag (default "leseliste") into a
  # folder, e.g. one synced to an e-reader. Preferred formats in order
  # (default epub, then pdf); without them a convertible format is converted
  # to the first one and added to calibre. Subfolders come from the category
  # column ("Fachbuch.Software" -> Fachbuch/Software), file names are
  # "Author - Series NN - Title". Files whose book lost the tag are removed.
  #
  # Reads metadata.db read-only for paths; writes only via calibre-server.
  # Environment: LESELISTE_TAG, LESELISTE_TARGET, LESELISTE_FORMATS,
  # CALIBRE_HUB_LIBRARY, CALIBRE_HUB_CATEGORY_COLUMN and the calibre-server
  # settings of the hub (for adding converted formats).
  module Leseliste
    CONVERTIBLE = %w(AZW3 MOBI AZW KEPUB FB2 LIT DOCX RTF HTMLZ TXT)
    KEEP        = {".stfolder", ".stignore", ".stversions"}
    RELEVANT    = %w(tags title authors authorSort series seriesIndex formats)

    record Wanted, rel : String, src : String

    def self.relevant?(event : JSON::Any?, tag : String, category : String?) : Bool
      return true unless event
      return true if event["type"]? != JSON::Any.new("changed")
      keys = event["changes"]?.try(&.as_h.keys) || [] of String
      fields = RELEVANT + (category ? ["##{category}"] : [] of String)
      return false unless keys.any? { |k| fields.includes?(k) }
      # only books that have or had the tag matter
      tags = event["changes"]["tags"]?.try(&.as_a.flat_map { |v| v.as_a? || [] of JSON::Any }.map(&.as_s)) ||
             event["book"]?.try(&.["tags"].as_a.map(&.as_s)) || [] of String
      tags.any? { |t| t.downcase == tag }
    end

    def self.run(env = ENV, input : IO = STDIN) : Int32
      tag = (env["LESELISTE_TAG"]? || "leseliste").downcase
      target = env["LESELISTE_TARGET"]? || abort "LESELISTE_TARGET is not set"
      library = env["CALIBRE_HUB_LIBRARY"]? || abort "CALIBRE_HUB_LIBRARY is not set"
      formats = (env["LESELISTE_FORMATS"]? || "epub,pdf").split(',', remove_empty: true).map(&.strip.upcase)
      category = env["CALIBRE_HUB_CATEGORY_COLUMN"]?.presence

      raw = input.gets_to_end.strip
      event = raw.empty? ? nil : JSON.parse(raw)
      return 0 unless relevant?(event, tag, category)

      db = LibraryDB.open_read_only(File.join(library, "metadata.db"))
      Dir.mktmpdir_compat do |tmp|
        mirror(wanted(db, library, tag, formats, category, tmp, env), target)
      end
      db.close
      0
    end

    def self.wanted(db, library, tag, formats, category, tmp, env) : Array(Wanted)
      column = category.try do |c|
        db.query_one?("select id from custom_columns where label = ?", c, as: Int64)
      end
      cat_sql = column ? %((select v.value from custom_column_#{column} v
        join books_custom_column_#{column}_link l on l.value = v.id where l.book = b.id)) : "null"
      rows = [] of {Int64, String, String, Float64, String?, String?, String?}
      db.query_each(<<-SQL, tag) do |rs|
        select b.id, b.title, b.path, b.series_index,
               (select s.name from series s join books_series_link l on l.series = s.id where l.book = b.id),
               (select a.sort from authors a join books_authors_link l on l.author = a.id
                 where l.book = b.id order by l.id limit 1),
               #{cat_sql}
          from books b
          join books_tags_link bt on bt.book = b.id
          join tags t on t.id = bt.tag
         where lower(t.name) = ?
        SQL
        rows << {rs.read(Int64), rs.read(String), rs.read(String), rs.read(Float64),
                 rs.read(String?), rs.read(String?), rs.read(String?)}
      end

      result = {} of String => Wanted
      rows.each do |id, title, path, idx, series, author, kategorie|
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
            next
          end
          fmt = formats.first
          begin
            src = convert(id, files[from], fmt, tmp, env)
            puts "##{id} #{title}: #{from} -> #{fmt}, added to calibre"
          rescue ex
            puts "##{id} #{title}: #{from} -> #{fmt} failed: #{ex.message}"
            next
          end
        end
        name = series ? "#{author || "Unknown"} - #{series} #{series_number(idx)} - #{title}" : "#{author || "Unknown"} - #{title}"
        folders = kategorie ? kategorie.split('.').map(&.strip).reject(&.empty?).map { |p| clean(p, 60) } : [] of String
        rel = File.join(folders + ["#{clean(name)}.#{fmt.not_nil!.downcase}"])
        rel = File.join(folders + ["#{clean(name)} (#{id}).#{fmt.not_nil!.downcase}"]) if result.has_key?(rel)
        result[rel] = Wanted.new(rel, src.not_nil!)
      end
      result.values
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
