require "db"
require "json"
require "kemal"
require "./incoming"
require "./covers"
require "./meta_filename"
require "./writer"
require "./api"

module CalibreHub
  # What gets a file of the Eingang into the library, one unit at a time, as a
  # decision of Intake wants it. The state DB keeps what earlier imports
  # handled: import_runs and import_units, which nothing reads any more, and
  # import_files, which ImportRepair goes by. Only a row left of the backlog
  # still adds to it.
  class Importer
    # A decision of the Eingang in place of the rule flow: the values to
    # write (empty: as in the file), the flow's decision they come from, that
    # the book is wanted although it looks like one the library has, that it
    # is a book of its own even if only a format looks new (fresh: an upload
    # sent on purpose), and what its source gives it: tags and a category as
    # {column, value}
    record Chosen, values : Hash(String, JSON::Any), decision : Meta::Flow::Decision?, force : Bool = false,
      fresh : Bool = false, tags : Array(String) = [] of String, category : {String, String}? = nil

    getter writer : Writer

    def initialize(@db : DB::Database, @calibre : Calibre, @writer : Writer,
                   @library : String?, @retries = 20, @retry_wait = 15.seconds)
      Importer.migrate(@db)
      @index = nil.as(Incoming::Index?)
      @index_run = ""
      # folder -> how its files are named (Meta::FileName.orientation)
      @hints = {} of String => Symbol?
    end

    def self.migrate(db : DB::Database)
      db.exec <<-SQL
        create table if not exists import_files (
          path text primary key,
          size integer not null,
          mtime integer not null,
          status text not null,
          book_id integer,
          run_id text not null,
          at integer not null
        )
        SQL
    end

    def index_for(run_id : String) : Incoming::Index
      if (ix = @index) && @index_run == run_id
        return ix
      end
      ix = with_retry { Incoming::Index.load(@calibre, @library, @db) }
      @index = ix
      @index_run = run_id
      ix
    end

    # the book's files, for ImportRepair
    def handled(unit : Incoming::Unit, run_id : String)
      now = Time.utc.to_unix
      unit.files.each do |f|
        @db.exec "insert or replace into import_files (path, size, mtime, status, book_id, run_id, at) values (?, ?, ?, ?, ?, ?, ?)",
          f.path, f.size, f.mtime, unit.status, unit.book_id, run_id, now
      end
    end

    # calibre-server failed on one book (e.g. calibre's NoSuchBook, an
    # HTTP 500) while it answers otherwise: that unit fails, the run goes on
    class BookFailed < Exception
    end

    # calibre-server down: wait, then stop the job (resumed by another run).
    # book: the call is about one book; when calibre-server answers a
    # plain search, the error is that book's (BookFailed), no outage.
    private def with_retry(book = false, &)
      attempts = 0
      loop do
        return yield
      rescue ex : Calibre::Unavailable
        raise BookFailed.new(ex.message) if book && healthy?
        attempts += 1
        raise Jobs::Abort.new("calibre-server unavailable: #{ex.message}") if attempts > @retries
        STDERR.puts "import: #{ex.message}, retrying in #{@retry_wait.total_seconds.to_i} s"
        sleep @retry_wait
      end
    end

    # calibre-server answers a cheap search
    private def healthy? : Bool
      @calibre.search("", "id", true, 0, 1)
      true
    rescue Calibre::Error
      false
    end

    # A unit as decided in the Eingang; a book that turned out to be in the
    # library comes back with the status duplicate, nothing added
    def import(unit : Incoming::Unit, ix : Incoming::Index, chosen : Chosen)
      Incoming.plan(unit, ix)
      return add(unit, ix, chosen) if chosen.fresh
      case unit.action
      when "addFormats"
        add_formats(unit.book_id.not_nil!, unit, ix)
      when "duplicate"
        chosen.force ? add(unit, ix, chosen) : (unit.status = "duplicate")
      else
        add(unit, ix, chosen)
      end
    end

    # the unit's files as formats of a book chosen by hand
    def add_to(unit : Incoming::Unit, ix : Incoming::Index, id : Int64)
      unit.add_formats = unit.files.map(&.format).uniq
      add_formats(id, unit, ix)
    end

    private def add_formats(id : Int64, unit : Incoming::Unit, ix : Incoming::Index)
      added = [] of Incoming::BookFile
      notes = [] of String
      unit.files.each do |f|
        next unless unit.add_formats.includes?(f.format) && added.none? { |a| a.format == f.format }
        if f.size > Incoming::MAX_FORMAT
          notes << "#{File.basename(f.path)} too large for another format"
          next
        end
        begin
          with_retry(book: true) { @calibre.add_format(id, f.path, f.format.downcase) }
        rescue ex : Calibre::TooLarge
          notes << "#{File.basename(f.path)}: #{ex.message}"
          next
        end
        added << f
      end
      ix.add_files(id, added)
      unit.add_formats = added.map(&.format)
      unit.book_id = id
      unit.status = added.empty? ? "duplicate" : "formatAdded"
      unit.detail = notes.join("; ").presence
      @writer.written([id]) unless added.empty?
    end

    private def add(unit : Incoming::Unit, ix : Incoming::Index, chosen : Chosen)
      primary = unit.primary
      opf = unit.meta
      force = chosen.force
      # a calibre folder was checked against the library already; a plain
      # file gets calibre's title/author check too
      result = with_retry(book: true) { @calibre.add_book(primary.path, File.basename(primary.path), duplicates: !opf.nil? || force) }
      id = result.book_id
      unless id
        existing = @writer.duplicate_books(result.duplicates).first?
        unless existing
          unit.status = "duplicate"
          unit.match = "calibre"
          unit.detail = result.duplicates.map(&.to_s).join("; ")
          return
        end
        merge(unit, existing.id, "calibre", ix)
        return
      end
      notes = [] of String
      book = nil
      decided = chosen.decision
      unit.decided = decided.try(&.how)
      begin
        if opf
          @calibre.set_fields(id, opf.changes)
          b = @calibre.book(id)
          changes = b ? Importer.chosen_fields(b, chosen) : {} of String => JSON::Any
          @calibre.set_fields(id, changes) unless changes.empty?
          unit.cover.try { |c| cover(id, c) }
        else
          # tags embedded in the file are dropped: only the decision's
          fields = {"tags" => JSON.parse("[]")}
          @calibre.book(id).try { |b| fields.merge!(Importer.chosen_fields(b, chosen)) }
          @calibre.set_fields(id, fields)
          book = @calibre.book(id)
          if !force && book && (hit = ix.match_book(book))
            @calibre.remove([id], permanent: true)
            merge(unit, hit[0], hit[1], ix)
            return
          end
        end
        unit.files.each do |f|
          next if f.path == primary.path || f.format == primary.format
          if f.size > Incoming::MAX_FORMAT
            notes << "#{File.basename(f.path)} too large for another format"
            next
          end
          begin
            @calibre.add_format(id, f.path, f.format.downcase)
          rescue too : Calibre::TooLarge
            # the book is in with its first file, as with one too large above
            notes << "#{File.basename(f.path)}: #{too.message}"
          end
        end
      rescue ex
        # no half imported book; the next run tries again
        begin
          @calibre.remove([id], permanent: true)
        rescue cleanup : Calibre::Error
          STDERR.puts "import: removing half imported book #{id} failed: #{cleanup.message}"
          raise Exception.new("#{ex.message} (book ##{id} is half imported, remove it)")
        end
        raise ex
      end
      if opf
        ix.add_meta(id, opf)
      elsif b = book
        ix.add_book(b)
      end
      ix.add_files(id, unit.files)
      unit.book_id = id
      unit.status = "imported"
      unit.detail = notes.join("; ").presence
      @writer.written([id])
      decided.try { |d| record_decision(id, primary.path, d, MetaLog::ACCEPTED) }
    end

    # What the Eingang's decision writes: its values and the flow's tags
    def self.chosen_fields(book : Book, chosen : Chosen) : Hash(String, JSON::Any)
      fields = {} of String => JSON::Any
      flow = chosen.decision.try(&.changes.find { |c| c.field == "tags" }).try(&.new.as_a.map(&.as_s)) || [] of String
      tags = (chosen.tags + flow).uniq
      fields["tags"] = JSON.parse(tags.to_json) unless tags.empty?
      fields.merge!(Edit.changes(Meta::Merge.patch(book, chosen.values), book, nil)) unless chosen.values.empty?
      chosen.category.try { |column, value| fields["##{column}"] = JSON::Any.new(value) }
      fields
    end

    # the decision in the state DB, a conflict to the review
    private def record_decision(id : Int64, path : String, d : Meta::Flow::Decision, status : String)
      @decisions.try &.decide(id, d, status)
      return if d.notes.empty?
      @review.try &.call(id, path, d)
      @decisions.try &.decided_status(id, status)
    end

    # where decisions are kept, what goes to the review (ImportRepair#flagged)
    property decisions : MetaLog?
    property review : Proc(Int64, String, Meta::Flow::Decision, Nil)?

    # How the folder's book files are named (Meta::FileName.orientation),
    # for names that could be read either way
    def hint(dir : String) : Symbol?
      @hints.clear if @hints.size > 500
      return @hints[dir] if @hints.has_key?(dir)
      names = begin
        Dir.children(dir).select { |n| Incoming::Scanner.format(n) }
      rescue File::Error
        [] of String
      end
      @hints[dir] = Meta::FileName.orientation(names)
    end

    # the unit is the book `id` already has: only its missing formats
    private def merge(unit : Incoming::Unit, id : Int64, how : String, ix : Incoming::Index)
      have = @calibre.book(id).try(&.formats.map(&.upcase).to_set) || ix.formats(id)
      unit.match = how
      unit.add_formats = unit.files.reject { |f| have.includes?(f.format) }.map(&.format).uniq
      add_formats(id, unit, ix)
    end

    private def cover(id : Int64, path : String)
      data = File.open(path, &.getb_to_end)
      type = Covers.image_type(data)
      @calibre.set_cover(id, data, type.not_nil!) if type && {"jpeg", "png"}.includes?(type)
    end
  end

  # Takes back what the inbox made of an imported collection's folders: for
  # books it added, the category it derived from the folder path is cleared
  # and exactly the tags that are a folder of that path are removed. The
  # folder path is read from the hub's events (the first state of the book
  # with a category, which the inbox set right after adding). Every apply
  # keeps the previous values (state DB and a JSON file) and can be undone.
  class ImportCleanup < Jobs
    class Entry
      include JSON::Serializable

      @[JSON::Field(key: "bookId")]
      getter book_id : Int64
      getter title : String
      getter folders : Array(String)
      # the category and tags before
      @[JSON::Field(emit_null: true)]
      getter kategorie : String?
      getter tags : Array(String)
      @[JSON::Field(key: "removeTags")]
      getter remove_tags : Array(String)
      @[JSON::Field(key: "clearKategorie")]
      getter clear_kategorie : Bool

      def initialize(@book_id, @title, @folders, @kategorie, @tags, @remove_tags, @clear_kategorie)
      end
    end

    def initialize(db : DB::Database, calibre : Calibre, writer : Writer, @column : String?, @backup_dir : String)
      db.exec <<-SQL
        create table if not exists import_cleanups (
          id text primary key,
          created_at integer not null,
          params text not null,
          entries text not null,
          job_id text,
          undo_job_id text
        )
        SQL
      super(db, calibre, writer, @column, "import_cleanup_jobs")
    end

    # The folders of a category "A.B.C" the inbox set together with the
    # tags A, B, C (a folder may contain dots); nil when it isn't one
    def self.folders(kategorie : String, tags : Array(String)) : Array(String)?
      return nil if kategorie.empty?
      tags.uniq.sort_by { |t| -t.size }.each do |t|
        next if t.empty?
        return [t] if kategorie == t
        if kategorie.starts_with?(t + ".")
          rest = folders(kategorie[(t.size + 1)..], tags)
          return [t] + rest if rest
        end
      end
      nil
    end

    def self.parse_time(s : String) : Time
      Time.parse_iso8601(s)
    rescue Time::Format::Error
      {"%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%d"}.each do |f|
        return Time.parse(s, f, Time::Location.local) rescue nil
      end
      raise Edit::Invalid.new("since", "ISO 8601 time expected (2026-11-02T18:00)")
    end

    # params: since (time of the added event), minId, maxId (book ids)
    def plan(params : Hash(String, JSON::Any)) : Array(Entry)
      column = @column || raise Edit::Invalid.new("kategorie", "no category column configured")
      since = params["since"]?.try(&.as_s?).try { |s| ImportCleanup.parse_time(s) }
      min = params["minId"]?.try { |v| v.as_i64? || raise Edit::Invalid.new("minId", "number expected") }
      max = params["maxId"]?.try { |v| v.as_i64? || raise Edit::Invalid.new("maxId", "number expected") }
      raise Edit::Invalid.new("since", "since or minId expected") unless since || min
      ids = [] of Int64
      sql = "select distinct book_id from events where type = 'added'"
      args = [] of DB::Any
      since.try { |t| sql += " and created_at >= ?"; args << t.to_unix }
      min.try { |v| sql += " and book_id >= ?"; args << v }
      max.try { |v| sql += " and book_id <= ?"; args << v }
      @db.query_each(sql + " order by book_id", args: args) { |rs| ids << rs.read(Int64) }
      return [] of Entry if ids.empty?
      # the first state of each book with a category: what the inbox set
      derived = {} of Int64 => {String, Array(String)}
      ids.each_slice(500) do |slice|
        @db.query_each("select book_id, payload from events where type in ('added', 'changed') and book_id in (#{slice.join(",")}) order by id") do |rs|
          book_id, payload = rs.read(Int64, String)
          next if derived.has_key?(book_id)
          book = JSON.parse(payload)["book"]? || next
          kat = book["custom"]?.try(&.[column]?).try(&.as_s?).presence || next
          tags = book["tags"]?.try(&.as_a?).try(&.map(&.to_s)) || [] of String
          derived[book_id] = {kat, tags}
        end
      end
      current = @calibre.books(ids)
      current.compact_map do |b|
        if d = derived[b.id]?
          kat, tags = d
        else
          kat = b.custom[column]?.try(&.as_s?) || next
          tags = b.tags
        end
        folders = ImportCleanup.folders(kat, tags) || next
        keys = folders.map(&.downcase).to_set
        remove = b.tags.select { |t| keys.includes?(t.downcase) }
        now = b.custom[column]?.try(&.as_s?)
        clear = now == kat
        next if remove.empty? && !clear
        Entry.new(b.id, b.title, folders, now, b.tags, remove, clear)
      end
    end

    # dry run: {entries}; else the cleanup with its job
    def submit_cleanup(params : Hash(String, JSON::Any), dry_run : Bool) : JSON::Any
      entries = plan(params)
      return JSON.parse({dryRun: true, total: entries.size, entries: entries}.to_json) if dry_run
      id = Random::Secure.hex(6)
      Dir.mkdir_p(@backup_dir)
      File.write(File.join(@backup_dir, "import-cleanup-#{id}.json"), {id: id, params: params, entries: entries}.to_pretty_json)
      @db.exec "insert into import_cleanups (id, created_at, params, entries) values (?, ?, ?, ?)",
        id, Time.utc.to_unix, params.to_json, entries.to_json
      job = enqueue(entries.map(&.book_id), {"cleanup" => JSON::Any.new(id), "undo" => JSON::Any.new(false)})
      @db.exec "update import_cleanups set job_id = ? where id = ?", job.id, id
      cleanup(id).not_nil!
    end

    def undo(id : String, dry_run : Bool) : JSON::Any
      c = cleanup(id) || raise Writer::NotFound.new
      entries = Array(Entry).from_json(c["entries"].to_json)
      return JSON.parse({dryRun: true, total: entries.size, entries: entries}.to_json) if dry_run
      job = enqueue(entries.map(&.book_id), {"cleanup" => JSON::Any.new(id), "undo" => JSON::Any.new(true)})
      @db.exec "update import_cleanups set undo_job_id = ? where id = ?", job.id, id
      cleanup(id).not_nil!
    end

    def cleanup(id : String) : JSON::Any?
      row = @db.query_one?("select created_at, params, entries, job_id, undo_job_id from import_cleanups where id = ?", id,
        as: {Int64, String, String, String?, String?})
      return nil unless row
      created, params, entries, job, undo = row
      JSON.parse({id: id, createdAt: Time.unix(created).to_rfc3339, params: JSON.parse(params), entries: JSON.parse(entries),
                  job: job.try { |j| self[j]? }, undoJob: undo.try { |j| self[j]? }}.to_json)
    end

    def cleanups : Array(JSON::Any)
      ids = [] of String
      @db.query_each("select id from import_cleanups order by created_at desc, rowid desc limit 10") { |rs| ids << rs.read(String) }
      ids.compact_map { |id| cleanup(id) }.map do |c|
        h = c.as_h.dup
        h["total"] = JSON::Any.new(h.delete("entries").try(&.as_a.size.to_i64) || 0_i64)
        JSON::Any.new(h)
      end
    end

    protected def apply(job : Job, index : Int32, id : Int64, resumed : Bool)
      column = @column.not_nil!
      cid = job.changes["cleanup"].as_s
      undo = job.changes["undo"]?.try(&.as_bool?) || false
      entries = @db.query_one("select entries from import_cleanups where id = ?", cid, as: String)
      entry = Array(Entry).from_json(entries).find { |e| e.book_id == id } || return
      book = @calibre.book(id) || raise Writer::NotFound.new
      now = book.custom[column]?.try(&.as_s?)
      body = {} of String => JSON::Any
      if undo
        missing = entry.remove_tags.reject { |t| book.tags.any? { |x| x.downcase == t.downcase } }
        body["tags"] = JSON.parse((book.tags + missing).to_json) unless missing.empty?
        body["kategorie"] = JSON::Any.new(entry.kategorie) if entry.clear_kategorie && now.nil?
      else
        keys = entry.remove_tags.map(&.downcase).to_set
        kept = book.tags.reject { |t| keys.includes?(t.downcase) }
        body["tags"] = JSON.parse(kept.to_json) if kept.size != book.tags.size
        body["kategorie"] = JSON::Any.new(nil) if entry.clear_kategorie && now == entry.kategorie
      end
      @writer.update(id, body) unless body.empty?
    end
  end

  def self.import_routes(cleanup : ImportCleanup?)
    # the last cleanups, to undo one
    get "/api/import/cleanups" do
      (cleanup.try(&.cleanups) || [] of JSON::Any).to_json
    end

    post "/api/import/cleanup" do |env|
      write_errors(env) do
        next fail(env, 404, {error: "no category column"}) unless cleanup
        body = json_body(env)
        dry = body.delete("dryRun").try(&.as_bool?)
        dry = true if dry.nil?
        result = cleanup.submit_cleanup(body, dry)
        env.response.status_code = dry ? 200 : 202
        result.to_json
      end
    end

    get "/api/import/cleanups/:id" do |env|
      c = cleanup.try(&.cleanup(env.params.url["id"]))
      c ? c.to_json : fail(env, 404, {error: "not found"})
    end

    post "/api/import/cleanups/:id/undo" do |env|
      write_errors(env) do
        next fail(env, 404, {error: "no category column"}) unless cleanup
        dry = json_body(env)["dryRun"]?.try(&.as_bool?)
        dry = true if dry.nil?
        result = cleanup.undo(env.params.url["id"], dry)
        env.response.status_code = dry ? 200 : 202
        result.to_json
      end
    end
  end
end
