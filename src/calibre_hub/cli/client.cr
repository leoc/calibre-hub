require "http/client"
require "json"
require "uri"

module CalibreHub
  module Cli
    # Error answer of the hub; body is its JSON ({error, field?, ...})
    class HttpError < Failure
      getter status : Int32
      getter body : JSON::Any

      def initialize(@status : Int32, @body : JSON::Any)
        super(HttpError.code(status), HttpError.message(status, body),
          {"status" => JSON::Any.new(status.to_i64), "response" => body})
      end

      def self.code(status : Int32) : Int32
        case status
        when 401, 403, 429 then AUTH
        when 404           then NOT_FOUND
        when 409           then CONFLICT
        when 400..499      then USAGE
        else                    SERVER
        end
      end

      def self.message(status : Int32, body : JSON::Any) : String
        error = body["error"]?.try(&.as_s?) || "HTTP #{status}"
        field = body["field"]?.try(&.as_s?).presence
        text = field ? "#{field}: #{error}" : error
        case status
        when 401 then "not authorized: #{text} (check the API token)"
        when 404 then "not found"
        else          text
        end
      end
    end

    # JSON API client with an API token (Authorization: Bearer)
    class Client
      DEFAULT_URL  = "https://hub.nor.sh"
      DEFAULT_FILE = "calibre-hub/token"

      getter base : URI

      def initialize(url : String, @token : String, @read_timeout : Time::Span = 5.minutes)
        @base = URI.parse(url)
        unless {"http", "https"}.includes?(@base.scheme) && @base.host.presence
          raise Usage.new("CALIBRE_HUB_URL must be an http(s) URL: #{url}")
        end
      end

      # CALIBRE_HUB_URL; token from CALIBRE_HUB_TOKEN, CALIBRE_HUB_TOKEN_FILE
      # or ~/.config/calibre-hub/token
      def self.from_env(env : Hash(String, String)) : Client
        url = env["CALIBRE_HUB_URL"]?.presence || DEFAULT_URL
        new(url, token(env))
      end

      def self.token(env : Hash(String, String)) : String
        if t = env["CALIBRE_HUB_TOKEN"]?.presence
          return t.strip
        end
        if path = env["CALIBRE_HUB_TOKEN_FILE"]?.presence
          return read_token(path) || raise Failure.new(AUTH, "cannot read token file #{path}")
        end
        config = env["XDG_CONFIG_HOME"]?.presence || env["HOME"]?.try { |h| File.join(h, ".config") }
        path = config.try { |c| File.join(c, DEFAULT_FILE) }
        path.try { |p| read_token(p) } ||
          raise Failure.new(AUTH, "no API token: set CALIBRE_HUB_TOKEN or CALIBRE_HUB_TOKEN_FILE, or put it into #{path || "~/.config/#{DEFAULT_FILE}"}")
      end

      private def self.read_token(path : String) : String?
        File.read(path).strip.presence
      rescue File::Error
        nil
      end

      def get(path : String, params : HTTP::Params? = nil) : JSON::Any
        json("GET", params && !params.empty? ? "#{path}?#{params}" : path)
      end

      def patch(path : String, body) : JSON::Any
        json("PATCH", path, body.to_json, HTTP::Headers{"Content-Type" => "application/json"})
      end

      def post(path : String, body) : JSON::Any
        json("POST", path, body.to_json, HTTP::Headers{"Content-Type" => "application/json"})
      end

      # body may be a file (sent with its length); returns the parsed answer
      def json(method : String, path : String, body : String | IO | Nil = nil,
               headers = HTTP::Headers.new) : JSON::Any
        exec(method, path, body, headers) do |r|
          text = r.body_io.gets_to_end
          parsed = text.empty? ? JSON::Any.new(nil) : (JSON.parse(text) rescue JSON::Any.new({"error" => JSON::Any.new(text.strip[0, 200])}))
          raise HttpError.new(r.status_code, parsed) unless r.success?
          parsed
        end
      end

      # binary answers (files, covers); errors are raised before the block
      def download(path : String, & : HTTP::Client::Response ->)
        exec("GET", path) do |r|
          unless r.success?
            text = r.body_io.gets_to_end
            raise HttpError.new(r.status_code, (JSON.parse(text) rescue JSON::Any.new({} of String => JSON::Any)))
          end
          yield r
        end
      end

      private def exec(method, path, body = nil, headers = HTTP::Headers.new, &)
        headers["Authorization"] = "Bearer #{@token}"
        headers["Accept"] ||= "application/json"
        headers["User-Agent"] = "calibre-hub-cli"
        client = HTTP::Client.new(@base)
        client.connect_timeout = 15.seconds
        client.read_timeout = @read_timeout
        begin
          client.exec(method, @base.path.rstrip('/') + path, headers, body) { |r| yield r }
        ensure
          client.close
        end
      rescue ex : Socket::Error | IO::TimeoutError | OpenSSL::SSL::Error
        raise Failure.new(SERVER, "cannot reach #{@base}: #{ex.message}")
      end
    end
  end
end
