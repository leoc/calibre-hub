require "http/client"
require "json"
require "uri"
require "./book"
require "./sanitizer"

module CalibreHub
  # Talks to calibre-server the way calibredb does: POST /cdb/cmd/<name>/<version>
  # with the positional arguments of the command's implementation() as JSON.
  # Read paths (/ajax, /get) are used where they offer paging or files.
  class Calibre
    class Error < Exception
    end

    # calibre-server not reachable or answering with a server error
    class Unavailable < Error
    end

    # a book file larger than calibre-server takes (its max request body
    # size): nothing was sent, the book fails with the reason
    class TooLarge < Error
    end

    # as calibre counts them for --max-request-body-size
    MB = 1024_i64 * 1024

    # Fields for lists and the snapshot. Custom columns are "#name" in results
    # but "*name" in requests.
    FIELDS = %w(title authors author_sort tags series series_index formats
      last_modified timestamp pubdate rating publisher identifiers languages)
    DETAIL_FIELDS = FIELDS + %w(comments)

    record SearchResult, total : Int32, ids : Array(Int64)

    getter custom_columns : Array(String)
    # how long a request may take (adding a large book, a slow list)
    property read_timeout : Time::Span = 60.seconds
    # calibre-server's --max-request-body-size in bytes; nil: unknown,
    # nothing is checked before an upload
    property max_body : Int64? = nil

    def initialize(url : String, @user : String, @password : String, @library : String? = nil,
                   @custom_columns : Array(String) = [] of String)
      @url = URI.parse(url)
    end

    # calibredb list: fields, sort_by, ascending, search_text, limit
    def list(search = "", fields = FIELDS) : Array(Book)
      requested = fields + @custom_columns.map { |c| "*#{c}" }
      books = Book.from_list(cmd("list", [requested, "id", true, search, -1]), @custom_columns)
      return books unless fields.includes?("comments")
      # comments come from book files too (upload, inbox, calibre's own
      # import): the hub only ever hands out cleaned HTML (review #8411 H1)
      books.map { |b| b.comments = Calibre.clean_comments(b.comments); b }
    end

    def self.clean_comments(html : String?) : String?
      html.try { |h| Sanitizer.clean(h).presence }
    end

    # Up to this many ids go into one "id:1 or id:2 ..." search; calibre's
    # parser recurses per term and fails at a few hundred. Above it, listing
    # everything and filtering is cheaper anyway (~1 s for 10,000 books).
    SEARCH_IDS = 20

    def books(ids : Array(Int64), fields = FIELDS) : Array(Book)
      return [] of Book if ids.empty?
      found = if ids.size <= SEARCH_IDS
                list(ids.map { |id| "id:#{id}" }.join(" or "), fields)
              else
                wanted = ids.to_set
                list("", fields).select { |b| wanted.includes?(b.id) }
              end
      by_id = found.index_by(&.id)
      ids.compact_map { |id| by_id[id]? }
    end

    def book(id : Int64) : Book?
      books([id], DETAIL_FIELDS).first?
    end

    # calibredb list's "cover" is the cover's path, null without one
    def has_cover?(id : Int64) : Bool
      result = cmd("list", [["cover"], "id", true, "id:#{id}", -1])
      v = Calibre.unwrap(result["data"]["cover"]?.try(&.[id.to_s]?) || JSON::Any.new(nil))
      !v.raw.nil? && v.raw != false
    end

    # Cheap pass for reconciling: only id and last_modified of every book
    def last_modified : Hash(Int64, String)
      result = cmd("list", [["last_modified"], "id", true, "", -1])
      data = result["data"]["last_modified"].as_h
      result["book_ids"].as_a.to_h do |id|
        v = Calibre.unwrap(data[id.to_s]? || JSON::Any.new(nil))
        {id.as_i64, v.as_s? ? Time.parse_iso8601(v.as_s).to_utc.to_rfc3339(fraction_digits: 6) : ""}
      end
    end

    record Duplicate, title : String, authors : Array(String) do
      def to_s(io)
        io << title << " (" << authors.join(", ") << ')'
      end
    end
    record Added, book_id : Int64?, duplicates : Array(Duplicate)

    # POST /cdb/add-book: the file is the body; calibre reads its metadata.
    # Its length goes along (not chunked), so calibre-server checks it against
    # its limit just as the hub does, byte for byte.
    def add_book(file : String, filename : String, duplicates = false) : Added
      size = File.size(file)
      fits!(size, size)
      path = "/cdb/add-book/#{Random::Secure.hex(4)}/#{duplicates ? "y" : "n"}/#{URI.encode_path_segment(filename)}#{library_path}"
      body = File.open(file) do |io|
        c = client
        c.basic_auth(@user, @password)
        r = c.post(path, headers: HTTP::Headers{"Accept" => "application/json", "Content-Length" => size.to_s}, body: io)
        raise Unavailable.new("calibre-server add-book: HTTP #{r.status_code}") if r.status_code >= 500
        raise Error.new("calibre-server add-book: HTTP #{r.status_code} #{r.body[0, 200]}") unless r.success?
        JSON.parse(r.body)
      end
      dups = body["duplicates"]?.try(&.as_a.map { |d| Duplicate.new(d["title"].as_s, d["authors"].as_a.map(&.as_s)) }) || [] of Duplicate
      Added.new(body["book_id"]?.try(&.as_i64), dups)
    rescue ex : IO::Error | Socket::Error
      raise Unavailable.new(Calibre.cut_off(ex.message, size))
    end

    # CALIBRE_HUB_CALIBRE_MAX_BODY_MB, MB as calibre-server's
    # --max-request-body-size takes them; unset or empty: no check
    def self.max_body(mb : String?) : Int64?
      mb.presence.try { |v| (v.to_f * MB).to_i64 }
    end

    # Why a book file is not sent: its size against its share of the limit
    def self.too_large(size : Int64, room : Int64) : String
      "file is #{mb(size, up: true)} MB, calibre-server takes at most #{mb(room, up: false)} MB (calibre-server max request body size)"
    end

    # calibre-server answers a body over its limit with a 413 and closes the
    # connection, which the hub only notices while it still writes. Without
    # the hub knowing the limit (or knowing a wrong one) that is the reason.
    def self.cut_off(message : String?, size : Int64?) : String
      if size && message && message.matches?(/Broken pipe|Connection reset/i)
        "calibre-server closed the connection during a #{mb(size, up: true)} MB upload, " \
        "the file may be over calibre-server's max request body size (#{message})"
      else
        "calibre-server: #{message}"
      end
    end

    # MB with one decimal below 10; sizes rounded up and limits down, so a
    # file just over the limit never reads as the limit itself
    def self.mb(bytes : Int64, up : Bool) : String
      if bytes < 10 * MB
        tenths = up ? (bytes * 10 + MB - 1) // MB : bytes * 10 // MB
        "#{tenths // 10}.#{tenths % 10}"
      else
        (up ? (bytes + MB - 1) // MB : bytes // MB).to_s
      end
    end

    # A body of that many bytes around a file of size, checked before it is
    # sent. The file's share of the limit is what the body's overhead leaves;
    # base64 makes 4 bytes of 3.
    private def fits!(size : Int64, body : Int64) : Nil
      limit = @max_body || return
      return if body <= limit
      room = body == size ? limit : Math.max(0_i64, (limit - (body - (size + 2) // 3 * 4)) // 4 * 3)
      raise TooLarge.new(Calibre.too_large(size, room))
    end

    # POST /cdb/set-fields: {"changes": {"tags": [...], "#kategorie": "A.B",
    # "added_formats": [{"ext": "epub", "data_url": "<base64>"}]}}
    def set_fields(book_id : Int64, changes : Hash(String, JSON::Any)) : Nil
      # whatever writes comments (edits, metadata sources, merges, undo)
      if (c = changes["comments"]?) && (s = c.as_s?)
        changes = changes.merge({"comments" => JSON::Any.new(Calibre.clean_comments(s))})
      end
      request("POST", "/cdb/set-fields/#{book_id}#{library_path}", {changes: changes, loaded_book_ids: [book_id]}.to_json)
    end

    # calibre takes JPEG or PNG as base64 and doesn't bump last_modified
    # when a cover replaces another, so it is set explicitly
    def set_cover(book_id : Int64, data : Bytes, type : String) : Nil
      set_fields(book_id, {
        "cover"         => JSON::Any.new("data:image/#{type};base64,#{Base64.strict_encode(data)}"),
        "last_modified" => JSON::Any.new(Time.utc.to_rfc3339(fraction_digits: 6)),
      })
    end

    # The set-fields body is streamed with the file base64-encoded on the
    # way, so a 200 MB upload isn't held in memory several times over
    def add_format(book_id : Int64, file : String, ext : String) : Nil
      prefix = %({"changes":{"added_formats":[{"ext":#{ext.to_json},"data_url":")
      suffix = %("}]},"loaded_book_ids":[#{book_id}]})
      size = File.size(file)
      length = prefix.bytesize + (size + 2) // 3 * 4 + suffix.bytesize
      fits!(size, length)
      File.open(file) do |f|
        reader, writer = IO.pipe
        spawn do
          writer << prefix
          Calibre.base64(f, writer)
          writer << suffix
        rescue IO::Error
          # the request ended early, its error is raised there
        ensure
          writer.close
        end
        begin
          request("POST", "/cdb/set-fields/#{book_id}#{library_path}", reader, length, upload: size)
        ensure
          reader.close
        end
      end
    end

    # strict base64 of everything in src, in chunks of a multiple of 3 bytes
    # (so the pieces join to the encoding of the whole)
    def self.base64(src : IO, dst : IO) : Nil
      buf = Bytes.new(3 * 64 * 1024)
      loop do
        n = 0
        while n < buf.size && (m = src.read(buf[n..])) > 0
          n += m
        end
        Base64.strict_encode(buf[0, n], dst) if n > 0
        break if n < buf.size
      end
    end

    # calibredb remove: ids, permanent. Without permanent calibre moves the
    # book folder to its trash (<library>/.caltrash/b/<id>).
    def remove(ids : Array(Int64), permanent = false) : Nil
      cmd("remove", [ids, permanent])
    end

    # calibredb add, action "empty": a book without files from a Metadata
    # object as calibre serializes it (calibre.utils.serialize.json_dumps)
    def add_empty(metadata : JSON::Any) : Int64
      result = cmd("add", ["empty", metadata])
      result[0].as_a.first?.try(&.as_i64) || raise Error.new("calibre-server add: no book created")
    end

    # Paging with total count via the same search the web UI uses
    def search(query : String, sort : String, ascending : Bool, offset : Int32, limit : Int32) : SearchResult
      params = URI::Params.build do |p|
        p.add "query", query
        p.add "sort", sort
        p.add "sort_order", ascending ? "asc" : "desc"
        p.add "offset", offset.to_s
        p.add "num", limit.to_s
      end
      body = JSON.parse(get("/ajax/search#{library_path}?#{params}"))
      SearchResult.new(body["total_num"].as_i, body["book_ids"].as_a.map(&.as_i64))
    end

    # calibredb list_categories: [categories, field_metadata]; items are
    # wrapped Tag objects with name, count, sort
    def categories : Hash(String, Array(NamedTuple(name: String, count: Int32)))
      cats = cmd("list_categories", [] of String)[0].as_h
      cats.transform_values do |items|
        items.as_a.map do |item|
          v = Calibre.unwrap(item)
          {name: v["name"].as_s, count: v["count"].as_i}
        end
      end
    end

    # Streams a calibre-server response (covers, downloads, OPDS)
    def forward(method : String, path : String, headers = HTTP::Headers.new, body : IO? = nil, &)
      headers = headers.dup
      headers["Authorization"] = "Basic #{Base64.strict_encode("#{@user}:#{@password}")}"
      client.exec(method, path, headers: headers, body: body) { |r| yield r }
    rescue ex : IO::Error | Socket::Error
      raise Unavailable.new("calibre-server: #{ex.message}")
    end

    def cmd(name : String, args, version = 0) : JSON::Any
      path = "/cdb/cmd/#{name}/#{version}"
      path += "?" + URI::Params.encode({"library_id" => @library.not_nil!}) if @library
      response = request("POST", path, args.to_json)
      body = JSON.parse(response)
      if err = body["err"]?
        raise Error.new("calibre-server #{name}: #{err}")
      end
      body["result"]
    end

    def self.unwrap(value : JSON::Any) : JSON::Any
      # Datetimes and objects come wrapped as {"<marker>": n, "v": value}
      if (h = value.as_h?) && h.has_key?("v") && h.size == 2
        h["v"]
      else
        value
      end
    end

    private def get(path) : String
      request("GET", path, nil)
    end

    # upload: the size of the file in the body, for the reason when
    # calibre-server cuts the request off
    private def request(method, path, body : String | IO | Nil, length : Int64? = nil, upload : Int64? = nil) : String
      c = client
      c.basic_auth(@user, @password)
      headers = HTTP::Headers{"Accept" => "application/json"}
      headers["Content-Type"] = "application/json" if body
      headers["Content-Length"] = length.to_s if length
      response = c.exec(method, path, headers: headers, body: body)
      if response.status_code >= 500
        raise Unavailable.new("calibre-server #{path}: HTTP #{response.status_code}")
      end
      unless response.success?
        raise Error.new("calibre-server #{path}: HTTP #{response.status_code}")
      end
      response.body
    rescue ex : IO::Error | Socket::Error
      raise Unavailable.new(Calibre.cut_off(ex.message, upload))
    end

    # "/<library id>" for /get/* links, "" for the default library
    def library_suffix : String
      library_path
    end

    private def library_path
      @library ? "/#{URI.encode_path_segment(@library.not_nil!)}" : ""
    end

    private def client
      HTTP::Client.new(@url).tap do |c|
        c.connect_timeout = 5.seconds
        c.read_timeout = @read_timeout
      end
    end
  end
end
