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

    def books(ids : Array(Int64), fields = FIELDS) : Array(Book)
      return [] of Book if ids.empty?
      by_id = list(ids.map { |id| "id:#{id}" }.join(" or "), fields).index_by(&.id)
      ids.compact_map { |id| by_id[id]? }
    end

    def book(id : Int64) : Book?
      books([id], DETAIL_FIELDS).first?
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
