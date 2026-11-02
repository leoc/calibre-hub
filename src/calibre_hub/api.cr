require "kemal"
require "./calibre"
require "./auth"
require "./writer"

module CalibreHub
  module Api
    SORTS = {
      "title"     => "title",
      "author"    => "author_sort",
      "added"     => "timestamp",
      "modified"  => "last_modified",
      "published" => "pubdate",
      "series"    => "series",
      "rating"    => "rating",
    }
    DEFAULT_LIMIT =  50
    MAX_LIMIT     = 500

    # Turns the structured filters plus an optional raw calibre query into one
    # calibre search expression.
    def self.query(params : HTTP::Params, kategorie_column : String?) : String
      parts = [] of String
      parts << "(#{params["q"]})" if params["q"]?.presence
      # "=." matches the value and everything below it in a hierarchy
      if (k = params["kategorie"]?.presence) && kategorie_column
        parts << %(##{kategorie_column}:"=.#{escape(k)}")
      end
      params.fetch_all("tag").each { |t| parts << %(tags:"=#{escape(t)}") }
      params["author"]?.presence.try { |a| parts << %(authors:"=#{escape(a)}") }
      params["series"]?.presence.try { |s| parts << %(series:"=#{escape(s)}") }
      parts.join(" and ")
    end

    def self.escape(value : String) : String
      value.gsub('\\', "\\\\").gsub('"', "\\\"")
    end

    # "Fachbuch.Software.Architektur" counts -> nested nodes; a node counts
    # its own books plus those below it
    def self.tree(items : Array(NamedTuple(name: String, count: Int32))) : Array(JSON::Any)
      root = {} of String => Hash(String, JSON::Any)
      nodes = {} of String => Hash(String, JSON::Any)
      items.sort_by(&.[:name]).each do |item|
        path = [] of String
        item[:name].split('.').each do |part|
          path << part
          key = path.join('.')
          node = nodes[key] ||= begin
            n = {"name" => JSON::Any.new(part), "path" => JSON::Any.new(key),
                 "count" => JSON::Any.new(0_i64), "children" => JSON::Any.new([] of JSON::Any)}
            if path.size == 1
              root[key] = n
            else
              nodes[path[0..-2].join('.')]["children"].as_a << JSON::Any.new(n)
            end
            n
          end
          node["count"] = JSON::Any.new(node["count"].as_i64 + item[:count])
        end
      end
      root.values.map { |n| JSON::Any.new(n) }
    end
  end

  # Maps calibre-server outages to 502 with a JSON body
  class UnavailableHandler
    include HTTP::Handler

    def call(context)
      call_next(context)
    rescue ex : Calibre::Unavailable
      STDERR.puts ex.message
      context.response.status_code = 502
      context.response.content_type = "application/json"
      context.response.print %({"error":"calibre-server unavailable"})
    end
  end

  # Session for /api/*, Basic for the OPDS passthrough, CSRF header for
  # unsafe methods. Re-issues the cookie on every authenticated API request.
  class AuthHandler
    include HTTP::Handler

    PUBLIC = {"/healthz"}

    def initialize(@auth : Auth, @trusted_proxies : Array(String))
    end

    def call(context)
      req = context.request
      path = req.path
      return call_next(context) if PUBLIC.includes?(path)

      if path.starts_with?("/opds") || path.starts_with?("/get/")
        return call_next(context) if @auth.basic_user(client_ip(context), req.headers["Authorization"]?)
        context.response.headers["WWW-Authenticate"] = %(Basic realm="calibre-hub")
        return deny(context, 401, "login required")
      end

      unless {"GET", "HEAD", "OPTIONS"}.includes?(req.method) || req.headers[Auth::CSRF_HEADER]?
        return deny(context, 403, "missing #{Auth::CSRF_HEADER} header")
      end

      return call_next(context) if path == "/api/session" && req.method == "POST"

      if @auth.session_user(req.cookies[Auth::COOKIE]?.try(&.value))
        context.response.cookies << @auth.cookie unless path == "/api/session" && req.method == "DELETE"
        call_next(context)
      else
        deny(context, 401, "login required")
      end
    rescue RateLimiter::Limited
      deny(context, 429, "too many failed logins")
    end

    def client_ip(context) : String
      remote = context.request.remote_address.as?(Socket::IPAddress).try(&.address) || "unknown"
      if @trusted_proxies.includes?(remote)
        # the proxy appends the client it saw as the last entry
        context.request.headers["X-Forwarded-For"]?.try(&.split(',').last.strip) || remote
      else
        remote
      end
    end

    private def deny(context, status, message)
      context.response.status_code = status
      context.response.content_type = "application/json"
      context.response.print({error: message}.to_json)
    end
  end

  def self.routes(calibre : Calibre, auth : Auth, auth_handler : AuthHandler, kategorie : String?,
                  fast_tags = [] of String, writer : Writer? = nil, jobs : Jobs? = nil)
    before_all("/api/*") { |env| env.response.content_type = "application/json" }

    get "/healthz" { "ok" }

    post "/api/session" do |env|
      body = JSON.parse(env.request.body.try(&.gets_to_end) || "{}") rescue JSON.parse("{}")
      user = body["user"]?.try(&.as_s?) || ""
      password = body["password"]?.try(&.as_s?) || ""
      if cookie = auth.login(auth_handler.client_ip(env), user, password)
        env.response.cookies << cookie
        {user: auth.user}.to_json
      else
        halt env, 401, %({"error":"wrong user or password"})
      end
    rescue RateLimiter::Limited
      halt env, 429, %({"error":"too many failed logins"})
    end

    get "/api/session" { {user: auth.user}.to_json }

    get "/api/config" { {fastTags: fast_tags, categoryColumn: kategorie}.to_json }

    delete "/api/session" do |env|
      env.response.cookies << auth.expired_cookie
      env.response.status_code = 204
      nil
    end

    get "/api/books" do |env|
      p = env.params.query
      sort = Api::SORTS[p["sort"]? || "title"]? || halt(env, 400, %({"error":"unknown sort"}))
      ascending = p["order"]? != "desc"
      offset = (p["offset"]?.try(&.to_i?) || 0).clamp(0, Int32::MAX)
      limit = (p["limit"]?.try(&.to_i?) || Api::DEFAULT_LIMIT).clamp(1, Api::MAX_LIMIT)
      result = calibre.search(Api.query(p, kategorie), sort, ascending, offset, limit)
      {total: result.total, offset: offset, limit: limit, books: calibre.books(result.ids)}.to_json
    end

    get "/api/books/:id" do |env|
      id = env.params.url["id"].to_i64? || halt(env, 404, %({"error":"not found"}))
      calibre.book(id).try(&.to_json) || halt(env, 404, %({"error":"not found"}))
    end

    get "/api/books/:id/cover" do |env|
      id = env.params.url["id"].to_i64? || halt(env, 404, %({"error":"not found"}))
      path = env.params.query["size"]? == "thumb" ? "/get/thumb/#{id}?sz=300x400" : "/get/cover/#{id}"
      CalibreHub.stream(env, calibre, path)
    end

    get "/api/books/:id/download/:format" do |env|
      id = env.params.url["id"].to_i64? || halt(env, 404, %({"error":"not found"}))
      format = env.params.url["format"].downcase
      halt(env, 404, %({"error":"not found"})) unless format.matches?(/\A[a-z0-9]+\z/)
      CalibreHub.stream(env, calibre, "/get/#{format}/#{id}")
    end

    get "/api/categories" do |env|
      cats = calibre.categories
      list = ->(key : String) { (cats[key]? || [] of NamedTuple(name: String, count: Int32)).map { |c| {name: c[:name], count: c[:count]} } }
      {
        kategorie: kategorie ? Api.tree(cats["##{kategorie}"]? || [] of NamedTuple(name: String, count: Int32)) : [] of JSON::Any,
        tags:      list.call("tags"),
        authors:   list.call("authors"),
        series:    list.call("series"),
        languages: list.call("languages"),
      }.to_json
    end

    if (w = writer) && (j = jobs)
      write_routes(w, j)
    end

    # OPDS for reader apps; its links point to /opds/* and /get/*
    {"/opds", "/opds/*", "/get/*"}.each do |route|
      get route do |env|
        path = env.request.resource
        CalibreHub.stream(env, calibre, path, passthrough_headers: true)
      end
    end
  end

  def self.write_routes(writer : Writer, jobs : Jobs)
    # before /api/books/:id so "bulk" isn't taken for an id
    post "/api/books/bulk" do |env|
      write_errors(env) do
        body = JSON.parse(env.request.body.try(&.gets_to_end) || "").as_h? || raise Edit::Invalid.new("", "JSON object expected")
        job = jobs.submit(body)
        env.response.status_code = 202
        {jobId: job.id, total: job.total}.to_json
      end
    end

    put "/api/books/:id/cover" do |env|
      write_errors(env) do
        id = env.params.url["id"].to_i64? || raise Writer::NotFound.new
        body = env.request.body || raise Edit::Invalid.new("", "image expected")
        data = IO::Memory.new
        raise Writer::TooLarge.new if IO.copy(body, data, Covers::MAX_BYTES + 1) > Covers::MAX_BYTES
        writer.set_cover(id, data.to_slice).to_json
      end
    end

    post "/api/books/:id/cover/from-file" do |env|
      write_errors(env) do
        id = env.params.url["id"].to_i64? || raise Writer::NotFound.new
        body = JSON.parse(env.request.body.try(&.gets_to_end).presence || "{}")
        writer.cover_from_file(id, body["format"]?.try(&.as_s?)).to_json
      end
    end

    post "/api/books/:id/cover/from-url" do |env|
      write_errors(env) do
        id = env.params.url["id"].to_i64? || raise Writer::NotFound.new
        body = JSON.parse(env.request.body.try(&.gets_to_end).presence || "{}")
        url = body["url"]?.try(&.as_s?) || raise Edit::Invalid.new("url", "URL expected")
        writer.cover_from_url(id, url).to_json
      end
    end

    get "/api/books/:id/cover/search" do |env|
      write_errors(env) do
        id = env.params.url["id"].to_i64? || raise Writer::NotFound.new
        book = writer.calibre.book(id) || raise Writer::NotFound.new
        Covers.search(book, env.params.query["q"]?).to_json
      end
    end

    get "/api/jobs/:id" do |env|
      jobs[env.params.url["id"]]?.try(&.to_json) || fail(env, 404, {error: "not found"})
    end

    patch "/api/books/:id" do |env|
      write_errors(env) do
        id = env.params.url["id"].to_i64? || raise Writer::NotFound.new
        body = JSON.parse(env.request.body.try(&.gets_to_end) || "").as_h? || raise Edit::Invalid.new("", "JSON object expected")
        writer.update(id, body).to_json
      end
    end

    post "/api/books" do |env|
      write_errors(env) do
        upload = Writer.read_upload(env.request)
        begin
          book, created = writer.upload(upload)
          env.response.status_code = created ? 201 : 200
          {book: book}.to_json
        ensure
          File.delete?(upload.file)
        end
      end
    end
  end

  # Maps the writer's errors to the API's {error, field?} bodies. Closes the
  # response like Kemal's halt, so Kemal's own error pages don't replace it.
  def self.write_errors(env, &)
    yield
  rescue ex : JSON::ParseException
    fail(env, 400, {error: "invalid JSON: #{ex.message}"})
  rescue ex : Edit::Invalid
    fail(env, 400, {error: ex.message, field: ex.field})
  rescue Writer::NotFound
    fail(env, 404, {error: "not found"})
  rescue ex : Writer::Conflict
    fail(env, 409, {error: "changed in the meantime", book: ex.book})
  rescue ex : Writer::Duplicates
    fail(env, 409, {error: "duplicate", duplicates: ex.books, titles: ex.titles})
  rescue ex : Writer::Unsupported
    fail(env, 415, {error: ex.message})
  rescue ex : Writer::NoCover
    fail(env, 422, {error: ex.message})
  rescue Writer::TooLarge
    fail(env, 413, {error: "too large", limit: env.request.path.includes?("/cover") ? Covers::MAX_BYTES : Writer::MAX_UPLOAD})
  end

  def self.fail(env, status : Int32, body) : Nil
    env.response.status_code = status
    env.response.print body.to_json
    env.response.close
  end

  HOP_HEADERS = %w(connection keep-alive transfer-encoding te trailer upgrade proxy-authenticate proxy-authorization)

  def self.stream(env, calibre : Calibre, path : String, passthrough_headers = false)
    headers = HTTP::Headers.new
    {"If-None-Match", "If-Modified-Since", "Range", "Accept"}.each do |h|
      env.request.headers[h]?.try { |v| headers[h] = v }
    end
    calibre.forward("GET", path, headers) do |r|
      env.response.status_code = r.status_code
      r.headers.each do |k, v|
        next if HOP_HEADERS.includes?(k.downcase) || k.downcase == "set-cookie" || k.downcase == "www-authenticate"
        next unless passthrough_headers || {"content-type", "content-length", "etag", "last-modified",
                                            "cache-control", "content-disposition"}.includes?(k.downcase)
        env.response.headers[k] = v
      end
      IO.copy(r.body_io, env.response) if r.body_io?
    end
    nil
  end
end
