require "kemal"
require "./calibre_hub/calibre"
require "./calibre_hub/secret"
require "./calibre_hub/detector"
require "./calibre_hub/auth"
require "./calibre_hub/users"
require "./calibre_hub/api"
require "./calibre_hub/duplicates"
require "./calibre_hub/files"
require "./calibre_hub/epub_fix"
require "./calibre_hub/dispatcher"
require "./calibre_hub/inbox"
require "./calibre_hub/handlers/leseliste"
require "./calibre_hub/frontend"
require "./calibre_hub/security_headers"
require "./calibre_hub/body_limit"
require "./calibre_hub/cli"
require "./calibre_hub/hardcover_sync"
require "./calibre_hub/backlog_jobs"
require "./calibre_hub/import_repair"

module CalibreHub
  VERSION = "0.1.0"

  # Configuration comes from the environment (set by the NixOS module).
  # Secrets are read from files, e.g. systemd credentials.
  struct Config
    getter calibre_url : String = env("CALIBRE_HUB_CALIBRE_URL", "http://127.0.0.1:8083")
    getter calibre_user : String = env("CALIBRE_HUB_CALIBRE_USER", "calibre-hub")
    getter calibre_password : String = secret("CALIBRE_HUB_CALIBRE_PASSWORD_FILE")
    getter library_id : String? = ENV["CALIBRE_HUB_LIBRARY_ID"]?
    getter custom_columns : Array(String) = env("CALIBRE_HUB_CUSTOM_COLUMNS", "").split(',', remove_empty: true)
    # custom column shown as category tree and filterable with ?kategorie=
    getter category_column : String? = ENV["CALIBRE_HUB_CATEGORY_COLUMN"]?.presence
    getter state_db : String = env("CALIBRE_HUB_STATE_DB", "calibre-hub.sqlite")
    getter host : String = env("CALIBRE_HUB_HOST", "127.0.0.1")
    getter port : Int32 = env("CALIBRE_HUB_PORT", "8084").to_i
    # library path: metadata.db is watched (mtime) and its trigger changelog read
    getter library : String? = ENV["CALIBRE_HUB_LIBRARY"]?.presence
    # fallback reconcile interval when the changelog is missing
    getter interval : Time::Span = env("CALIBRE_HUB_SCAN_INTERVAL", "900").to_i.seconds
    # daily full reconcile, local time HH:MM
    getter reconcile_at : String = env("CALIBRE_HUB_RECONCILE_AT", "03:30")
    getter handlers_dir : String? = ENV["CALIBRE_HUB_HANDLERS_DIR"]?.presence
    getter handler_timeout : Time::Span = env("CALIBRE_HUB_HANDLER_TIMEOUT", "600").to_i.seconds
    getter max_attempts : Int32 = env("CALIBRE_HUB_HANDLER_ATTEMPTS", "10").to_i
    # executable called with subject and text when a handler is parked
    getter alert_command : String? = ENV["CALIBRE_HUB_ALERT_COMMAND"]?.presence
    getter inbox : String? = ENV["CALIBRE_HUB_INBOX"]?.presence
    getter inbox_stable : Time::Span = env("CALIBRE_HUB_INBOX_STABLE", "120").to_i.seconds
    # folders a backlog import may read (POST /api/import), ':' separated
    getter import_roots : Array(String) = env("CALIBRE_HUB_IMPORT_ROOTS", "").split(':', remove_empty: true).map(&.strip).reject(&.empty?)
    # tags the web app offers as one-click toggles
    getter fast_tags : Array(String) = env("CALIBRE_HUB_FAST_TAGS", "leseliste").split(',', remove_empty: true).map(&.strip)
    # built web app (dist/); served without login
    getter frontend : String? = ENV["CALIBRE_HUB_FRONTEND"]?.presence
    # the tag the reading list was; becomes the list "Leseliste" once
    getter list_migrate_tag : String = env("CALIBRE_HUB_LIST_MIGRATE_TAG", "leseliste")
    getter login_user : String = env("CALIBRE_HUB_LOGIN_USER", "arthur")
    # category suggestions from a local model (Ollama API)
    getter classify : Bool = env("CALIBRE_HUB_CLASSIFY", "false") == "true"
    getter classify_endpoint : String = env("CALIBRE_HUB_CLASSIFY_ENDPOINT", "http://127.0.0.1:11434")
    getter classify_model : String = env("CALIBRE_HUB_CLASSIFY_MODEL", "qwen2.5:3b")
    getter classify_threshold : Float64 = env("CALIBRE_HUB_CLASSIFY_THRESHOLD", "0.85").to_f
    # nightly run over the unsorted books, local time HH:MM; empty: none
    getter classify_schedule : String = env("CALIBRE_HUB_CLASSIFY_SCHEDULE", "03:45")
    getter classify_timeout : Time::Span = env("CALIBRE_HUB_CLASSIFY_TIMEOUT", "300").to_i.seconds
    # metadata cleanup: book file, Hardcover, DNB, Open Library; the classify model
    # (endpoint, model) only cleans up names when the rules can't decide
    getter metadata : Bool = env("CALIBRE_HUB_METADATA", "false") == "true"
    getter metadata_sources : Array(String) = env("CALIBRE_HUB_METADATA_SOURCES", "file,hardcover,dnb,openlibrary").split(',', remove_empty: true).map(&.strip)
    getter metadata_model : Bool = env("CALIBRE_HUB_METADATA_MODEL", "false") == "true"
    # nightly run over the incomplete books, local time HH:MM; empty: none
    getter metadata_nightly : String = env("CALIBRE_HUB_METADATA_NIGHTLY", "")
    getter openlibrary_url : String = env("CALIBRE_HUB_OPENLIBRARY_URL", "https://openlibrary.org")
    getter openlibrary_covers_url : String = env("CALIBRE_HUB_OPENLIBRARY_COVERS_URL", "https://covers.openlibrary.org")
    getter dnb_url : String = env("CALIBRE_HUB_DNB_URL", "https://services.dnb.de/sru/dnb")
    getter hardcover_url : String = env("CALIBRE_HUB_HARDCOVER_URL", "https://api.hardcover.app/v1/graphql")
    # pause between two requests to the same source
    getter metadata_interval : Time::Span = env("CALIBRE_HUB_METADATA_INTERVAL", "1000").to_i.milliseconds
    # embed metadata and cover into the book files after edits, debounced
    getter embed : Bool = env("CALIBRE_HUB_EMBED", "false") == "true"
    getter embed_delay : Time::Span = env("CALIBRE_HUB_EMBED_DELAY", "60").to_i.seconds
    # convert added books into a target format, keeping the original
    getter convert : Bool = env("CALIBRE_HUB_CONVERT", "false") == "true"
    getter convert_target : String = env("CALIBRE_HUB_CONVERT_TARGET", "EPUB").upcase
    getter convert_ignore : Array(String) = env("CALIBRE_HUB_CONVERT_IGNORE", "PDF,CBZ,CBR").split(',', remove_empty: true).map(&.strip.upcase)
    # Hardcover sync (hardcover_sync.cr) with the metadata source's token;
    # without write a dry run that only logs the planned writes
    getter hardcover_sync : Bool = env("CALIBRE_HUB_HARDCOVER_SYNC", "false") == "true"
    getter hardcover_sync_write : Bool = env("CALIBRE_HUB_HARDCOVER_SYNC_WRITE", "false") == "true"
    getter hardcover_sync_user : String = ENV["CALIBRE_HUB_HARDCOVER_SYNC_USER"]?.presence || env("CALIBRE_HUB_LOGIN_USER", "arthur")
    getter hardcover_sync_interval : Time::Span = env("CALIBRE_HUB_HARDCOVER_SYNC_INTERVAL", "900").to_i.seconds
    getter hardcover_sync_batch : Int32 = env("CALIBRE_HUB_HARDCOVER_SYNC_BATCH", "100").to_i
    getter hardcover_sync_read_at : Float64 = env("CALIBRE_HUB_HARDCOVER_SYNC_READ_AT", "0.98").to_f
    # duplicates: how alike two titles of one author must be (0.5..1)
    getter duplicates_threshold : Float64 = env("CALIBRE_HUB_DUPLICATES_THRESHOLD", Dedup::DEFAULT_THRESHOLD.to_s).to_f.clamp(Dedup::MIN_THRESHOLD, 1.0)
    # repair the EPUBs of added books; keep the file before the first repair as ORIGINAL_EPUB
    getter epub_fix_on_import : Bool = env("CALIBRE_HUB_EPUB_FIX_ON_IMPORT", "false") == "true"
    getter epub_fix_keep_original : Bool = env("CALIBRE_HUB_EPUB_FIX_KEEP_ORIGINAL", "true") != "false"
    # books with one of these tags (any case) are never sent to Hardcover
    getter hardcover_sync_private_tags : Array(String) = env("CALIBRE_HUB_HARDCOVER_SYNC_PRIVATE_TAGS", "Private,privat").split(',', remove_empty: true).map(&.strip)

    # read only by serve, so scan works without them
    def login_password : String
      secret("CALIBRE_HUB_LOGIN_PASSWORD_FILE")
    end

    def session_key : Bytes
      Config.secret_bytes("CALIBRE_HUB_SESSION_KEY_FILE")
    end

    # Hardcover API token: from CALIBRE_HUB_HARDCOVER_TOKEN_FILE (a systemd
    # credential), else CALIBRE_HUB_HARDCOVER_TOKEN; nil skips the source
    def hardcover_token : String?
      if path = ENV["CALIBRE_HUB_HARDCOVER_TOKEN_FILE"]?.presence
        Config.read_secret(path).strip.presence
      else
        ENV["CALIBRE_HUB_HARDCOVER_TOKEN"]?.try(&.strip).presence
      end
    end

    # API tokens (Authorization: Bearer) for the CLI, one per file
    def api_tokens : Array(String)
      env("CALIBRE_HUB_API_TOKEN_FILES", "").split(',', remove_empty: true).map do |path|
        Config.read_secret(path.strip)
      end
    end

    # The login user (admin, with the API tokens above) and the further
    # users of CALIBRE_HUB_USERS: "name:role:passwordFile[:tokenFile|...]",
    # comma separated, role admin or reader
    def accounts : Array(Auth::Account)
      others = env("CALIBRE_HUB_USERS", "").split(',', remove_empty: true).map do |entry|
        name, role, password_file, token_files = entry.strip.split(':', 4) + [""] * 3
        r = Auth::Role.parse?(role) || abort "CALIBRE_HUB_USERS: user #{name}: role admin or reader expected, not #{role.inspect}"
        abort "CALIBRE_HUB_USERS: user #{name}: password file missing" if password_file.empty?
        tokens = token_files.split('|', remove_empty: true).map { |path| Config.read_secret(path.strip) }
        Auth.account(name, Config.read_secret(password_file), r, tokens)
      end
      [Auth.account(login_user, login_password, Auth::Role::Admin, api_tokens)] + others
    end

    # readers with a reader folder of their own (users.<name>.leseliste.target),
    # who may sync their lists; comma separated
    getter sync_users : Set(String) = env("CALIBRE_HUB_SYNC_USERS", "").split(',', remove_empty: true).map(&.strip).to_set

    getter session_days : Int32 = env("CALIBRE_HUB_SESSION_DAYS", "30").to_i
    # "false" only for local development over plain http
    getter secure_cookies : Bool = env("CALIBRE_HUB_SECURE_COOKIES", "true") != "false"
    getter trusted_proxies : Array(String) = env("CALIBRE_HUB_TRUSTED_PROXIES", "127.0.0.1,::1").split(',', remove_empty: true)

    def self.env(key, default = nil) : String
      ENV[key]? || default || abort "#{key} is not set"
    end

    # Trailing newlines are dropped, like nix/init.sh does for calibre-server
    def self.secret(key) : String
      String.new(secret_bytes(key))
    end

    # byte-wise, so binary keys (not valid UTF-8) work too
    def self.secret_bytes(key) : Bytes
      read_secret_bytes(env(key))
    end

    def self.read_secret(path) : String
      Secret.read(path)
    end

    def self.read_secret_bytes(path) : Bytes
      Secret.read_bytes(path)
    end

    private def env(key, default = nil)
      Config.env(key, default)
    end

    private def secret(key)
      Config.secret(key)
    end

    def calibre : Calibre
      Calibre.new(calibre_url, calibre_user, calibre_password, library_id, custom_columns)
    end

    def metadata_db : String?
      library.try { |l| File.join(l, "metadata.db") }
    end

    def state : DB::Database
      # one connection: fibers share it, so SQLite never sees two writers
      DB.open("sqlite3://#{state_db}?max_pool_size=1&busy_timeout=5000")
    end
  end

  def self.print_events(events)
    events.each { |e| puts e.to_json }
    STDOUT.flush
  end

  # Change detection: reconcile on start (until calibre-server answers),
  # then read the changelog whenever metadata.db changes (polled mtime,
  # debounced) and at least every minute; full reconcile daily and, if the
  # triggers are missing, every interval.
  def self.detect(detector : Detector, config : Config, wake : Channel(Nil))
    spawn do
      loop do
        print_events(detector.reconcile)
        wake.send(nil) rescue nil
        break
      rescue ex
        STDERR.puts "reconcile failed: #{ex.message}"
        sleep 10.seconds
      end
      triggers = begin
        detector.library_db.try { |db| LibraryDB.triggers_installed?(db) } || false
      rescue ex
        STDERR.puts "trigger check failed: #{ex.message}"
        false
      end
      STDERR.puts "no trigger changelog in metadata.db, reconciling every #{config.interval.total_seconds.to_i} s" unless triggers
      last_mtime = nil
      last_poll = Time.utc
      last_reconcile = Time.utc
      failures = 0
      loop do
        mtime = config.metadata_db.try { |p| File.info?(p).try(&.modification_time) }
        begin
          if !triggers && Time.utc - last_reconcile > config.interval
            emit(detector.reconcile, wake)
            last_reconcile = Time.utc
          elsif reconcile_due?(config.reconcile_at, last_reconcile)
            emit(detector.reconcile, wake)
            last_reconcile = Time.utc
          elsif triggers && (mtime != last_mtime || Time.utc - last_poll > 1.minute)
            sleep 500.milliseconds if mtime != last_mtime # let a burst of writes settle
            emit(detector.poll, wake)
            last_poll = Time.utc
          end
          last_mtime = mtime
          failures = 0
        rescue ex
          failures += 1
          STDERR.puts "change detection failed (#{failures}): #{ex.message}"
          # the same changes keep failing: rebuild from a reconcile instead
          # of retrying them forever (calibre-server down fails here too)
          if failures >= 3 && !ex.is_a?(Calibre::Unavailable)
            begin
              emit(detector.reconcile, wake)
              last_reconcile = Time.utc
              failures = 0
            rescue ex2
              STDERR.puts "reconcile failed: #{ex2.message}"
            end
          end
          sleep 10.seconds
        end
        sleep 1.second
      end
    end
  end

  def self.emit(events, wake)
    print_events(events)
    wake.send(nil) unless events.empty?
  end

  def self.reconcile_due?(at : String, last : Time, now = Time.local) : Bool
    h, m = at.split(':').map(&.to_i)
    today = Time.local(now.year, now.month, now.day, h, m, location: now.location)
    now >= today && last < today
  end

  def self.dispatch(dispatcher : Dispatcher, wake : Channel(Nil))
    spawn do
      loop do
        begin
          while dispatcher.run_once > 0
          end
        rescue ex
          STDERR.puts "dispatch failed: #{ex.message}"
        end
        select
        when wake.receive
        when timeout(5.seconds)
        end
      end
    end
  end

  def self.watch_inbox(inbox : Inbox, wake : Channel(Nil))
    spawn do
      loop do
        begin
          wake.send(nil) if inbox.run_once > 0
        rescue ex
          STDERR.puts "inbox failed: #{ex.message}"
        end
        sleep 30.seconds
      end
    end
  end

  # One Hardcover client (token, pause, alerts) for the metadata source and
  # the sync; nil without a token
  def self.hardcover(config : Config, http : Meta::Http, db : DB::Database) : Meta::Hardcover?
    token = config.hardcover_token || return nil
    alert = DailyAlert.new(db, config.alert_command.try { |c| [c] })
    Meta::Hardcover.new(http, token, config.hardcover_url, alert.proc)
  end

  def self.metadata(config : Config, calibre : Calibre, writer : Writer, db : DB::Database,
                    http : Meta::Http, hardcover : Meta::Hardcover?) : MetadataJobs?
    return nil unless config.metadata
    if bad = config.metadata_sources.find { |s| !Metadata::SOURCES.includes?(s) }
      abort "CALIBRE_HUB_METADATA_SOURCES: unknown source #{bad}"
    end
    ollama = config.metadata_model ? Ollama.new(config.classify_endpoint, config.classify_model, config.classify_timeout, 2, 2.seconds) : nil
    if config.metadata_sources.includes?("hardcover")
      puts "metadata: no Hardcover token, source hardcover skipped" unless hardcover
    else
      hardcover = nil
    end
    m = Metadata.new(calibre, writer, MetaLog.new(db), config.metadata_sources,
      Meta::OpenLibrary.new(http, config.openlibrary_url, config.openlibrary_covers_url),
      Meta::Dnb.new(http, config.dnb_url), http, ollama, nightly: config.metadata_nightly.presence, hardcover: hardcover)
    jobs = MetadataJobs.new(db, calibre, writer, m)
    jobs.watch_events
    config.metadata_nightly.presence.try { |at| jobs.schedule(at) }
    puts "metadata: sources #{m.active_sources.join(", ")}#{ollama ? ", names cleaned with #{config.classify_model}" : ""}"
    jobs
  end

  def self.classify(config : Config, calibre : Calibre, writer : Writer, db : DB::Database,
                    metadata : MetadataJobs? = nil) : ClassifyJobs?
    return nil unless config.classify
    column = config.category_column || begin
      STDERR.puts "classify: needs a category column, off"
      return nil
    end
    ollama = Ollama.new(config.classify_endpoint, config.classify_model, config.classify_timeout)
    c = Classify.new(calibre, writer, column, Suggestions.new(db), ollama, config.classify_threshold)
    jobs = ClassifyJobs.new(db, calibre, writer, c)
    # a new book is classified after its metadata run, on clean names
    metadata.try { |m| jobs.ready = ->(event : Int64, book : Int64, at : Time) { m.ready_for_classify?(event, book, at) } }
    jobs.watch_events
    config.classify_schedule.presence.try { |at| jobs.schedule(at) }
    puts "classify: #{config.classify_model} at #{config.classify_endpoint}, auto-apply from #{config.classify_threshold}"
    jobs
  end

  # Metadata embedded into the files after edits (when on); conversion of
  # added books (when on) and of the library on request (always)
  def self.book_files(config : Config, calibre : Calibre, writer : Writer, db : DB::Database,
                      detector : Detector, wake : Channel(Nil)) : {Embedder?, ConvertJobs}
    unless ConvertJobs::TARGETS.includes?(config.convert_target)
      abort "CALIBRE_HUB_CONVERT_TARGET: one of #{ConvertJobs::TARGETS.join(", ")}"
    end
    embedder = if config.embed
                 e = Embedder.new(db, calibre, config.library, config.embed_delay, detector, wake)
                 writer.on_cover = ->(id : Int64) { e.enqueue(id, force: true); nil }
                 e.start
                 puts "embed: metadata into the files #{config.embed_delay.total_seconds.to_i} s after the last edit"
                 e
               end
    convert = ConvertJobs.new(db, calibre, writer, config.convert_target, config.convert_ignore, config.convert)
    if config.convert
      convert.watch_events
      puts "convert: added books to #{config.convert_target} (not from #{config.convert_ignore.join(", ")})"
    end
    {embedder, convert}
  end

  # Lists: deleted books leave them; the reading list tag becomes a list
  # once (retried until calibre-server answers)
  def self.lists(config : Config, calibre : Calibre, db : DB::Database, wake : Channel(Nil)) : Lists
    exists = ->(ids : Array(Int64)) { calibre.books(ids, ["title"]).map(&.id) }
    # magic shelves: newest in the library first
    search = ->(q : String, limit : Int32) do
      r = calibre.search(q, "timestamp", false, 0, limit)
      {r.total.to_i64, r.ids}
    end
    lists = Lists.new(db, exists, wake, search, config.category_column)
    lists.watch_events
    unless lists.migrated?
      spawn do
        loop do
          tag = config.list_migrate_tag
          tagged = calibre.search(%(tags:"=#{Api.escape(tag)}"), "timestamp", true, 0, 1_000_000).ids
          lists.migrate(config.login_user, tag, tagged)
          break
        rescue ex
          STDERR.puts "lists: migrating the tag failed, retrying: #{ex.message}"
          sleep 10.seconds
        end
      end
    end
    lists
  end

  def self.hardcover_sync(config : Config, calibre : Calibre, db : DB::Database, progress : Progress,
                          hardcover : Meta::Hardcover?) : HardcoverSync?
    return nil unless config.hardcover_sync
    unless hardcover
      STDERR.puts "hardcover sync: no Hardcover token, off"
      return nil
    end
    sync = HardcoverSync.new(db, calibre, progress, hardcover, config.hardcover_sync_user, config.hardcover_sync_write,
      config.hardcover_sync_read_at, config.hardcover_sync_batch, config.hardcover_sync_interval,
      config.hardcover_sync_private_tags)
    sync.start
    puts "hardcover sync: progress of #{config.hardcover_sync_user} every #{config.hardcover_sync_interval.total_seconds.to_i} s, " \
         "#{config.hardcover_sync_write ? "writing" : "dry run (planned writes only logged)"}"
    sync
  end

  def self.serve(config : Config)
    calibre = config.calibre
    db = config.state
    detector = Detector.new(calibre, db, config.metadata_db)
    wake = Channel(Nil).new(1)
    detect(detector, config, wake)
    alert = config.alert_command.try { |c| [c] }
    env = {"CALIBRE_HUB_LIBRARY" => config.library || ""}
    dispatch(Dispatcher.new(db, config.handlers_dir, env, config.max_attempts, config.handler_timeout, alert), wake)
    inbox = config.inbox.try { |dir| Inbox.new(dir, calibre, detector, config.category_column, config.inbox_stable) }

    auth = Auth.new(config.accounts, config.session_key, lifetime: config.session_days.days, secure: config.secure_cookies)
    Users.new(db).sync(auth.accounts)
    puts "users: #{auth.accounts.map { |a| "#{a.name} (#{a.role})" }.join(", ")}"
    auth_handler = AuthHandler.new(auth, config.trusted_proxies, config.sync_users)
    use SecurityHeadersHandler.new
    use UnavailableHandler.new
    # before the frontend and the login (AuthHandler reads list bodies)
    use BodyLimitHandler.new
    config.frontend.try { |dir| use FrontendHandler.new(dir) }
    use auth_handler
    writer = Writer.new(calibre, detector, wake, config.category_column)
    lists = lists(config, calibre, db, wake)
    # in the request that submits the job, so the lists of its user
    members = ->(p : HTTP::Params) { Api.list_members(lists, auth.user, p) }
    private_tags = PrivateTags.new(db)
    private_tags.watch_events
    # {query: {ptag}} targets: the private tags of the request's user
    tagged = ->(tags : Array(String)) { private_tags.books(auth.user, tags) }
    # one per host interval for the metadata sources and the sync
    http = Meta::Http.new(config.metadata_interval)
    hardcover = hardcover(config, http, db)
    metadata_jobs = metadata(config, calibre, writer, db, http, hardcover)
    classify_jobs = classify(config, calibre, writer, db, metadata_jobs)
    jobs = Jobs.new(db, calibre, writer, config.category_column)
    [jobs, metadata_jobs, classify_jobs].compact.each { |j| j.list_members = members; j.private_books = tagged }
    trash = Trash.new(calibre, writer, config.library, db)
    trash.on_restore = ->(old_id : Int64, new_id : Int64) { lists.book_restored(old_id, new_id); private_tags.book_restored(old_id, new_id); nil }
    dups = Duplicates.new(calibre, writer, db, config.library, config.category_column, lists, trash, config.duplicates_threshold)
    dups.private_tags = private_tags
    # uploads and the inbox look for duplicates the same way as the page
    writer.similar = ->(id : Int64) { dups.similar(id) }
    inbox.try do |i|
      i.on_import = ->(id : Int64) do
        found = dups.similar(id)
        puts "inbox: ##{id} looks like #{found.map { |b| "##{b.id}" }.join(", ")} (see Duplikate)" unless found.empty?
      end
      watch_inbox(i, wake)
    end
    embedder, convert_jobs = book_files(config, calibre, writer, db, detector, wake)
    progress = Progress.new(db)
    hardcover_sync(config, calibre, db, progress, hardcover)
    epub_fix = EpubFixJobs.new(db, calibre, writer, config.library, config.epub_fix_on_import,
      config.epub_fix_keep_original, detector, wake)
    if config.epub_fix_on_import
      epub_fix.watch_events
      puts "epub-fix: EPUBs of added books are repaired"
    end
    imports = config.import_roots.empty? ? nil : ImportJobs.new(db, calibre, writer, config.import_roots, config.library)
    imports.try { |i| puts "backlog import: roots #{i.roots.join(", ")}" }
    # the hooks that work off imported books, for the import's followup
    imports.try do |i|
      i.followup = [
        metadata_jobs && ImportJobs::FollowupHook.new("metadata", "metadata_event_seq", "added", jobs: "metadata_jobs"),
        classify_jobs && ImportJobs::FollowupHook.new("classify", "classify_event_seq", "added", jobs: "classify_jobs"),
        config.convert ? ImportJobs::FollowupHook.new("convert", "convert_event_seq", "added", jobs: "convert_jobs") : nil,
        embedder && ImportJobs::FollowupHook.new("embed", "embed_event_seq", "changed", queue: "embed_queue"),
      ].compact
    end
    cleanup = config.category_column ? ImportCleanup.new(db, calibre, writer, config.category_column, File.dirname(File.expand_path(config.state_db))) : nil
    # metadata of books imported from plain files before the import read file names
    repair = imports ? ImportRepair.new(db, calibre, writer, metadata_jobs.try(&.metadata.log) || MetaLog.new(db)) : nil
    repair.try &.metadata = metadata_jobs
    # selections from the command palette ({query} like bulk edits)
    [convert_jobs, epub_fix].each do |j|
      j.list_members = members
      j.private_books = tagged
      j.category_column = config.category_column
    end
    # the metadata cleanup edits no category, but its {query} targets filter by it
    metadata_jobs.try &.category_column = config.category_column
    routes(calibre, auth, auth_handler, config.category_column, config.fast_tags,
      writer, jobs, trash, classify_jobs, metadata_jobs, lists, [convert_jobs, epub_fix, imports, imports.try(&.scans), cleanup, repair].compact.map(&.as(Jobs)), progress, ReaderSettings.new(db), private_tags)
    file_routes(convert_jobs, embedder)
    duplicate_routes(dups, auth)
    epub_fix_routes(epub_fix)
    import_routes(imports, cleanup)
    import_repair_routes(repair)

    Kemal.config.host_binding = config.host
    Kemal.config.env = "production"
    # the frontend comes from FrontendHandler; Kemal's own static handler
    # (./public, before the AuthHandler) stays off
    Kemal.config.serve_static = false
    Kemal.run(config.port, args: [] of String)
  end

  USAGE = <<-TXT
    usage: calibre-hub <command>
      serve                       API, change detection, handlers, inbox (default)
      scan                        reconcile with the library once, print events as JSON lines
      install-triggers <db>       create the changelog triggers in metadata.db
                                  (only while calibre-server is stopped)
      handler leseliste           mirror the reading list (event JSON on stdin)
      cli <command>               command line client for a running hub (the `hub`
                                  binary is the same client plus `hub tui`)
      --help, --version
    TXT

  def self.main(args)
    case args.first?
    when "cli"
      exit Cli.run(args[1..])
    when "serve", nil
      serve(Config.new)
    when "scan"
      config = Config.new
      print_events(Detector.new(config.calibre, config.state, config.metadata_db).reconcile)
    when "install-triggers"
      path = args[1]? || abort USAGE
      LibraryDB.install_triggers(path)
      puts "triggers installed in #{path}"
    when "handler"
      case args[1]?
      when "leseliste" then exit Leseliste.run
      else                  abort USAGE
      end
    when "--help", "-h", "help"
      puts USAGE
    when "--version"
      puts VERSION
    else
      abort USAGE
    end
  end
end

CalibreHub.main(ARGV)
