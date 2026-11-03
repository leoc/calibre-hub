require "db"
require "json"
require "kemal"
require "./backlog"
require "./covers"
require "./meta_filename"
require "./writer"
require "./api"

module CalibreHub
  # Backlog imports as jobs (one per run: the scan, then a unit per book)
  # and their runs in the state DB: the scan with its plan (import_units),
  # the summary and the skipped files (import_runs), and every file a run
  # handled (import_files), so another run of the same folder skips them.
  # A dry run is only the scan, in a queue of its own (ImportScans): it
  # doesn't wait for an import and doesn't pause the hooks.
  class ImportJobs < Jobs
    KEEP_RUNS = 20
    # units stored per transaction; the API gets the state DB in between
    STORE_BATCH = 500

    class Busy < Exception
    end

    # A hook that works off the imported books afterwards (paused while an
    # import runs): the books in its running jobs or its queue table, and
    # the events of its kind past its cursor it hasn't looked at yet
    record FollowupHook, name : String, cursor : String, events : String, jobs : String? = nil, queue : String? = nil

    getter roots : Array(String)
    # the hooks that are on (main.cr)
    property followup = [] of FollowupHook

    def initialize(db : DB::Database, calibre : Calibre, writer : Writer, roots : Array(String),
                   @library : String?, @retries = 20, @retry_wait = 15.seconds)
      @roots = roots.map { |r| File.expand_path(r) }
      ImportJobs.migrate(db)
      super(db, calibre, writer, nil, "import_jobs")
      @index = nil.as(Backlog::Index?)
      @index_run = ""
      @scans = nil.as(ImportScans?)
      # run -> the book being imported, and when this process took the
      # run up with how many were done then (the rate leaves out restarts)
      @current = {} of String => String
      @base = {} of String => {Time::Instant, Int32}
      # folder -> how its files are named (Meta::FileName.orientation)
      @hints = {} of String => Symbol?
      @scans = ImportScans.new(db, calibre, writer, self)
    end

    # the dry runs' queue
    def scans : ImportScans
      @scans.not_nil!
    end

    def self.migrate(db : DB::Database)
      db.exec <<-SQL
        create table if not exists import_runs (
          id text primary key,
          path text not null,
          dry_run integer not null,
          job_id text,
          created_at integer not null,
          summary text not null,
          skipped text not null
        )
        SQL
      columns = [] of String
      db.query_each("select name from pragma_table_info('import_runs')") { |rs| columns << rs.read(String) }
      # every folder of the run (JSON), path is them joined
      db.exec "alter table import_runs add column paths text" unless columns.includes?("paths")
      db.exec "alter table import_runs add column limit_n integer" unless columns.includes?("limit_n")
      # 0 until the job's scan stored units and summary (runs from before scanned at once)
      db.exec "alter table import_runs add column scanned integer not null default 1" unless columns.includes?("scanned")
      # the scan's progress: {files, units, planned}
      db.exec "alter table import_runs add column scan text" unless columns.includes?("scan")
      # unix times: the job began the scan, the scan ended, the last book was handled
      %w(started_at scanned_at finished_at).each do |c|
        db.exec "alter table import_runs add column #{c} integer" unless columns.includes?(c)
      end
      db.exec <<-SQL
        create table if not exists import_units (
          run_id text not null,
          idx integer not null,
          status text not null,
          unit text not null,
          primary key (run_id, idx)
        )
        SQL
      units = [] of String
      db.query_each("select name from pragma_table_info('import_units')") { |rs| units << rs.read(String) }
      # the plan's action (add, addFormats, duplicate), for the backlog's open books
      db.exec "alter table import_units add column action text" unless units.includes?("action")
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

    # The folder to import: absolute, or relative to the first root; it
    # must be (in) a root
    def resolve(path : String) : String
      raise Edit::Invalid.new("path", "no import roots configured (backlogImport.roots)") if @roots.empty?
      p = path.strip
      raise Edit::Invalid.new("path", "path expected") if p.empty?
      full = File.expand_path(p, @roots.first)
      real = File.realpath(full) rescue raise Edit::Invalid.new("path", "#{full} does not exist")
      raise Edit::Invalid.new("path", "#{full} is not a folder") unless File.directory?(real)
      ok = @roots.any? do |r|
        root = File.realpath(r) rescue next false
        real == root || real.starts_with?(root.rstrip('/') + "/")
      end
      raise Edit::Invalid.new("path", "#{full} is not below an import root (#{@roots.join(", ")})") unless ok
      real
    end

    # The files earlier runs handled; with an index, without those whose
    # book (imported, a duplicate of or a format added to) is no longer in
    # the library: they are planned again
    def known(index : Backlog::Index? = nil) : Backlog::Known
      k = Backlog::Known.new
      @db.query_each("select path, size, mtime, status, book_id from import_files") do |rs|
        path, size, mtime, status, book = rs.read(String, Int64, Int64, String, Int64?)
        next if index && book && !index.exists?(book)
        k[path] = {size, mtime, status, book}
      end
      k
    end

    # Queues a run of one or more folders and returns it right away: a dry
    # run only scans and plans (status scanning, then planned), an import
    # scans and then imports the units (scanning, running, done). limit:
    # the first that many books that add a book or formats, in scan order.
    def start(paths : Array(String), dry_run : Bool, limit : Int32? = nil) : JSON::Any
      raise Edit::Invalid.new("path", "path expected") if paths.empty?
      raise Edit::Invalid.new("limit", "1 or more expected") if limit && limit < 1
      dirs = paths.map { |p| resolve(p) }.uniq
      # a folder below another one of the run is scanned with that
      dirs = dirs.reject { |d| dirs.any? { |o| o != d && d.starts_with?(o.rstrip('/') + "/") } }
      raise Busy.new("an import is running") if !dry_run && running?
      id = Random::Secure.hex(8)
      @db.exec "insert into import_runs (id, path, paths, dry_run, limit_n, created_at, summary, skipped, scanned) values (?, ?, ?, ?, ?, ?, 'null', '[]', 0)",
        id, dirs.join(", "), dirs.to_json, dry_run ? 1 : 0, limit.try(&.to_i64), Time.utc.to_unix
      job = dry_run ? scans.queue(id) : enqueue([] of Int64, {"run" => JSON::Any.new(id)})
      @db.exec "update import_runs set job_id = ? where id = ?", job.id, id
      prune
      run(id) || raise Writer::NotFound.new
    end

    def start(path : String, dry_run : Bool, limit : Int32? = nil) : JSON::Any
      start([path], dry_run, limit)
    end

    # A run's scan, the first step of its job (table: the job's queue):
    # walks the folders, plans every unit and stores units and summary; an
    # import's job gets the units it imports. Done already when the hub
    # restarted after it.
    def scan(job : Job, table : String) : Job
      run_id = job.changes["run"].as_s
      row = @db.query_one?("select path, paths, dry_run, limit_n, scanned from import_runs where id = ?", run_id,
        as: {String, String?, Int64, Int64?, Int64})
      raise Jobs::Abort.new("run #{run_id} is gone") unless row
      path, paths, dry, limit_n, scanned = row
      return job if scanned == 1
      dirs = paths.try { |p| Array(String).from_json(p) } || [path]
      limit = limit_n.try(&.to_i32)
      last = Time.instant
      # phase: scan (walking the folders), check (against the library);
      # since: when the phase began; path: the folder or book it is at
      phase = "scan"
      since = Time.utc.to_unix
      progress = ->(files : Int32, units : Int32, planned : Int32, path : String?, force : Bool) do
        now = Time.instant
        if force || now - last >= 1.second
          last = now
          @db.exec "update import_runs set scan = ? where id = ?",
            {files: files, units: units, planned: planned, phase: phase, since: since, path: path}.to_json, run_id
        end
        nil
      end
      # a scan begun again after a restart starts over
      @db.exec "update import_runs set started_at = ? where id = ?", since, run_id
      progress.call(0, 0, 0, nil, true)
      index = with_retry { Backlog::Index.load(@calibre, @library, @db) }
      scanner = Backlog::Scanner.new(dirs, known(index))
      scanner.on_progress = ->(files : Int32, units : Int32) { progress.call(files, units, 0, scanner.current, false) }
      scanner.run
      units = scanner.units
      phase = "check"
      since = Time.utc.to_unix
      progress.call(scanner.files, units.size, 0, nil, true)
      Backlog.plan_all(units, index) { |n| progress.call(scanner.files, units.size, n, units[n - 1]?.try(&.name), false) }
      progress.call(scanner.files, units.size, units.size, nil, true)
      taken = Backlog.take(units, limit)
      if limit
        chosen = taken.to_set
        units.each_with_index { |u, i| u.status = "deferred" unless chosen.includes?(i) }
      end
      summary = Backlog.summary(units, scanner.skipped, scanner.already, dirs, taken, limit)
      @db.exec "delete from import_units where run_id = ?", run_id
      units.each_slice(STORE_BATCH).with_index do |slice, n|
        @db.transaction do |tx|
          slice.each_with_index do |u, i|
            tx.connection.exec "insert into import_units (run_id, idx, status, action, unit) values (?, ?, ?, ?, ?)",
              run_id, n * STORE_BATCH + i, u.status, u.action, u.to_json
          end
        end
        Fiber.yield
      end
      ids = dry == 1 ? [] of Int64 : taken.map(&.to_i64)
      @db.transaction do |tx|
        c = tx.connection
        c.exec "update import_runs set summary = ?, skipped = ?, scanned = 1, scanned_at = ? where id = ?",
          summary.to_json, scanner.skipped.to_json, Time.utc.to_unix, run_id
        c.exec "update #{table} set ids = ? where id = ?", ids.to_json, job.id
      end
      Job.new(ids, job.changes, job.id)
    end

    def runs(limit = 10) : Array(JSON::Any)
      ids = [] of String
      @db.query_each("select id from import_runs order by created_at desc, rowid desc limit ?", limit) { |rs| ids << rs.read(String) }
      ids.compact_map { |id| run(id) }
    end

    # failed books listed with a run
    FAILURES = 20

    # status: scanning (the job's scan), planned (a dry run's result),
    # running, done, failed (the import job's), gone (the job was pruned).
    # phase: scan (walking the folders), check (against the library),
    # import, else the status; current: the folder or book it is at.
    # Times, rates (files per second while scanning, books per minute) and
    # the ETA (seconds, while checking and importing) come from the state
    # DB and, for an import, from the books this process imported.
    def run(id : String) : JSON::Any?
      row = @db.query_one?("select path, paths, dry_run, job_id, created_at, summary, limit_n, scanned, scan, started_at, scanned_at, finished_at " \
                           "from import_runs where id = ?", id,
        as: {String, String?, Int64, String?, Int64, String, Int64?, Int64, String?, Int64?, Int64?, Int64?})
      return nil unless row
      path, paths, dry, job_id, created, summary, limit, scanned, scan, started, scanned_at, finished = row
      results = Hash(String, Int64).new(0_i64)
      @db.query_each("select status, count(*) from import_units where run_id = ? group by status", id) do |rs|
        results[rs.read(String)] = rs.read(Int64)
      end
      job = job_id.try { |j| dry == 1 ? scans[j]? : self[j]? }
      status = if scanned == 0
                 case job.try(&.status)
                 when nil       then "gone"
                 when "running" then "scanning"
                 else                "failed"
                 end
               elsif dry == 1
                 "planned"
               else
                 job.try(&.status) || "gone"
               end
      progress = scan.try { |s| JSON.parse(s) }
      done = dry == 1 ? nil : job.try(&.done)
      total = dry == 1 ? results.values.sum : (job.try(&.total) || results.values.sum)
      phase = case status
              when "scanning" then progress.try(&.["phase"]?).try(&.as_s?) || "scan"
              when "running"  then "import"
              else                 status
              end
      current = case phase
                when "scan", "check" then progress.try(&.["path"]?).try(&.as_s?)
                when "import"        then @current[id]?
                end
      now = Time.utc.to_unix
      live = {"scanning", "running"}.includes?(status)
      ended = live ? now : (dry == 1 ? scanned_at : finished || scanned_at)
      elapsed = started.try { |s| ended.try { |e| Math.max(e - s, 0_i64) } }
      files_rate = nil.as(Float64?)
      books_rate = nil.as(Float64?)
      eta = nil.as(Int64?)
      case phase
      when "scan"
        if p = progress
          dt = now - (p["since"]?.try(&.as_i64?) || now)
          files_rate = (p["files"].as_i64 / dt).round(1) if dt > 0
        end
      when "check"
        if p = progress
          dt = now - (p["since"]?.try(&.as_i64?) || now)
          planned = p["planned"].as_i64
          if dt > 0 && planned > 0
            books_rate = (planned * 60 / dt).round(1)
            eta = ((p["units"].as_i64 - planned) * dt / planned).to_i64
          end
        end
      when "import"
        if (base = @base[id]?) && (d = done)
          dt = (Time.instant - base[0]).total_seconds
          n = d - base[1]
          if dt >= 1 && n > 0
            books_rate = (n * 60 / dt).round(1)
            eta = ((total - d) * dt / n).to_i64
          end
        end
      when "done", "failed"
        if (d = done) && d > 0 && (f = finished) && (sc = scanned_at) && f > sc
          books_rate = (d * 60 / (f - sc)).round(1)
        end
      end
      failures = [] of NamedTuple(path: String, detail: String?)
      @db.query_each("select unit from import_units where run_id = ? and status = 'failed' order by idx limit ?", id, FAILURES) do |rs|
        u = Backlog::Unit.from_json(rs.read(String))
        failures << {path: u.name, detail: u.detail}
      end
      JSON.parse({
        id: id, path: path, paths: paths.try { |p| JSON.parse(p) } || [path], dryRun: dry == 1, limit: limit,
        createdAt: Time.unix(created).to_rfc3339, jobId: job_id, status: status, phase: phase, current: current,
        startedAt: started.try { |t| Time.unix(t).to_rfc3339 }, scannedAt: scanned_at.try { |t| Time.unix(t).to_rfc3339 },
        finishedAt: live ? nil : ended.try { |t| Time.unix(t).to_rfc3339 }, elapsedSeconds: elapsed,
        filesPerSecond: files_rate, booksPerMinute: books_rate, etaSeconds: eta,
        done: done, total: total,
        error: job.try(&.error), scan: progress, summary: JSON.parse(summary), results: results, failures: failures,
      }.to_json)
    end

    # The whole backlog, from the runs: books imported, formats added and
    # duplicates found by every import so far (the files they handled), and
    # what is still open by the latest scanned run (its folders): books to
    # add, formats to add, duplicates and failed books not handled yet.
    # rate: books per minute of the running import, for the ETA.
    def backlog(rate : Float64? = nil) : JSON::Any
      handled = Hash(String, Int64).new(0_i64)
      # a unit's files share run, status and book
      @db.query_each("select status, count(*) from (select distinct run_id, status, book_id from import_files) group by status") do |rs|
        handled[rs.read(String)] = rs.read(Int64)
      end
      basis = @db.query_one?("select id, path, paths, created_at from import_runs where scanned = 1 order by created_at desc, rowid desc limit 1",
        as: {String, String, String?, Int64})
      open = Hash(String, Int64).new(0_i64)
      failed = 0_i64
      if basis
        @db.query_each("select coalesce(action, json_extract(unit, '$.action')), status, count(*) from import_units " \
                       "where run_id = ? and status in ('pending', 'deferred', 'failed') group by 1, 2", basis[0]) do |rs|
          action, status, n = rs.read(String?, String, Int64)
          open[action || "add"] += n
          failed += n if status == "failed"
        end
      end
      left = open.values.sum
      JSON.parse({
        imported: handled["imported"], formatAdded: handled["formatAdded"], duplicates: handled["duplicate"],
        open: {books: open["add"], formats: open["addFormats"], duplicates: open["duplicate"], failed: failed},
        # the new books of the backlog: imported and still to add
        total:      handled["imported"] + open["add"],
        basis:      basis.try { |b| {runId: b[0], paths: b[2].try { |p| JSON.parse(p) } || [b[1]], createdAt: Time.unix(b[3]).to_rfc3339} },
        etaSeconds: rate && rate > 0 && left > 0 ? (left * 60 / rate).to_i64 : nil,
      }.to_json)
    end

    # The hooks' work left after imports: books per hook, and whether they
    # still wait for an import
    def followup_status : JSON::Any
      queues = {} of String => Int64
      @followup.each do |h|
        n = 0_i64
        begin
          if cursor = @db.query_one?("select value from meta where key = ?", h.cursor, as: String).try(&.to_i64?)
            n += @db.query_one("select count(*) from events where id > ? and type = ?", cursor, h.events, as: Int64)
          end
          if table = h.jobs
            rows = [] of {String, Int32}
            @db.query_each("select ids, done from #{table} where status = 'running'") { |rs| rows << {rs.read(String), rs.read(Int32)} }
            # the metadata jobs' author pass is the id 0
            rows.each { |ids, done| n += (Array(Int64).from_json(ids)[done..]? || [] of Int64).count(&.> 0) }
          end
          h.queue.try { |q| n += @db.query_one("select count(*) from #{q}", as: Int64) }
        rescue DB::Error | SQLite3::Exception
        end
        queues[h.name] = n
      end
      JSON.parse({paused: Backlog.paused?(@db), total: queues.values.sum, queues: queues}.to_json)
    end

    # Every unit with its plan and result, and the skipped files
    def report(id : String) : JSON::Any?
      r = run(id) || return nil
      units = [] of JSON::Any
      @db.query_each("select unit from import_units where run_id = ? order by idx", id) { |rs| units << JSON.parse(rs.read(String)) }
      skipped = @db.query_one("select skipped from import_runs where id = ?", id, as: String)
      JSON.parse({run: r, units: units, skipped: JSON.parse(skipped)}.to_json)
    end

    private def prune
      old = [] of String
      @db.query_each("select id from import_runs order by created_at desc, rowid desc limit -1 offset ?", KEEP_RUNS) { |rs| old << rs.read(String) }
      old.each do |id|
        @db.exec "delete from import_units where run_id = ?", id
        @db.exec "delete from import_runs where id = ?", id
      end
    end

    protected def prepare(job : Job) : Job
      job = scan(job, @table)
      @base[job.changes["run"].as_s] = {Time.instant, job.done}
      job
    end

    # One unit of a run
    protected def apply(job : Job, index : Int32, id : Int64, resumed : Bool)
      run_id = job.changes["run"].as_s
      json = @db.query_one?("select unit from import_units where run_id = ? and idx = ?", run_id, id, as: String) || return
      unit = Backlog::Unit.from_json(json)
      # handled just before the hub stopped
      return unless unit.status == "pending"
      @current[run_id] = unit.name
      ix = index_for(run_id)
      begin
        import(unit, ix)
      rescue ex : Jobs::Abort
        raise ex
      rescue ex
        unit.status = "failed"
        unit.detail = ex.message || ex.class.name
        save(run_id, id, unit)
        raise ex
      end
      save(run_id, id, unit)
    end

    private def index_for(run_id : String) : Backlog::Index
      if (ix = @index) && @index_run == run_id
        return ix
      end
      ix = with_retry { Backlog::Index.load(@calibre, @library, @db) }
      @index = ix
      @index_run = run_id
      ix
    end

    private def save(run_id : String, idx : Int64, unit : Backlog::Unit)
      now = Time.utc.to_unix
      @db.exec "update import_units set status = ?, action = ?, unit = ? where run_id = ? and idx = ?", unit.status, unit.action, unit.to_json, run_id, idx
      @db.exec "update import_runs set finished_at = ? where id = ?", now, run_id
      return if unit.status == "failed"
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

    def import(unit : Backlog::Unit, ix : Backlog::Index)
      Backlog.plan(unit, ix)
      case unit.action
      when "duplicate"
        unit.status = "duplicate"
      when "addFormats"
        add_formats(unit.book_id.not_nil!, unit, ix)
      else
        add(unit, ix)
      end
    end

    private def add_formats(id : Int64, unit : Backlog::Unit, ix : Backlog::Index)
      added = [] of Backlog::BookFile
      notes = [] of String
      unit.files.each do |f|
        next unless unit.add_formats.includes?(f.format) && added.none? { |a| a.format == f.format }
        if f.size > Backlog::MAX_FORMAT
          notes << "#{File.basename(f.path)} too large for another format"
          next
        end
        with_retry(book: true) { @calibre.add_format(id, f.path, f.format.downcase) }
        added << f
      end
      ix.add_files(id, added)
      unit.add_formats = added.map(&.format)
      unit.book_id = id
      unit.status = added.empty? ? "duplicate" : "formatAdded"
      unit.detail = notes.join("; ").presence
      @writer.written([id]) unless added.empty?
    end

    private def add(unit : Backlog::Unit, ix : Backlog::Index)
      primary = unit.primary
      opf = unit.meta
      # a calibre folder was checked against the library already; a plain
      # file gets calibre's title/author check too
      result = with_retry(book: true) { @calibre.add_book(primary.path, File.basename(primary.path), duplicates: !opf.nil?) }
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
      begin
        if opf
          @calibre.set_fields(id, opf.changes)
          unit.cover.try { |c| cover(id, c) }
        else
          # tags embedded in the file are dropped, like in the inbox; title,
          # authors, publisher, year and series from the file name where
          # calibre has only its own reading of it ("Title - Author")
          fields = {"tags" => JSON.parse("[]")}
          @calibre.book(id).try { |b| fields.merge!(ImportJobs.name_fields(b, primary.path, hint(unit.dir))) }
          @calibre.set_fields(id, fields)
          book = @calibre.book(id)
          if book && (hit = ix.match_book(book))
            @calibre.remove([id], permanent: true)
            merge(unit, hit[0], hit[1], ix)
            return
          end
        end
        unit.files.each do |f|
          next if f.path == primary.path || f.format == primary.format
          if f.size > Backlog::MAX_FORMAT
            notes << "#{File.basename(f.path)} too large for another format"
            next
          end
          @calibre.add_format(id, f.path, f.format.downcase)
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
    end

    # set-fields changes from the file name of a book calibre just added
    # from that file (Meta::FileName): its title and authors where calibre
    # read them from the name (or the file's title says nothing), the
    # publisher, year and series where the file has none
    def self.name_fields(book : Book, path : String, hint : Symbol?) : Hash(String, JSON::Any)
      name = File.basename(path)
      guess = Meta::FileName.parse(name, hint) || return {} of String => JSON::Any
      changes = Meta::FileName.changes(book, name, guess, ->(field : String) { Meta::Merge.value(book, field).as(JSON::Any?) })
      return {} of String => JSON::Any if changes.empty?
      Edit.changes(Meta::Merge.patch(book, changes.to_h { |c| {c.field, c.new} }), book, nil)
    end

    # How the folder's book files are named (Meta::FileName.orientation),
    # for names that could be read either way
    private def hint(dir : String) : Symbol?
      @hints.clear if @hints.size > 500
      return @hints[dir] if @hints.has_key?(dir)
      names = begin
        Dir.children(dir).select { |n| Backlog::Scanner.format(n) }
      rescue File::Error
        [] of String
      end
      @hints[dir] = Meta::FileName.orientation(names)
    end

    # the unit is the book `id` already has: only its missing formats
    private def merge(unit : Backlog::Unit, id : Int64, how : String, ix : Backlog::Index)
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

  # The dry runs of the backlog import: only the scan (ImportJobs#scan)
  class ImportScans < Jobs
    def initialize(db : DB::Database, calibre : Calibre, writer : Writer, @imports : ImportJobs)
      super(db, calibre, writer, nil, "import_scan_jobs")
    end

    def queue(run_id : String) : Job
      enqueue([] of Int64, {"run" => JSON::Any.new(run_id)})
    end

    protected def prepare(job : Job) : Job
      @imports.scan(job, @table)
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

  def self.import_routes(imports : ImportJobs?, cleanup : ImportCleanup?)
    get "/api/import" do
      cleanups = cleanup.try(&.cleanups) || [] of JSON::Any
      next {enabled: false, cleanups: cleanups}.to_json unless imports
      runs = imports.runs
      running = imports.running?
      scan = runs.find { |r| r["status"] == "scanning" }
      importing = runs.find { |r| r["status"] == "running" }
      followup = imports.followup_status
      # where the backlog import is now: scan or check (the scan of an
      # import, else of a dry run while nothing imports), import, followup
      # (the hooks work off imported books), nil when idle
      shown = runs.find { |r| r["status"] == "scanning" && !r["dryRun"].as_bool } || (importing ? nil : scan)
      phase = if shown
                shown["phase"].as_s
              elsif running
                "import"
              elsif followup["total"].as_i64 > 0 && runs.any? { |r| !r["dryRun"].as_bool }
                "followup"
              end
      rate = importing.try(&.["booksPerMinute"]?).try(&.as_f?)
      {enabled: true, roots: imports.roots, running: running, hooksPaused: running,
       scanning: !scan.nil?, phase: phase, backlog: imports.backlog(rate), followup: followup,
       runs: runs, cleanups: cleanups}.to_json
    end

    post "/api/import" do |env|
      write_errors(env) do
        next fail(env, 404, {error: "backlog import is off"}) unless imports
        body = json_body(env)
        paths = [] of String
        body["path"]?.try { |p| paths << (p.as_s? || raise Edit::Invalid.new("path", "string expected")) }
        body["paths"]?.try do |list|
          (list.as_a? || raise Edit::Invalid.new("paths", "list of strings expected")).each do |p|
            paths << (p.as_s? || raise Edit::Invalid.new("paths", "list of strings expected"))
          end
        end
        raise Edit::Invalid.new("path", "path or paths expected") if paths.empty?
        limit = body["limit"]?.try do |l|
          next nil if l.raw.nil?
          n = l.as_i64? || raise Edit::Invalid.new("limit", "number expected")
          raise Edit::Invalid.new("limit", "1 or more expected") if n < 1
          n.clamp(1_i64, Int32::MAX.to_i64).to_i32
        end
        dry = body["dryRun"]?.try(&.as_bool?)
        dry = true if dry.nil?
        begin
          run = imports.start(paths, dry, limit)
          env.response.status_code = 202
          run.to_json
        rescue ex : ImportJobs::Busy
          fail(env, 409, {error: ex.message})
        end
      end
    end

    get "/api/import/runs/:id" do |env|
      run = imports.try(&.run(env.params.url["id"]))
      run ? run.to_json : fail(env, 404, {error: "not found"})
    end

    get "/api/import/runs/:id/report" do |env|
      report = imports.try(&.report(env.params.url["id"]))
      report ? report.to_json : fail(env, 404, {error: "not found"})
    end

    post "/api/import/cleanup" do |env|
      write_errors(env) do
        next fail(env, 404, {error: "backlog import is off"}) unless cleanup
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
        next fail(env, 404, {error: "backlog import is off"}) unless cleanup
        dry = json_body(env)["dryRun"]?.try(&.as_bool?)
        dry = true if dry.nil?
        result = cleanup.undo(env.params.url["id"], dry)
        env.response.status_code = dry ? 200 : 202
        result.to_json
      end
    end
  end
end
