require "base64"
require "crypto/subtle"
require "json"
require "openssl/hmac"
require "http"

module CalibreHub
  # Single-user login. The session is a signed cookie, so nothing is stored
  # server side: "<base64 payload>.<base64 hmac>", payload {"u": user, "exp": unix}.
  # Sliding expiry: every authenticated request re-issues the cookie.
  class Auth
    COOKIE = "hub_session"
    # Unsafe methods need this header; a cross-site form cannot set it.
    CSRF_HEADER = "X-Calibre-Hub"

    getter user : String

    def initialize(@user : String, @password : String, @key : Bytes,
                   @lifetime : Time::Span = 30.days, @secure : Bool = true,
                   @limiter : RateLimiter = RateLimiter.new)
    end

    def check_password(user : String, password : String) : Bool
      # compare both in constant time, also when the user is wrong
      user_ok = Crypto::Subtle.constant_time_compare(user, @user)
      password_ok = Crypto::Subtle.constant_time_compare(password, @password)
      user_ok && password_ok
    end

    # Login with rate limiting per client IP. Returns the cookie or nil.
    def login(ip : String, user : String, password : String) : HTTP::Cookie?
      raise RateLimiter::Limited.new if @limiter.blocked?(ip)
      if check_password(user, password)
        @limiter.reset(ip)
        cookie
      else
        @limiter.fail(ip)
        nil
      end
    end

    def cookie(now = Time.utc) : HTTP::Cookie
      payload = Base64.urlsafe_encode({u: @user, exp: (now + @lifetime).to_unix}.to_json, padding: false)
      HTTP::Cookie.new(COOKIE, "#{payload}.#{sign(payload)}",
        path: "/", expires: now + @lifetime, http_only: true, secure: @secure,
        samesite: HTTP::Cookie::SameSite::Strict)
    end

    def expired_cookie : HTTP::Cookie
      HTTP::Cookie.new(COOKIE, "", path: "/", expires: Time::UNIX_EPOCH, http_only: true,
        secure: @secure, samesite: HTTP::Cookie::SameSite::Strict)
    end

    # The user of a valid session cookie, else nil
    def session_user(value : String?, now = Time.utc) : String?
      return nil unless value
      payload, _, signature = value.partition('.')
      return nil if payload.empty? || signature.empty?
      return nil unless Crypto::Subtle.constant_time_compare(signature, sign(payload))
      data = JSON.parse(Base64.decode_string(payload))
      return nil if data["exp"].as_i64 < now.to_unix
      data["u"].as_s
    rescue Base64::Error | JSON::ParseException | KeyError | TypeCastError
      nil
    end

    # HTTP Basic for OPDS clients (KOReader can't do cookies)
    def basic_user(ip : String, header : String?) : String?
      return nil unless header && header.starts_with?("Basic ")
      raise RateLimiter::Limited.new if @limiter.blocked?(ip)
      user, _, password = Base64.decode_string(header.lchop("Basic ")).partition(':')
      if check_password(user, password)
        user
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

  # Failed logins per IP in a sliding window, in memory (one process, one user)
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
