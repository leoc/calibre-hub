require "json"

module CalibreHub
  # A book as the API and the snapshot see it (camelCase for the frontend,
  # missing values as null).
  @[JSON::Serializable::Options(emit_nulls: true)]
  struct Book
    include JSON::Serializable

    getter id : Int64
    getter title : String
    getter authors : Array(String)
    @[JSON::Field(key: "authorSort")]
    getter author_sort : String?
    getter tags : Array(String)
    getter series : String?
    @[JSON::Field(key: "seriesIndex")]
    getter series_index : Float64?
    getter formats : Array(String)
    # full precision, so the PATCH conflict check sees writes within a second
    @[JSON::Field(key: "lastModified", converter: CalibreHub::Book::Micros)]
    getter last_modified : Time
    @[JSON::Field(key: "added")]
    getter timestamp : Time?
    getter pubdate : Time?
    getter rating : Float64?
    getter publisher : String?
    getter identifiers : Hash(String, String)
    getter languages : Array(String)
    @[JSON::Field(emit_null: false)]
    getter comments : String?
    getter custom : Hash(String, JSON::Any)

    module Micros
      def self.to_json(value : Time, json : JSON::Builder)
        json.string(format(value))
      end

      def self.format(value : Time) : String
        value.to_utc.to_rfc3339(fraction_digits: 6)
      end

      def self.from_json(pull : JSON::PullParser) : Time
        Time.parse_iso8601(pull.read_string)
      end
    end

    # lastModified as the API shows it
    def version : String
      Micros.format(last_modified)
    end

    def initialize(@id, @title, @authors, @author_sort, @tags, @series, @series_index, @formats,
                   @last_modified, @timestamp, @pubdate, @rating, @publisher, @identifiers,
                   @languages, @comments, @custom)
    end

    # list returns columns: {"book_ids": [...], "data": {field: {id: value}}}
    def self.from_list(result : JSON::Any, custom_columns : Array(String)) : Array(Book)
      data = result["data"].as_h
      col = ->(field : String, id : String) do
        Calibre.unwrap(data[field]?.try(&.as_h[id]?) || JSON::Any.new(nil))
      end
      result["book_ids"].as_a.map do |raw_id|
        id = raw_id.to_s
        series = col.call("series", id).as_s?
        Book.new(
          id: raw_id.as_i64,
          title: col.call("title", id).as_s? || "",
          authors: strings(col.call("authors", id)),
          author_sort: col.call("author_sort", id).as_s?,
          tags: strings(col.call("tags", id)),
          series: series,
          # calibre keeps 1.0 even without a series
          series_index: series ? number(col.call("series_index", id)) : nil,
          formats: strings(col.call("formats", id)),
          last_modified: time(col.call("last_modified", id)) || Time::UNIX_EPOCH,
          timestamp: time(col.call("timestamp", id)),
          pubdate: time(col.call("pubdate", id)),
          rating: number(col.call("rating", id)),
          publisher: col.call("publisher", id).as_s?,
          identifiers: (col.call("identifiers", id).as_h? || {} of String => JSON::Any).transform_values(&.to_s),
          languages: strings(col.call("languages", id)),
          comments: col.call("comments", id).as_s?,
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

    # calibre's "undefined" date is 0101-01-01
    private def self.time(v : JSON::Any) : Time?
      v.as_s?.try { |s| Time.parse_iso8601(s) }.try { |t| t.year <= 101 ? nil : t }
    end
  end
end
