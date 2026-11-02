require "db"
require "digest/md5"
require "digest/sha1"
require "file_utils"
require "json"
require "./calibre"
require "./backlog_pause"
require "./detector"
require "./library_db"
require "./writer"

module CalibreHub
  # The book files themselves: metadata embedded into them after edits
  # (Embedder) and formats converted for new books (ConvertJobs). Both go
  # through calibre-server; the hub never writes the library.
  module BookFiles
    # Formats calibre has a metadata writer for (calibre 9.14, MetadataWriterPlugin)
    WRITABLE = %w(EPUB KEPUB AZW3 AZW MOBI PRC AZW4 PDF DOCX FB2 FBZ HTMLZ ODT RTF TXTZ PDB)
    # calibre-server embeds the metadata into these when it serves them
    SERVED = %w(EPUB AZW3 MOBI PDF)

    # KOReader's partial MD5 (util.partialMD5, the document id KOSync uses):
    # 1 KiB at 256 B, 1 KiB, 4 KiB, ... 1 GiB, until the file ends
    def self.partial_md5(path : String) : String
      File.open(path) do |f|
        size = f.size
        d = Digest::MD5.new
        buf = Bytes.new(1024)
        (-1..10).each do |i|
          offset = i < 0 ? 256_i64 : 1024_i64 << (2 * i)
          break if offset >= size
          f.seek(offset)
          n = 0
          while n < buf.size
            r = f.read(buf[n..])
            break if r == 0
            n += r
          end
          break if n == 0
          d.update(buf[0, n])
        end
        d.hexfinal
      end
    end

    # Downloads a format through calibre-server
    def self.download(calibre : Calibre, id : Int64, fmt : String, dest : String)
      File.open(dest, "w") do |io|
        calibre.forward("GET", "/get/#{fmt.downcase}/#{id}#{calibre.library_suffix}") do |r|
          raise Writer::NotFound.new("no #{fmt} for book #{id}") if r.status_code == 404
          raise Calibre::Unavailable.new("calibre-server /get: HTTP #{r.status_code}") if r.status_code >= 500
          raise Calibre::Error.new("calibre-server /get: HTTP #{r.status_code}") unless r.success?
          IO.copy(r.body_io, io)
        end
      end
    end

    # Runs a command, killed after timeout; {ok, output}
    def self.run(cmd : String, args : Array(String), timeout : Time::Span) : {Bool, String}
      output = IO::Memory.new
      process = Process.new(cmd, args, env: {"QT_QPA_PLATFORM" => "offscreen"}, output: output, error: output)
      done = Channel(Process::Status).new(1)
      spawn { done.send(process.wait) }
      select
      when status = done.receive
        {status.success?, output.to_s}
      when timeout(timeout)
        process.terminate rescue nil
        {false, "timeout after #{timeout.total_seconds.to_i} s"}
      end
    rescue ex : File::Error | IO::Error
      {false, ex.message || "#{cmd} failed"}
    end

    # KOReader partial MD5s a file had before the hub rewrote it, oldest
    # first per book and format (the original), for KOSync mappings
    def self.create_checksums(db : DB::Database)
      db.exec <<-SQL
        create table if not exists file_checksums (
          book_id integer not null,
          format text not null,
          partial_md5 text not null,
          size integer not null,
          recorded_at integer not null,
          primary key (book_id, format, partial_md5)
        )
        SQL
    end

    # The files of a book in the library (format -> path), read from
    # metadata.db; empty without a library path
    def self.library_files(library : String?, id : Int64) : Hash(String, String)
      files = {} of String => String
      library || return files
      ldb = LibraryDB.open_read_only(File.join(library, "metadata.db"))
      begin
        ldb.query_each("select b.path, d.format, d.name from books b join data d on d.book = b.id where b.id = ?", id) do |rs|
          path, fmt, name = rs.read(String, String, String)
          files[fmt.upcase] = File.join(library, path, "#{name}.#{fmt.downcase}")
        end
      ensure
        ldb.close
      end
      files
    end

    # The KOReader checksums of a book's files before they change
    def self.remember_checksums(db : DB::Database, library : String?, id : Int64, fmts : Array(String))
      return unless library
      files = library_files(library, id)
      now = Time.utc.to_unix
      fmts.each do |f|
        file = files[f]? || next
        next unless File.exists?(file)
        db.exec "insert or ignore into file_checksums (book_id, format, partial_md5, size, recorded_at) values (?, ?, ?, ?, ?)",
          id, f, partial_md5(file), File.size(file), now
      rescue ex : File::Error
        STDERR.puts "files: ##{id} #{f}: checksum not kept: #{ex.message}"
      end
    end

    # The files changed, the metadata didn't: a changed event with the same
    # formats on both sides, so handlers (the reading list) copy the files again
    def self.files_changed(detector : Detector?, wake : Channel(Nil)?, book : Book)
      d = detector || return
      formats = JSON.parse(book.formats.to_json)
      d.record([Event.new("changed", book.id, changes: {"formats" => [formats, formats]}, book: JSON.parse(book.to_json))])
      if w = wake
        select
        when w.send(nil)
        else
        end
      end
    end

    def self.tmpdir(&)
      dir = File.join(Dir.tempdir, "calibre-hub-#{Random::Secure.hex(6)}")
      Dir.mkdir(dir)
      begin
        yield dir
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end

  # Embeds the current metadata and cover into a book's files after an edit,
  # so a file copied to a reader shows what calibre shows. Follows the event
  # queue (cursor embed_event_seq): a changed event touching an embedded
  # field, or new formats, queues the book; a cover set through the hub
  # queues it too (covers don't show in events). The queue lives in the
  # state DB (embed_queue); every new change moves the book's due time, so
  # several quick edits end in one embed. A book embedded with the same
  # metadata before is skipped (embed_state), unless a cover or a new
  # format came along.
  #
  # Embedding goes through calibre-server (cdb embed_metadata), only into
  # formats calibre can write. calibre embeds nothing into a book without a
  # cover, so for those the formats calibre-server embeds on download
  # (EPUB, AZW3, MOBI, PDF) are downloaded and added back.
  #
  # Before a file is rewritten its KOReader partial MD5 is kept in
  # file_checksums, so reading positions synced under the old checksum can
  # be mapped later. Afterwards a changed event with formats (the same list
  # on both sides: the files changed) tells handlers to copy the file again.
  class Embedder
    FIELDS       = %w(title authors authorSort series seriesIndex tags comments identifiers languages publisher pubdate rating)
    MAX_ATTEMPTS = 8

    getter delay : Time::Span

    def initialize(@db : DB::Database, @calibre : Calibre, @library : String?, @delay : Time::Span = 1.minute,
                   @detector : Detector? = nil, @wake : Channel(Nil)? = nil)
      @db.exec "create table if not exists meta (key text primary key, value text)"
      @db.exec <<-SQL
        create table if not exists embed_queue (
          book_id integer primary key,
          due_at integer not null,
          force integer not null default 0,
          attempts integer not null default 0,
          last_error text
        )
        SQL
      @db.exec "create table if not exists embed_state (book_id integer primary key, fingerprint text not null, embedded_at integer not null)"
      BookFiles.create_checksums(@db)
    end

    # Follows the events and works off the due books
    def start(interval = 2.seconds)
      if cursor.nil?
        max = @db.query_one("select coalesce(max(id), 0) from events", as: Int64)
        @db.exec "insert or replace into meta (key, value) values ('embed_event_seq', ?)", max.to_s
      end
      spawn do
        loop do
          begin
            follow_events
            run_due
          rescue ex
            STDERR.puts "embed: #{ex.message}"
          end
          sleep interval
        end
      end
    end

    def cursor : Int64?
      @db.query_one?("select value from meta where key = 'embed_event_seq'", as: String).try(&.to_i64)
    end

    # force: embed even when the metadata is the same as last time
    def enqueue(id : Int64, force = false, now = Time.utc)
      @db.exec <<-SQL, id, (now + @delay).to_unix, force ? 1 : 0
        insert into embed_queue (book_id, due_at, force) values (?, ?, ?)
          on conflict(book_id) do update set due_at = excluded.due_at,
            force = max(force, excluded.force), attempts = 0, last_error = null
        SQL
    end

    def pending : Int64
      @db.query_one("select count(*) from embed_queue", as: Int64)
    end

    # Does the event change what is embedded? {queue?, force?}
    def self.relevant(type : String, changes : Hash(String, JSON::Any)?) : {Bool, Bool}
      return {false, false} unless type == "changed" && changes
      if f = changes["formats"]?
        old = f[0]?.try(&.as_a?).try(&.map(&.to_s)) || [] of String
        new = f[1]?.try(&.as_a?).try(&.map(&.to_s)) || [] of String
        return {true, true} unless (new - old).empty?
      end
      {changes.keys.any? { |k| FIELDS.includes?(k) }, false}
    end

    def follow_events(now = Time.utc)
      return if Backlog.paused?(@db)
      from = cursor || 0_i64
      rows = [] of {Int64, String, Int64, String}
      @db.query_each("select id, type, book_id, payload from events where id > ? order by id limit 500", from) do |rs|
        rows << rs.read(Int64, String, Int64, String)
      end
      return if rows.empty?
      rows.each do |_, type, book_id, payload|
        if type == "deleted"
          @db.exec "delete from embed_queue where book_id = ?", book_id
          next
        end
        next unless type == "changed"
        changes = JSON.parse(payload)["changes"]?.try(&.as_h?)
        queue, force = Embedder.relevant(type, changes)
        enqueue(book_id, force, now) if queue
      end
      @db.exec "insert or replace into meta (key, value) values ('embed_event_seq', ?)", rows.last[0].to_s
    end

    # Embeds the books that are due; returns how many were handled
    def run_due(now = Time.utc) : Int32
      due = [] of {Int64, Int64, Bool, Int32}
      @db.query_each("select book_id, due_at, force, attempts from embed_queue where due_at <= ? order by due_at limit 50", now.to_unix) do |rs|
        due << {rs.read(Int64), rs.read(Int64), rs.read(Int64) == 1, rs.read(Int32)}
      end
      due.each do |id, due_at, force, attempts|
        begin
          result = embed(id, force)
          puts "embed: ##{id} #{result}"
          # changed again meanwhile: the row has a later due time and stays
          @db.exec "delete from embed_queue where book_id = ? and due_at = ?", id, due_at
        rescue ex : Calibre::Unavailable
          STDERR.puts "embed: #{ex.message}"
          break
        rescue ex
          attempts += 1
          if attempts >= MAX_ATTEMPTS
            STDERR.puts "embed: ##{id} given up after #{attempts} attempts: #{ex.message}"
            @db.exec "delete from embed_queue where book_id = ? and due_at = ?", id, due_at
          else
            STDERR.puts "embed: ##{id} failed (attempt #{attempts}): #{ex.message}"
            retry_at = now + (30.seconds * (2 ** (attempts - 1))).clamp(30.seconds, 1.hour)
            @db.exec "update embed_queue set due_at = ?, attempts = ?, last_error = ? where book_id = ? and due_at = ?",
              retry_at.to_unix, attempts, ex.message, id, due_at
          end
        end
      end
      due.size
    end

    # Embeds the metadata of one book into its files; returns what happened
    def embed(id : Int64, force = false) : String
      book = @calibre.book(id) || return "gone"
      fmts = book.formats.map(&.upcase).select { |f| BookFiles::WRITABLE.includes?(f) }
      return "skipped, no format calibre can write (#{book.formats.join(", ")})" if fmts.empty?
      fp = Embedder.fingerprint(book)
      if !force && @db.query_one?("select fingerprint from embed_state where book_id = ?", id, as: String) == fp
        return "unchanged"
      end
      if @calibre.has_cover?(id)
        remember_checksums(id, fmts)
        @calibre.cmd("embed_metadata", [JSON::Any.new(id), JSON.parse(fmts.map(&.downcase).to_json)])
      else
        fmts = fmts.select { |f| BookFiles::SERVED.includes?(f) }
        return "skipped, no cover and no format calibre-server embeds into" if fmts.empty?
        remember_checksums(id, fmts)
        BookFiles.tmpdir do |dir|
          fmts.each do |f|
            file = File.join(dir, "book.#{f.downcase}")
            BookFiles.download(@calibre, id, f, file)
            @calibre.add_format(id, file, f.downcase)
          end
        end
      end
      @db.exec "insert or replace into embed_state (book_id, fingerprint, embedded_at) values (?, ?, ?)", id, fp, Time.utc.to_unix
      notify(book)
      "embedded into #{fmts.join(", ")}"
    end

    def self.fingerprint(book : Book) : String
      json = JSON.parse(book.to_json)
      Digest::SHA1.hexdigest(FIELDS.map { |f| json[f]?.try(&.to_json) || "null" }.join("\n"))
    end

    # The KOReader checksums of the files before they change
    def remember_checksums(id : Int64, fmts : Array(String))
      BookFiles.remember_checksums(@db, @library, id, fmts)
    end

    private def notify(book : Book)
      BookFiles.files_changed(@detector, @wake, book)
    end
  end

  # Converts books into a target format (EPUB by default), keeping their
  # formats and adding the new one through calibre-server. Automatically for
  # added books when enabled (cursor convert_event_seq), for the whole
  # library through POST /api/convert. A queue of its own.
  class ConvertJobs < Jobs
    TARGETS = %w(EPUB AZW3 MOBI PDF DOCX FB2)
    # better sources first; any other format not ignored comes after these
    SOURCES = %w(EPUB AZW3 KEPUB MOBI AZW AZW4 PRC FB2 FBZ DOCX ODT HTMLZ RTF TXTZ TXT MD MARKDOWN HTML HTM LIT PDB DJVU PDF)

    getter target : String
    getter ignore : Array(String)
    getter enabled : Bool

    def initialize(db : DB::Database, calibre : Calibre, writer : Writer, target : String, ignore : Array(String),
                   @enabled : Bool, @timeout : Time::Span = 15.minutes)
      @target = target.upcase
      @ignore = ignore.map(&.upcase)
      super(db, calibre, writer, nil, "convert_jobs")
    end

    # The format to convert from, nil when the book has the target already
    # or nothing to convert
    def self.source(formats : Array(String), target : String, ignore : Array(String)) : String?
      fmts = formats.map(&.upcase)
      return nil if fmts.includes?(target)
      candidates = fmts.reject { |f| ignore.includes?(f) || f.starts_with?("ORIGINAL_") }
      SOURCES.find { |f| candidates.includes?(f) } || candidates.first?
    end

    def source(formats : Array(String), target = @target) : String?
      ConvertJobs.source(formats, target, @ignore)
    end

    def self.target!(value : JSON::Any?, default : String) : String
      t = value.try { |v| v.raw.nil? ? nil : (v.as_s? || raise Edit::Invalid.new("target", "format expected")) }
      t = (t.presence || default).upcase
      raise Edit::Invalid.new("target", "one of #{TARGETS.join(", ")}") unless TARGETS.includes?(t)
      t
    end

    # Every book that lacks the target and has something to convert
    def submit_target(target : JSON::Any?) : Job
      t = ConvertJobs.target!(target, @target)
      ids = @calibre.list("", ["formats"]).select { |b| source(b.formats, t) }.map(&.id)
      enqueue(ids, {"target" => JSON::Any.new(t), "from" => JSON::Any.new("library")})
    end

    def watch_events(interval = 10.seconds)
      if cursor.nil?
        max = @db.query_one("select coalesce(max(id), 0) from events", as: Int64)
        @db.exec "insert or replace into meta (key, value) values ('convert_event_seq', ?)", max.to_s
      end
      spawn do
        loop do
          begin
            follow_events
          rescue ex
            STDERR.puts "convert: events: #{ex.message}"
          end
          sleep interval
        end
      end
    end

    def cursor : Int64?
      @db.query_one?("select value from meta where key = 'convert_event_seq'", as: String).try(&.to_i64)
    end

    # Added books (inbox, upload, calibre) without the target format
    def follow_events
      return if Backlog.paused?(@db)
      from = cursor || 0_i64
      rows = [] of {Int64, String, Int64, String}
      @db.query_each("select id, type, book_id, payload from events where id > ? order by id limit 500", from) do |rs|
        rows << rs.read(Int64, String, Int64, String)
      end
      return if rows.empty?
      ids = rows.compact_map do |_, type, book_id, payload|
        next unless type == "added"
        formats = JSON.parse(payload)["book"]?.try(&.["formats"]?).try(&.as_a?).try(&.map(&.to_s)) || [] of String
        book_id if source(formats)
      end
      unless ids.empty?
        job = enqueue(ids.uniq, {"target" => JSON::Any.new(@target), "from" => JSON::Any.new("added")})
        puts "convert: job #{job.id} for #{job.total} new books"
      end
      @db.exec "insert or replace into meta (key, value) values ('convert_event_seq', ?)", rows.last[0].to_s
    end

    protected def apply(job : Job, index : Int32, id : Int64, resumed : Bool)
      t = job.changes["target"]?.try(&.as_s?) || @target
      book = @calibre.book(id) || raise Writer::NotFound.new
      from = source(book.formats, t) || return
      convert(book, from, t)
    rescue ex : Calibre::Unavailable
      raise Abort.new(ex.message)
    end

    def convert(book : Book, from : String, to : String)
      BookFiles.tmpdir do |dir|
        src = File.join(dir, "source.#{from.downcase}")
        dst = File.join(dir, "#{book.id}.#{to.downcase}")
        BookFiles.download(@calibre, book.id, from, src)
        # the downloaded file may not carry calibre's metadata (TXT, DOCX)
        args = [src, dst, "--title", book.title]
        args += ["--authors", book.authors.join(" & ")] unless book.authors.empty?
        ok, log = BookFiles.run("ebook-convert", args, @timeout)
        unless ok && File.exists?(dst)
          raise "ebook-convert #{from} -> #{to}: #{log.lines.reject(&.blank?).last? || "failed"}"
        end
        @calibre.add_format(book.id, dst, to.downcase)
        @writer.written([book.id])
        puts "convert: ##{book.id} #{book.title}: #{from} -> #{to}"
      end
    end
  end

  # POST /api/convert, GET /api/convert/status, GET /api/embed/status
  def self.file_routes(convert : ConvertJobs, embedder : Embedder?)
    get "/api/embed/status" do
      next {enabled: false}.to_json unless embedder
      {enabled: true, delay: embedder.delay.total_seconds.to_i, pending: embedder.pending}.to_json
    end

    get "/api/convert/status" do
      last = convert.last.try do |job, started|
        JSON.parse(job.to_json).as_h.merge({"startedAt" => JSON::Any.new(started.to_rfc3339),
                                            "target" => job.changes["target"]? || JSON::Any.new(nil)})
      end
      {enabled: convert.enabled, target: convert.target, ignore: convert.ignore, targets: ConvertJobs::TARGETS,
       running: convert.running?, lastRun: last}.to_json
    end

    post "/api/convert" do |env|
      write_errors(env) do
        body = json_body(env)
        job = convert.submit_target(body["target"]?)
        env.response.status_code = 202
        {jobId: job.id, total: job.total}.to_json
      end
    end
  end
end
