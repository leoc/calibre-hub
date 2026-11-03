require "http"
require "json"

module CalibreHub
  # Request bodies have a size limit before anything reads them, also before
  # the login (review #8411 M3): routes read JSON bodies whole, so without a
  # limit a single request could fill the memory.
  #
  # - book upload (POST /api/books) and cover upload (PUT .../cover):
  #   checked by Content-Length here, the routes stream with their own limit
  #   (Writer::MAX_UPLOAD, Covers::MAX_BYTES)
  # - the login: LOGIN_MAX
  # - everything else (JSON): JSON_MAX, enough for id lists of a whole library
  # Small bodies are read here and handed on as a string; more than the
  # limit, announced or sent, is 413.
  class BodyLimitHandler
    include HTTP::Handler

    LOGIN_MAX  = 64 * 1024
    JSON_MAX   = 1024 * 1024
    UPLOAD_MAX = 201_i64 * 1024 * 1024 # Writer::MAX_UPLOAD + form fields
    COVER_MAX  = 11_i64 * 1024 * 1024  # Covers::MAX_BYTES + slack

    def self.limit(method : String, path : String) : Int64?
      return UPLOAD_MAX if method == "POST" && path == "/api/books"
      return COVER_MAX if method == "PUT" && path.matches?(%r{\A/api/books/\d+/cover\z})
      return LOGIN_MAX.to_i64 if path == "/api/session"
      nil
    end

    def call(context)
      req = context.request
      body = req.body
      return call_next(context) unless body
      max = BodyLimitHandler.limit(req.method, req.path)
      if (len = req.headers["Content-Length"]?.try(&.to_i64?)) && len > (max || JSON_MAX)
        return too_large(context)
      end
      # streamed by the route with its own limit
      return call_next(context) if max && max > JSON_MAX

      max = (max || JSON_MAX).to_i64
      buf = IO::Memory.new
      return too_large(context) if IO.copy(body, buf, max + 1) > max
      req.body = buf.to_s
      call_next(context)
    end

    private def too_large(context)
      res = context.response
      res.status_code = 413
      res.content_type = "application/json"
      res.headers["Connection"] = "close"
      res.print({error: "request body too large"}.to_json)
    end
  end
end
