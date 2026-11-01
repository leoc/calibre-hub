require "kemal"
require "./calibre_hub/calibre"
require "./calibre_hub/detector"
require "./calibre_hub/auth"
require "./calibre_hub/api"

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
    # metadata.db of the library: scan when its mtime changes, else every interval
    getter watch : String? = ENV["CALIBRE_HUB_WATCH"]?
    getter interval : Time::Span = env("CALIBRE_HUB_SCAN_INTERVAL", "900").to_i.seconds
    getter login_user : String = env("CALIBRE_HUB_LOGIN_USER", "arthur")
    # read only by serve, so scan works without them
    def login_password : String
      secret("CALIBRE_HUB_LOGIN_PASSWORD_FILE")
    end

    def session_key : Bytes
      secret("CALIBRE_HUB_SESSION_KEY_FILE").to_slice
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
      File.read(env(key)).sub(/\n+\z/, "")
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
  end

  def self.print_events(events)
    events.each { |e| puts e.to_json }
    STDOUT.flush
  end

  # Scan on start, then whenever metadata.db changes (debounced) or the
  # interval passes. Polls the mtime instead of inotify: robust across
  # filesystems and cheap. Phase 2 replaces the full scan with the trigger
  # changelog.
  def self.watch(detector : Detector, config : Config)
    spawn do
      last_mtime = nil
      last_scan = Time::UNIX_EPOCH
      loop do
        mtime = config.watch.try { |p| File.info?(p).try(&.modification_time) }
        if mtime != last_mtime || Time.utc - last_scan > config.interval
          sleep 2.seconds if last_mtime && mtime != last_mtime # let a burst of writes settle
          begin
            print_events(detector.scan)
            last_scan = Time.utc
            last_mtime = mtime
          rescue ex
            STDERR.puts "scan failed: #{ex.message}"
            sleep 10.seconds
          end
        end
        sleep 1.second
      end
    end
  end

  def self.serve(config : Config)
    calibre = config.calibre
    db = DB.open("sqlite3://#{config.state_db}")
    watch(Detector.new(calibre, db), config)

    auth = Auth.new(config.login_user, config.login_password, config.session_key,
      lifetime: config.session_days.days, secure: config.secure_cookies)
    auth_handler = AuthHandler.new(auth, config.trusted_proxies)
    use UnavailableHandler.new
    use auth_handler
    routes(calibre, auth, auth_handler, config.category_column)

    Kemal.config.host_binding = config.host
    Kemal.config.env = "production"
    Kemal.run(config.port, args: [] of String)
  end

  USAGE = <<-TXT
    usage: calibre-hub [serve|scan|--help|--version]
      serve  API on CALIBRE_HUB_HOST:CALIBRE_HUB_PORT, scans in the background
      scan   compare the library with the snapshot once, print events as JSON lines
    TXT

  def self.main(args)
    case args.first?
    when "serve", nil
      serve(Config.new)
    when "scan"
      config = Config.new
      db = DB.open("sqlite3://#{config.state_db}")
      print_events(Detector.new(config.calibre, db).scan)
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
