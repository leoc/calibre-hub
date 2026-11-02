require "http/client"
require "json"
require "uri"
require "./book"

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

    # Fields for lists and the snapshot. Custom columns are "#name" in results
    # but "*name" in requests.
    FIELDS = %w(title authors author_sort tags series series_index formats
      last_modified timestamp pubdate rating publisher identifiers languages)
    DETAIL_FIELDS = FIELDS + %w(comments)

    record SearchResult, total : Int32, ids : Array(Int64)

    getter custom_columns : Array(String)

    def initialize(url : String, @user : String, @password : String, @library : String? = nil,
                   @custom_columns : Array(String) = [] of String)
      @url = URI.parse(url)
    end

    # calibredb list: fields, sort_by, ascending, search_text, limit
    def list(search = "", fields = FIELDS) : Array(Book)
      requested = fields + @custom_columns.map { |c| "*#{c}" }
      Book.from_list(cmd("list", [requested, "id", true, search, -1]), @custom_columns)
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

    # POST /cdb/add-book: the file is the body; calibre reads its metadata
    def add_book(file : String, filename : String, duplicates = false) : Added
      path = "/cdb/add-book/#{Random::Secure.hex(4)}/#{duplicates ? "y" : "n"}/#{URI.encode_path_segment(filename)}#{library_path}"
      body = File.open(file) do |io|
        c = client
        c.basic_auth(@user, @password)
        r = c.post(path, headers: HTTP::Headers{"Accept" => "application/json"}, body: io)
        raise Unavailable.new("calibre-server add-book: HTTP #{r.status_code}") if r.status_code >= 500
        raise Error.new("calibre-server add-book: HTTP #{r.status_code} #{r.body[0, 200]}") unless r.success?
        JSON.parse(r.body)
      end
      dups = body["duplicates"]?.try(&.as_a.map { |d| Duplicate.new(d["title"].as_s, d["authors"].as_a.map(&.as_s)) }) || [] of Duplicate
      Added.new(body["book_id"]?.try(&.as_i64), dups)
    rescue ex : IO::Error | Socket::Error
      raise Unavailable.new("calibre-server: #{ex.message}")
    end

    # POST /cdb/set-fields: {"changes": {"tags": [...], "#kategorie": "A.B",
    # "added_formats": [{"ext": "epub", "data_url": "<base64>"}]}}
    def set_fields(book_id : Int64, changes : Hash(String, JSON::Any)) : Nil
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

    def add_format(book_id : Int64, file : String, ext : String) : Nil
      data = Base64.strict_encode(File.open(file, &.getb_to_end))
      set_fields(book_id, {"added_formats" => JSON.parse([{ext: ext, data_url: data}].to_json)})
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

    private def request(method, path, body : String?) : String
      c = client
      c.basic_auth(@user, @password)
      headers = HTTP::Headers{"Accept" => "application/json"}
      headers["Content-Type"] = "application/json" if body
      response = c.exec(method, path, headers: headers, body: body)
      if response.status_code >= 500
        raise Unavailable.new("calibre-server #{path}: HTTP #{response.status_code}")
      end
      unless response.success?
        raise Error.new("calibre-server #{path}: HTTP #{response.status_code}")
      end
      response.body
    rescue ex : IO::Error | Socket::Error
      raise Unavailable.new("calibre-server: #{ex.message}")
    end

    private def library_path
      @library ? "/#{URI.encode_path_segment(@library.not_nil!)}" : ""
    end

    private def client
      HTTP::Client.new(@url).tap do |c|
        c.connect_timeout = 5.seconds
        c.read_timeout = 60.seconds
      end
    end
  end
end
