require "http/client"
require "json"
require "uri"

module CalibreHub
  # Talks to calibre-server the way calibredb does: POST /cdb/cmd/<name>/<version>
  # with the positional arguments of the command's implementation() as JSON.
  class Calibre
    class Error < Exception
    end

    # Fields the snapshot and the API care about. Custom columns are "#name"
    # in results but "*name" in requests.
    FIELDS = %w(title authors author_sort tags series series_index formats
      last_modified timestamp pubdate rating publisher identifiers languages)

    getter url : URI

    def initialize(url : String, @user : String, @password : String, @library : String? = nil,
                   @custom_columns : Array(String) = [] of String)
      @url = URI.parse(url)
    end

    # calibredb list: fields, sort_by, ascending, search_text, limit
    def list(search = "", fields = FIELDS) : Array(Book)
      requested = fields + @custom_columns.map { |c| "*#{c}" }
      result = cmd("list", [requested, "id", true, search, -1])
      Book.from_list(result, @custom_columns)
    end

    def cmd(name : String, args, version = 0) : JSON::Any
      path = "/cdb/cmd/#{name}/#{version}"
      path += "?" + URI::Params.encode({"library_id" => @library.not_nil!}) if @library
      response = client.post(path, headers: headers, body: args.to_json)
      unless response.success?
        raise Error.new("calibre-server #{name}: HTTP #{response.status_code}")
      end
      body = JSON.parse(response.body)
      if err = body["err"]?
        raise Error.new("calibre-server #{name}: #{err}")
      end
      body["result"]
    end

    private def client
      HTTP::Client.new(@url).tap do |c|
        c.basic_auth(@user, @password)
        c.connect_timeout = 5.seconds
        c.read_timeout = 60.seconds
      end
    end

    private def headers
      HTTP::Headers{"Content-Type" => "application/json", "Accept" => "application/json"}
    end

    # Datetimes come wrapped as {"<marker>": 0, "v": "<iso>"}
    def self.unwrap(value : JSON::Any) : JSON::Any
      if (h = value.as_h?) && h.has_key?("v") && h.size == 2
        h["v"]
      else
        value
      end
    end
  end

  struct Book
    include JSON::Serializable

    getter id : Int64
    getter title : String
    getter authors : Array(String)
    getter author_sort : String?
    getter tags : Array(String)
    getter series : String?
    getter series_index : Float64?
    getter formats : Array(String)
    getter last_modified : Time
    getter timestamp : Time?
    getter pubdate : Time?
    getter rating : Float64?
    getter publisher : String?
    getter identifiers : Hash(String, String)
    getter languages : Array(String)
    getter custom : Hash(String, JSON::Any)

    def initialize(@id, @title, @authors, @author_sort, @tags, @series, @series_index, @formats,
                   @last_modified, @timestamp, @pubdate, @rating, @publisher, @identifiers,
                   @languages, @custom)
    end

    # list returns columns: {"book_ids": [...], "data": {field: {id: value}}}
    def self.from_list(result : JSON::Any, custom_columns : Array(String)) : Array(Book)
      data = result["data"].as_h
      col = ->(field : String, id : String) do
        Calibre.unwrap(data[field]?.try(&.as_h[id]?) || JSON::Any.new(nil))
      end
      result["book_ids"].as_a.map do |raw_id|
        id = raw_id.to_s
        Book.new(
          id: raw_id.as_i64,
          title: col.call("title", id).as_s? || "",
          authors: strings(col.call("authors", id)),
          author_sort: col.call("author_sort", id).as_s?,
          tags: strings(col.call("tags", id)),
          series: col.call("series", id).as_s?,
          series_index: number(col.call("series_index", id)),
          formats: strings(col.call("formats", id)),
          last_modified: time(col.call("last_modified", id)) || Time::UNIX_EPOCH,
          timestamp: time(col.call("timestamp", id)),
          pubdate: time(col.call("pubdate", id)),
          rating: number(col.call("rating", id)),
          publisher: col.call("publisher", id).as_s?,
          identifiers: (col.call("identifiers", id).as_h? || {} of String => JSON::Any).transform_values(&.to_s),
          languages: strings(col.call("languages", id)),
          custom: custom_columns.to_h { |c| {c, col.call("##{c}", id)} },
        )
      end
    end

    private def self.strings(v : JSON::Any) : Array(String)
      v.as_a?.try(&.map(&.to_s)) || [] of String
    end

    private def self.number(v : JSON::Any) : Float64?
      v.as_f? || v.as_i64?.try(&.to_f)
    end

    private def self.time(v : JSON::Any) : Time?
      v.as_s?.try { |s| Time.parse_iso8601(s) }
    end
  end
end
