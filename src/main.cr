require "kemal"
require "./calibre_hub/calibre"
require "./calibre_hub/detector"
require "./calibre_hub/auth"
require "./calibre_hub/api"
require "./calibre_hub/dispatcher"
require "./calibre_hub/inbox"
require "./calibre_hub/handlers/leseliste"
require "./calibre_hub/frontend"
require "./calibre_hub/cli"

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
    # tags the web app offers as one-click toggles
    getter fast_tags : Array(String) = env("CALIBRE_HUB_FAST_TAGS", "leseliste").split(',', remove_empty: true).map(&.strip)
    # built web app (dist/); served without login
    getter frontend : String? = ENV["CALIBRE_HUB_FRONTEND"]?.presence
    getter login_user : String = env("CALIBRE_HUB_LOGIN_USER", "arthur")
    # category suggestions from a local model (Ollama API)
    getter classify : Bool = env("CALIBRE_HUB_CLASSIFY", "false") == "true"
    getter classify_endpoint : String = env("CALIBRE_HUB_CLASSIFY_ENDPOINT", "http://127.0.0.1:11434")
    getter classify_model : String = env("CALIBRE_HUB_CLASSIFY_MODEL", "qwen2.5:3b")
    getter classify_threshold : Float64 = env("CALIBRE_HUB_CLASSIFY_THRESHOLD", "0.85").to_f
    # nightly run over the unsorted books, local time HH:MM; empty: none
    getter classify_schedule : String = env("CALIBRE_HUB_CLASSIFY_SCHEDULE", "03:45")
    getter classify_timeout : Time::Span = env("CALIBRE_HUB_CLASSIFY_TIMEOUT", "300").to_i.seconds
    # read only by serve, so scan works without them
    def login_password : String
      secret("CALIBRE_HUB_LOGIN_PASSWORD_FILE")
    end

    def session_key : Bytes
      Config.secret_bytes("CALIBRE_HUB_SESSION_KEY_FILE")
    end

    # API tokens (Authorization: Bearer) for the CLI, one per file
    def api_tokens : Array(String)
      env("CALIBRE_HUB_API_TOKEN_FILES", "").split(',', remove_empty: true).map do |path|
        Config.read_secret(path.strip)
      end
    end

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
      String.new(read_secret_bytes(path))
    end

    def self.read_secret_bytes(path) : Bytes
      bytes = File.open(path, &.getb_to_end)
      size = bytes.size
      while size > 0 && bytes[size - 1] == '\n'.ord
        size -= 1
      end
      bytes[0, size]
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

  def self.classify(config : Config, calibre : Calibre, writer : Writer, db : DB::Database) : ClassifyJobs?
    return nil unless config.classify
    column = config.category_column || begin
      STDERR.puts "classify: needs a category column, off"
      return nil
    end
    ollama = Ollama.new(config.classify_endpoint, config.classify_model, config.classify_timeout)
    c = Classify.new(calibre, writer, column, Suggestions.new(db), ollama, config.classify_threshold)
    jobs = ClassifyJobs.new(db, calibre, writer, c)
    jobs.watch_events
    config.classify_schedule.presence.try { |at| jobs.schedule(at) }
    puts "classify: #{config.classify_model} at #{config.classify_endpoint}, auto-apply from #{config.classify_threshold}"
    jobs
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
    config.inbox.try { |dir| watch_inbox(Inbox.new(dir, calibre, detector, config.category_column, config.inbox_stable), wake) }

    auth = Auth.new(config.login_user, config.login_password, config.session_key,
      lifetime: config.session_days.days, secure: config.secure_cookies, tokens: config.api_tokens)
    auth_handler = AuthHandler.new(auth, config.trusted_proxies)
    use UnavailableHandler.new
    config.frontend.try { |dir| use FrontendHandler.new(dir) }
    use auth_handler
    writer = Writer.new(calibre, detector, wake, config.category_column)
    routes(calibre, auth, auth_handler, config.category_column, config.fast_tags,
      writer, Jobs.new(db, calibre, writer, config.category_column), Trash.new(calibre, writer, config.library, db),
      classify(config, calibre, writer, db))

    Kemal.config.host_binding = config.host
    Kemal.config.env = "production"
    Kemal.run(config.port, args: [] of String)
  end

  USAGE = <<-TXT
    usage: calibre-hub <command>
      serve                       API, change detection, handlers, inbox (default)
      scan                        reconcile with the library once, print events as JSON lines
      install-triggers <db>       create the changelog triggers in metadata.db
                                  (only while calibre-server is stopped)
      handler leseliste           mirror the reading list (event JSON on stdin)
      cli <command>               command line client for a running hub (also as `hub`)
      --help, --version
    TXT

  def self.main(args)
    # the package links the binary as `hub`, which is the CLI
    exit Cli.run(args) if File.basename(PROGRAM_NAME) == "hub"
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
