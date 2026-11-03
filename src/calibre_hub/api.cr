require "kemal"
require "./calibre"
require "./auth"
require "./writer"
require "./trash"
require "./classify"
require "./metadata"
require "./lists"
require "./opds"
require "./progress"
require "./reader_settings"

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
      params["q"]?.try(&.strip).presence.try { |q| parts << "(#{q})" }
      # "=." matches the value and everything below it in a hierarchy
      if (k = params["kategorie"]?.presence) && kategorie_column
        parts << %(##{kategorie_column}:"=.#{escape(k)}")
      end
      params.fetch_all("tag").each { |t| parts << %(tags:"=#{escape(t)}") unless t.empty? }
      params["author"]?.presence.try { |a| parts << %(authors:"=#{escape(a)}") }
      params["series"]?.presence.try { |s| parts << %(series:"=#{escape(s)}") }
      parts.join(" and ")
    end

    # Books of a list, filtered and sorted: {total, ids of the page}.
    # sort: listAdded (default, newest first), title, author, series; the
    # other filters of GET /api/books apply too. The list's sublists count
    # in, unless direct=1. Without a list id: listPath (and listOwner,
    # default the user) names a node, also one without a list of its own.
    def self.list_page(lists : Lists, calibre : Calibre, user : String, p : HTTP::Params,
                       kategorie : String?, offset : Int32, limit : Int32) : {Int32, Array(Int64)}
      sort = p["sort"]?.presence || "listAdded"
      raise Edit::Invalid.new("sort", "one of #{Lists::SORTS.join(", ")}") unless Lists::SORTS.includes?(sort)
      members = list_members(lists, user, p)
      query = query(p, kategorie)
      ids = if sort == "listAdded"
              ordered = p["order"]? == "asc" ? members.reverse : members
              if query.empty?
                ordered
              else
                found = calibre.search(query, "id", true, 0, 1_000_000).ids.to_set
                ordered.select { |id| found.includes?(id) }
              end
            else
              set = members.to_set
              calibre.search(query, SORTS[sort], p["order"]? != "desc", 0, 1_000_000).ids.select { |id| set.includes?(id) }
            end
      {ids.size, ids[offset, limit]? || [] of Int64}
    end

    # list or listPath given (GET /api/books, bulk targets)
    def self.list_query?(p : HTTP::Params) : Bool
      !!(p["list"]?.presence || p["listPath"]?.presence)
    end

    # The books of list=<id> or listPath=<path>[&listOwner=], most recently
    # added first, with the sublists unless direct=1
    def self.list_members(lists : Lists, user : String, p : HTTP::Params) : Array(Int64)
      direct = {"1", "true"}.includes?(p["direct"]?)
      node = if id = p["list"]?.presence
               l = lists[id.to_i64? || raise(Lists::NotFound.new), user]
               lists.node(l.owner, l.name, user, direct)
             else
               path = Lists.levels(p["listPath"]? || "").join(Lists::SEPARATOR).presence || raise Lists::NotFound.new
               all = lists.node(p["listOwner"]?.presence || user, path, user)
               raise Lists::NotFound.new if all.empty?
               direct ? all.select { |x| Lists.same?(x.name, path) } : all
             end
      lists.members(node)
    end

    # Adds the ids of the user's lists to each book
    def self.with_lists(books : Array(Book), lists : Lists?, user : String) : Array(Book)
      return books unless lists
      m = lists.memberships(books.map(&.id), user)
      books.map do |b|
        b.lists = m[b.id]? || [] of Int64
        b
      end
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

  # Session or API token for /api/*, Basic for the OPDS passthrough, CSRF
  # header for unsafe methods unless only a token is sent. Re-issues the
  # cookie on every request authenticated by the session. The request runs
  # as its user (Auth#user); a reader's writes stop here with 403 unless
  # they only touch the reader's own things (.reader_may?).
  class AuthHandler
    include HTTP::Handler

    PUBLIC = {"/healthz"}
    SAFE   = {"GET", "HEAD", "OPTIONS"}

    def initialize(@auth : Auth, @trusted_proxies : Array(String))
    end

    def call(context)
      req = context.request
      path = req.path
      return call_next(context) if PUBLIC.includes?(path)

      if path.starts_with?("/opds") || path.starts_with?("/get/")
        if user = @auth.basic_user(client_ip(context), req.headers["Authorization"]?)
          return serve(context, user)
        end
        context.response.headers["WWW-Authenticate"] = %(Basic realm="calibre-hub")
        return deny(context, 401, "login required")
      end

      authorization = req.headers["Authorization"]?
      bearer = Auth.bearer?(authorization)
      # A browser never adds a bearer token on its own, so token requests
      # need no CSRF header; once a cookie comes along they do again.
      csrf_exempt = bearer && !req.headers.has_key?("Cookie")
      unless SAFE.includes?(req.method) || req.headers[Auth::CSRF_HEADER]? || csrf_exempt
        return deny(context, 403, "missing #{Auth::CSRF_HEADER} header")
      end

      # a token is never mixed with the session: wrong token, no fallback
      if bearer
        if user = @auth.bearer_user(client_ip(context), authorization)
          return serve(context, user)
        end
        return deny(context, 401, "invalid token")
      end

      return call_next(context) if path == "/api/session" && req.method == "POST"

      if user = @auth.session_user(req.cookies[Auth::COOKIE]?.try(&.value))
        context.response.cookies << @auth.cookie(user: user) unless path == "/api/session" && req.method == "DELETE"
        serve(context, user)
      else
        deny(context, 401, "login required")
      end
    rescue RateLimiter::Limited
      deny(context, 429, "too many failed logins")
    end

    private def serve(context, user : String)
      unless @auth.admin?(user) || AuthHandler.reader_may?(context.request)
        return deny(context, 403, "only admins can change the library")
      end
      @auth.as_user(user) { call_next(context) }
    end

    # A reader reads everything and changes only their own things: lists,
    # reading progress, reader settings; and logs out. Syncing a list to
    # the reader folder (the admin's e-reader), on or off, is the admin's
    # call. Every
    # other write, also of routes added later, is for admins.
    def self.reader_may?(req : HTTP::Request) : Bool
      return true if SAFE.includes?(req.method)
      path = req.path
      return true if path == "/api/session" && req.method == "DELETE"
      return true if path == "/api/reader/settings" || path.matches?(%r{\A/api/books/\d+/progress\z})
      return false unless path == "/api/lists" || path.starts_with?("/api/lists/")
      !sets_sync?(req)
    end

    # Reads the body and puts it back for the route
    private def self.sets_sync?(req : HTTP::Request) : Bool
      body = req.body.try(&.gets_to_end) || ""
      req.body = body
      JSON.parse(body).as_h?.try(&.has_key?("sync")) || false
    rescue JSON::ParseException | TypeCastError
      false
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
                  fast_tags = [] of String, writer : Writer? = nil, jobs : Jobs? = nil, trash : Trash? = nil,
                  classify : ClassifyJobs? = nil, metadata : MetadataJobs? = nil, lists : Lists? = nil,
                  extra_jobs = [] of Jobs, progress : Progress? = nil,
                  reader_settings : ReaderSettings? = nil)
    before_all("/api/*") { |env| env.response.content_type = "application/json" }

    get "/healthz" { "ok" }

    post "/api/session" do |env|
      body = JSON.parse(env.request.body.try(&.gets_to_end) || "{}") rescue JSON.parse("{}")
      user = body["user"]?.try(&.as_s?) || ""
      password = body["password"]?.try(&.as_s?) || ""
      if cookie = auth.login(auth_handler.client_ip(env), user, password)
        env.response.cookies << cookie
        {user: user, role: auth.role(user).to_s}.to_json
      else
        halt env, 401, %({"error":"wrong user or password"})
      end
    rescue RateLimiter::Limited
      halt env, 429, %({"error":"too many failed logins"})
    end

    get "/api/session" { {user: auth.user, role: auth.role.to_s}.to_json }

    get "/api/config" { {fastTags: fast_tags, categoryColumn: kategorie, classify: !classify.nil?, metadata: !metadata.nil?}.to_json }

    delete "/api/session" do |env|
      env.response.cookies << auth.expired_cookie
      env.response.status_code = 204
      nil
    end

    get "/api/books" do |env|
      p = env.params.query
      offset = (p["offset"]?.try(&.to_i?) || 0).clamp(0, Int32::MAX)
      limit = (p["limit"]?.try(&.to_i?) || Api::DEFAULT_LIMIT).clamp(1, Api::MAX_LIMIT)
      if (l = lists) && Api.list_query?(p)
        next write_errors(env) do
          total, ids = Api.list_page(l, calibre, auth.user, p, kategorie, offset, limit)
          {total: total, offset: offset, limit: limit, books: Api.with_lists(calibre.books(ids), lists, auth.user)}.to_json
        end
      end
      sort = Api::SORTS[p["sort"]? || "title"]? || halt(env, 400, %({"error":"unknown sort"}))
      ascending = p["order"]? != "desc"
      result = calibre.search(Api.query(p, kategorie), sort, ascending, offset, limit)
      {total: result.total, offset: offset, limit: limit, books: Api.with_lists(calibre.books(result.ids), lists, auth.user)}.to_json
    end

    get "/api/books/:id" do |env|
      id = env.params.url["id"].to_i64? || halt(env, 404, %({"error":"not found"}))
      calibre.book(id).try { |b| Api.with_lists([b], lists, auth.user).first.to_json } || halt(env, 404, %({"error":"not found"}))
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
      write_routes(w, j, [classify, metadata].compact.map(&.as(Jobs)) + extra_jobs)
    end
    trash.try { |t| trash_routes(t) }
    lists.try { |l| list_routes(l, auth, jobs, calibre) }
    progress.try { |pr| progress_routes(pr, auth) }
    reader_settings.try { |rs| reader_settings_routes(rs, auth) }
    classify_routes(classify, calibre)
    metadata_routes(metadata, calibre)

    # OPDS for reader apps; its links point to /opds/* and /get/*
    {"/opds", "/opds/*", "/get/*"}.each do |route|
      get route do |env|
        path = env.request.resource
        CalibreHub.stream(env, calibre, path, passthrough_headers: true)
      end
    end
  end

  def self.write_routes(writer : Writer, jobs : Jobs, other_jobs = [] of Jobs)
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
      id = env.params.url["id"]
      (jobs[id]? || other_jobs.compact_map(&.[id]?).first?).try(&.to_json) || fail(env, 404, {error: "not found"})
    end

    # puts back what a finished bulk field change overwrote (once)
    post "/api/jobs/:id/undo" do |env|
      id = env.params.url["id"]
      next fail(env, 404, {error: "not found"}) unless jobs[id]?
      job = jobs.undo(id)
      env.response.status_code = 202
      {jobId: job.id, total: job.total}.to_json
    rescue ex : Jobs::NotUndoable
      fail(env, 409, {error: ex.message})
    end

    patch "/api/books/:id" do |env|
      write_errors(env) do
        id = env.params.url["id"].to_i64? || raise Writer::NotFound.new
        body = JSON.parse(env.request.body.try(&.gets_to_end) || "").as_h? || raise Edit::Invalid.new("", "JSON object expected")
        writer.update(id, body).to_json
      end
    end

    delete "/api/books/:id" do |env|
      write_errors(env) do
        id = env.params.url["id"].to_i64? || raise Writer::NotFound.new
        {book: writer.delete(id)}.to_json
      end
    end

    post "/api/books" do |env|
      write_errors(env) do
        upload = Writer.read_upload(env.request)
        begin
          book, created = writer.upload(upload)
          env.response.status_code = created ? 201 : 200
          # a new book that looks like others (the hub's own detection,
          # beyond calibre's exact title and author check)
          similar = created ? (writer.similar.try(&.call(book.id)) rescue nil) : nil
          similar ? {book: book, possibleDuplicates: similar}.to_json : {book: book}.to_json
        ensure
          File.delete?(upload.file)
        end
      end
    end
  end

  # Reading lists (lists.cr). Owner is the logged-in user.
  def self.list_routes(lists : Lists, auth : Auth, jobs : Jobs?, calibre : Calibre? = nil)
    # OPDS catalogs per list (Basic auth like /opds); before the /opds/*
    # passthrough
    get "/opds/lists" do |env|
      env.response.content_type = Opds::NAV
      Opds.lists_feed(lists.all(auth.user))
    end

    get "/opds/lists/:id" do |env|
      list = begin
        lists[list_id(env), auth.user]
      rescue Lists::NotFound
        env.response.status_code = 404
        next "not found"
      end
      ids = lists.members([list])
      offset = (env.params.query["offset"]?.try(&.to_i?) || 0).clamp(0, Int32::MAX)
      page = ids[offset, Opds::PAGE_SIZE]? || [] of Int64
      books = calibre ? calibre.books(page, Calibre::DETAIL_FIELDS) : [] of Book
      by_id = books.index_by(&.id)
      env.response.content_type = Opds::ACQ
      Opds.list_feed(list, page.compact_map { |id| by_id[id]? }, offset, ids.size, calibre.try(&.library_suffix) || "")
    end

    get "/api/lists" do |env|
      write_errors(env) { lists.all(auth.user).to_json }
    end

    post "/api/lists" do |env|
      write_errors(env) do
        list = lists.create(auth.user, json_body(env))
        env.response.status_code = 201
        list.to_json
      end
    end

    get "/api/lists/:id" do |env|
      write_errors(env) { lists[list_id(env), auth.user].to_json }
    end

    patch "/api/lists/:id" do |env|
      write_errors(env) { lists.update(list_id(env), auth.user, json_body(env), auth.admin?).to_json }
    end

    delete "/api/lists/:id" do |env|
      write_errors(env) { {list: lists.delete(list_id(env), auth.user)}.to_json }
    end

    post "/api/lists/:id/books" do |env|
      write_errors(env) do
        list, added = lists.add(list_id(env), auth.user, list_book_ids(json_body(env), jobs))
        {list: list, added: added}.to_json
      end
    end

    # before .../books/:bookId so "remove" isn't taken for an id
    post "/api/lists/:id/books/remove" do |env|
      write_errors(env) do
        list, removed = lists.remove(list_id(env), auth.user, list_book_ids(json_body(env), jobs))
        {list: list, removed: removed}.to_json
      end
    end

    put "/api/lists/:id/books/:bookId" do |env|
      write_errors(env) do
        book = env.params.url["bookId"].to_i64? || raise Writer::NotFound.new
        list, added = lists.add(list_id(env), auth.user, [book])
        raise Writer::NotFound.new if added.empty? && !lists.book_ids(list.id).includes?(book)
        {list: list, added: added}.to_json
      end
    end

    delete "/api/lists/:id/books/:bookId" do |env|
      write_errors(env) do
        book = env.params.url["bookId"].to_i64? || raise Writer::NotFound.new
        list, removed = lists.remove(list_id(env), auth.user, [book])
        {list: list, removed: removed}.to_json
      end
    end

    get "/api/books/:id/lists" do |env|
      write_errors(env) do
        id = env.params.url["id"].to_i64? || raise Writer::NotFound.new
        lists.lists_of(id, auth.user).to_json
      end
    end
  end

  # Reading progress (progress.cr) of the logged-in user
  def self.progress_routes(progress : Progress, auth : Auth)
    get "/api/progress" do |env|
      write_errors(env) do
        progress.latest(auth.user).map { |e| {bookId: e.book_id, fraction: e.fraction, format: e.format, updatedAt: e.updated_at} }.to_json
      end
    end

    get "/api/books/:id/progress" do |env|
      write_errors(env) do
        id = env.params.url["id"].to_i64? || raise Writer::NotFound.new
        devices = progress.of(auth.user, id)
        {latest: devices.first?, devices: devices}.to_json
      end
    end

    put "/api/books/:id/progress" do |env|
      write_errors(env) do
        id = env.params.url["id"].to_i64? || raise Writer::NotFound.new
        progress.save(auth.user, id, json_body(env)).to_json
      end
    end
  end

  # Reader settings (reader_settings.cr) of the logged-in user
  def self.reader_settings_routes(settings : ReaderSettings, auth : Auth)
    get "/api/reader/settings" do |env|
      write_errors(env) { settings.of(auth.user).to_json }
    end

    put "/api/reader/settings" do |env|
      write_errors(env) { settings.save(auth.user, json_body(env)).to_json }
    end
  end

  def self.list_id(env) : Int64
    env.params.url["id"].to_i64? || raise Lists::NotFound.new
  end

  def self.json_body(env) : Hash(String, JSON::Any)
    JSON.parse(env.request.body.try(&.gets_to_end).presence || "{}").as_h? || raise Edit::Invalid.new("", "JSON object expected")
  end

  # book ids from {bookIds: [...]} or {target: {ids} | {query}}
  def self.list_book_ids(body : Hash(String, JSON::Any), jobs : Jobs?) : Array(Int64)
    if v = body["bookIds"]?
      (v.as_a? || raise Edit::Invalid.new("bookIds", "list of book ids expected")).map do |x|
        x.as_i64? || raise Edit::Invalid.new("bookIds", "list of book ids expected")
      end
    elsif (t = body["target"]?) && jobs
      jobs.ids(t)
    else
      raise Edit::Invalid.new("bookIds", "bookIds or target expected")
    end
  end

  def self.trash_routes(trash : Trash)
    get "/api/trash" do
      trash.list.to_json
    end

    post "/api/trash/:id/restore" do |env|
      write_errors(env) do
        id = env.params.url["id"].to_i64? || raise Writer::NotFound.new
        {book: trash.restore(id)}.to_json
      end
    end
  end

  # Category suggestions from a local model (classify.cr). Only the status
  # route exists while classification is off.
  def self.classify_routes(jobs : ClassifyJobs?, calibre : Calibre)
    get "/api/classify/status" do
      next {enabled: false}.to_json unless jobs
      c = jobs.classify
      last = jobs.last.try do |job, started|
        JSON.parse(job.to_json).as_h.merge({"startedAt" => JSON::Any.new(started.to_rfc3339)})
      end
      {
        enabled: true, model: c.model, threshold: c.threshold, categories: c.paths(fresh: true).size,
        minCategories: Classifier::MIN_CATEGORIES, pending: c.suggestions.count("pending"),
        running: jobs.running?, lastRun: last,
      }.to_json
    end
    return unless jobs
    c = jobs.classify

    get "/api/suggestions" do |env|
      status = env.params.query["status"]?.presence
      if status && !Suggestions::STATUSES.includes?(status)
        next fail(env, 400, {error: "unknown status", field: "status"})
      end
      list = c.suggestions.list(status)
      books = calibre.books(list.map(&.book_id)).index_by(&.id)
      # books deleted since are left out
      list.compact_map do |s|
        books[s.book_id]?.try { |b| JSON.parse(s.to_json).as_h.merge({"book" => JSON.parse(b.to_json)}) }
      end.to_json
    end

    get "/api/suggestions/:id" do |env|
      id = env.params.url["id"].to_i64? || next fail(env, 404, {error: "not found"})
      c.suggestions[id]?.try(&.to_json) || fail(env, 404, {error: "not found"})
    end

    # before /api/suggestions/:id/accept so "accept" isn't taken for an id
    post "/api/suggestions/accept" do |env|
      write_errors(env) do
        body = JSON.parse(env.request.body.try(&.gets_to_end) || "").as_h? || raise Edit::Invalid.new("", "JSON object expected")
        ids = body["bookIds"]?.try(&.as_a?) || raise Edit::Invalid.new("bookIds", "list of book ids expected")
        ids = ids.map { |v| v.as_i64? || raise Edit::Invalid.new("bookIds", "list of book ids expected") }
        accepted = [] of Suggestions::Suggestion
        errors = [] of NamedTuple(bookId: Int64, error: String)
        ids.uniq.each do |id|
          accepted << c.accept(id)
        rescue Writer::NotFound
          errors << {bookId: id, error: "not found"}
        rescue ex : Calibre::Unavailable
          raise ex
        rescue ex
          errors << {bookId: id, error: ex.message || ex.class.name}
        end
        {accepted: accepted, errors: errors}.to_json
      end
    end

    post "/api/suggestions/:id/accept" do |env|
      write_errors(env) do
        id = env.params.url["id"].to_i64? || raise Writer::NotFound.new
        body = JSON.parse(env.request.body.try(&.gets_to_end).presence || "{}")
        override = body["category"]?.try { |v| v.as_s? || raise Edit::Invalid.new("category", "string expected") }
        c.accept(id, override).to_json
      end
    end

    post "/api/suggestions/:id/reject" do |env|
      write_errors(env) do
        id = env.params.url["id"].to_i64? || raise Writer::NotFound.new
        c.reject(id).to_json
      end
    end

    post "/api/classify" do |env|
      write_errors(env) do
        body = JSON.parse(env.request.body.try(&.gets_to_end).presence || "{}").as_h? || raise Edit::Invalid.new("", "JSON object expected")
        job = jobs.submit_target(body["target"]? || JSON::Any.new("unsorted"))
        env.response.status_code = 202
        {jobId: job.id, total: job.total}.to_json
      rescue ex : Classify::TooFewCategories
        fail(env, 409, {error: ex.message, categories: ex.count, minCategories: Classifier::MIN_CATEGORIES})
      end
    end
  end

  # Metadata cleanup (metadata.cr). Only the status route exists while it
  # is off.
  def self.metadata_routes(jobs : MetadataJobs?, calibre : Calibre)
    get "/api/metadata/status" do
      next {enabled: false}.to_json unless jobs
      m = jobs.metadata
      last = jobs.last.try do |job, started|
        JSON.parse(job.to_json).as_h.merge({"startedAt" => JSON::Any.new(started.to_rfc3339), "target" => JSON::Any.new(jobs.target(job))})
      end
      {
        enabled: true, sources: m.active_sources, model: m.model, nightly: m.nightly, running: jobs.running?,
        changedBooks: m.log.changed_books, lastRun: last,
      }.to_json
    end
    return unless jobs
    m = jobs.metadata

    post "/api/metadata/run" do |env|
      write_errors(env) do
        body = JSON.parse(env.request.body.try(&.gets_to_end).presence || "{}").as_h? || raise Edit::Invalid.new("", "JSON object expected")
        job = jobs.submit_target(body["target"]?)
        env.response.status_code = 202
        {jobId: job.id, total: job.total}.to_json
      end
    end

    get "/api/metadata/changes" do |env|
      write_errors(env) do
        p = env.params.query
        book_id = p["bookId"]?.presence.try { |v| v.to_i64? || raise Edit::Invalid.new("bookId", "number expected") }
        since = p["since"]?.presence.try do |v|
          Time.parse_iso8601(v) rescue raise Edit::Invalid.new("since", "ISO 8601 time expected")
        end
        reverted = case p["reverted"]?
                   when nil, ""      then nil
                   when "true", "1"  then true
                   when "false", "0" then false
                   else                   raise Edit::Invalid.new("reverted", "true or false expected")
                   end
        limit = (p["limit"]?.try(&.to_i?) || 500).clamp(1, 5000)
        changes = m.log.list(book_id, since, reverted, limit)
        {changes: changes, books: calibre.books(changes.map(&.book_id).uniq)}.to_json
      end
    end

    # before /api/metadata/changes/:id/revert so "revert" isn't taken for an id
    post "/api/metadata/changes/revert" do |env|
      write_errors(env) do
        body = JSON.parse(env.request.body.try(&.gets_to_end) || "").as_h? || raise Edit::Invalid.new("", "JSON object expected")
        unless body.has_key?("bookIds") || body.has_key?("changeIds")
          raise Edit::Invalid.new("bookIds", "bookIds or changeIds expected")
        end
        list = ->(key : String) do
          (body[key]?.try { |v| v.as_a? || raise Edit::Invalid.new(key, "list of ids expected") } || [] of JSON::Any).map do |v|
            v.as_i64? || raise Edit::Invalid.new(key, "list of ids expected")
          end
        end
        ids = (list.call("changeIds") + m.revert_books(list.call("bookIds").uniq)).uniq
        reverted = [] of MetaLog::Entry
        errors = [] of NamedTuple(changeId: Int64, bookId: Int64?, error: String)
        # newest first, so a field changed twice ends at its first value
        ids.sort.reverse.each do |id|
          reverted << m.revert(id)[0]
        rescue ex : Calibre::Unavailable
          raise ex
        rescue ex
          error = case ex
                  when Writer::NotFound then "not found"
                  when Writer::Conflict then "changed in the meantime"
                  else                       ex.message || ex.class.name
                  end
          errors << {changeId: id, bookId: m.log[id]?.try(&.book_id), error: error}
        end
        {reverted: reverted, errors: errors}.to_json
      end
    end

    post "/api/metadata/changes/:id/revert" do |env|
      write_errors(env) do
        id = env.params.url["id"].to_i64? || raise Writer::NotFound.new
        change, book = m.revert(id)
        {change: change, book: book}.to_json
      end
    end

    get "/api/books/:id/metadata/candidates" do |env|
      write_errors(env) do
        id = env.params.url["id"].to_i64? || raise Writer::NotFound.new
        {candidates: m.candidates(id, env.params.query["q"]?)}.to_json
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
  rescue Writer::NotFound | Lists::NotFound
    fail(env, 404, {error: "not found"})
  rescue ex : Lists::Forbidden
    fail(env, 403, {error: ex.message})
  rescue ex : Lists::Taken
    fail(env, 409, {error: ex.message, field: "name"})
  rescue ex : Writer::Conflict
    fail(env, 409, {error: "changed in the meantime", book: ex.book})
  rescue ex : Jobs::CountMismatch
    fail(env, 409, {error: ex.message, field: "target", expected: ex.expected, found: ex.found})
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
                                            "cache-control", "content-disposition", "accept-ranges",
                                            "content-range"}.includes?(k.downcase)
        env.response.headers[k] = v
      end
      IO.copy(r.body_io, env.response) if r.body_io?
    end
    nil
  end
end
