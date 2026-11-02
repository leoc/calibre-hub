require "base64"
require "crypto/subtle"
require "json"
require "openssl/hmac"
require "digest/sha256"
require "http"

class Fiber
  # the hub user of the request this fiber serves (Auth#as_user)
  property calibre_hub_user : String?
end

module CalibreHub
  # Login of the hub users (admins and readers, from the configuration).
  # The session is a signed cookie, so nothing is stored server side:
  # "<base64 payload>.<base64 hmac>", payload {"u": user, "exp": unix}.
  # Sliding expiry: every authenticated request re-issues the cookie. The
  # role is looked up on every request, so a changed role or a removed user
  # takes effect at once.
  class Auth
    COOKIE = "hub_session"
    # Unsafe methods need this header; a cross-site form cannot set it.
    CSRF_HEADER = "X-Calibre-Hub"

    # API tokens must be at least this long, so they can't be guessed
    MIN_TOKEN = 16

    # Admin: everything; reader: reads, plus own lists, progress and
    # reader settings
    enum Role
      Admin
      Reader

      def to_s : String
        admin? ? "admin" : "reader"
      end

      def to_s(io : IO) : Nil
        io << to_s
      end
    end

    # A user who may log in. Password and API tokens as SHA-256 digests, so
    # they're compared in the same time whatever their length.
    record Account, name : String, role : Role, password : Bytes, tokens : Array(Bytes)

    # Raised by #user outside of a request when there are several users
    class NoUser < Exception
    end

    # tokens: API tokens for the CLI and scripts, same rights as the user
    def self.account(name : String, password : String, role : Role = Role::Admin, tokens = [] of String) : Account
      raise ArgumentError.new("user name missing") if name.empty?
      raise ArgumentError.new("user #{name}: password missing") if password.empty?
      if short = tokens.find { |t| t.size < MIN_TOKEN }
        raise ArgumentError.new("API token shorter than #{MIN_TOKEN} characters (#{short.size})")
      end
      Account.new(name, role, Digest::SHA256.digest(password), tokens.map { |t| Digest::SHA256.digest(t) })
    end

    # One admin, as before there were several users
    def self.new(user : String, password : String, key : Bytes, lifetime : Time::Span = 30.days, secure : Bool = true,
                 limiter : RateLimiter = RateLimiter.new, tokens : Array(String) = [] of String)
      new([account(user, password, Role::Admin, tokens)], key, lifetime, secure, limiter)
    end

    getter accounts : Array(Account)

    def initialize(@accounts : Array(Account), @key : Bytes, @lifetime : Time::Span = 30.days,
                   @secure : Bool = true, @limiter : RateLimiter = RateLimiter.new)
      raise ArgumentError.new("no users") if @accounts.empty?
      names = @accounts.map(&.name)
      if dup = names.find { |n| names.count(n) > 1 }
        raise ArgumentError.new("user #{dup} configured twice")
      end
      tokens = @accounts.flat_map(&.tokens)
      raise ArgumentError.new("an API token is configured twice") if tokens.uniq.size != tokens.size
    end

    # The user of the current request (set by AuthHandler). With a single
    # user that one, as before; with several, outside of a request an error
    # rather than a guess.
    def user : String
      Fiber.current.calibre_hub_user || (@accounts.size == 1 ? @accounts.first.name : raise NoUser.new("no user for this request"))
    end

    # Runs the block as the user (#user), e.g. one request
    def as_user(name : String, &)
      fiber = Fiber.current
      before = fiber.calibre_hub_user
      fiber.calibre_hub_user = name
      begin
        yield
      ensure
        fiber.calibre_hub_user = before
      end
    end

    def role(name : String = user) : Role?
      @accounts.find { |a| a.name == name }.try(&.role)
    end

    def admin?(name : String = user) : Bool
      role(name).try(&.admin?) || false
    end

    # "Authorization: Bearer <token>" for the CLI; failures count like logins
    def bearer_user(ip : String, header : String?) : String?
      return nil unless Auth.bearer?(header)
      raise RateLimiter::Limited.new if @limiter.blocked?(ip)
      given = Digest::SHA256.digest(header.not_nil!.lchop("Bearer ").strip)
      # compares all tokens, so the timing doesn't tell which one matched
      found = nil
      @accounts.each do |a|
        a.tokens.each { |t| found = a.name if Crypto::Subtle.constant_time_compare(t, given) }
      end
      @limiter.fail(ip) unless found
      found
    end

    def self.bearer?(header : String?) : Bool
      !!header.try(&.starts_with?("Bearer "))
    end

    def check_password(user : String, password : String) : Bool
      !authenticate(user, password).nil?
    end

    # compares with every user in constant time, so the timing tells
    # neither whether the user exists nor which one it is
    private def authenticate(user : String, password : String) : Account?
      given = Digest::SHA256.digest(password)
      found = nil
      @accounts.each do |a|
        ok = Crypto::Subtle.constant_time_compare(a.name, user) & Crypto::Subtle.constant_time_compare(a.password, given)
        found = a if ok
      end
      found
    end

    # Login with rate limiting per client IP. Returns the cookie or nil.
    def login(ip : String, user : String, password : String) : HTTP::Cookie?
      raise RateLimiter::Limited.new if @limiter.blocked?(ip)
      if account = authenticate(user, password)
        @limiter.reset(ip)
        cookie(user: account.name)
      else
        @limiter.fail(ip)
        nil
      end
    end

    def cookie(now = Time.utc, user : String = self.user) : HTTP::Cookie
      payload = Base64.urlsafe_encode({u: user, exp: (now + @lifetime).to_unix}.to_json, padding: false)
      HTTP::Cookie.new(COOKIE, "#{payload}.#{sign(payload)}",
        path: "/", expires: now + @lifetime, http_only: true, secure: @secure,
        samesite: HTTP::Cookie::SameSite::Strict)
    end

    def expired_cookie : HTTP::Cookie
      HTTP::Cookie.new(COOKIE, "", path: "/", expires: Time::UNIX_EPOCH, http_only: true,
        secure: @secure, samesite: HTTP::Cookie::SameSite::Strict)
    end

    # The user of a valid session cookie, else nil (also when the user is
    # no longer configured)
    def session_user(value : String?, now = Time.utc) : String?
      return nil unless value
      payload, _, signature = value.partition('.')
      return nil if payload.empty? || signature.empty?
      return nil unless Crypto::Subtle.constant_time_compare(signature, sign(payload))
      data = JSON.parse(Base64.decode_string(payload))
      return nil if data["exp"].as_i64 < now.to_unix
      name = data["u"].as_s
      role(name) ? name : nil
    rescue Base64::Error | JSON::ParseException | KeyError | TypeCastError
      nil
    end

    # HTTP Basic for OPDS clients (KOReader can't do cookies)
    def basic_user(ip : String, header : String?) : String?
      return nil unless header && header.starts_with?("Basic ")
      raise RateLimiter::Limited.new if @limiter.blocked?(ip)
      user, _, password = Base64.decode_string(header.lchop("Basic ")).partition(':')
      if account = authenticate(user, password)
        account.name
      else
        @limiter.fail(ip)
        nil
      end
    rescue Base64::Error
      nil
    end

    private def sign(payload : String) : String
      Base64.urlsafe_encode(OpenSSL::HMAC.digest(:sha256, @key, payload), padding: false)
    end
  end

  # Failed logins per IP in a sliding window, in memory (one process)
  class RateLimiter
    class Limited < Exception
    end

    def initialize(@max_failures = 5, @window : Time::Span = 15.minutes)
      @failures = {} of String => Array(Time)
      @mutex = Mutex.new
    end

    def blocked?(ip : String, now = Time.utc) : Bool
      @mutex.synchronize { recent(ip, now).size >= @max_failures }
    end

    def fail(ip : String, now = Time.utc)
      @mutex.synchronize { @failures[ip] = recent(ip, now) << now }
    end

    def reset(ip : String)
      @mutex.synchronize { @failures.delete(ip) }
    end

    private def recent(ip, now)
      (@failures[ip]? || [] of Time).select { |t| now - t < @window }
    end
  end
end
