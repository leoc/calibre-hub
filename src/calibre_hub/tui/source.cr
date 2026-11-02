require "json"
require "http/params"
require "../cli/args"
require "../cli/client"

module CalibreHub
  module Tui
    # Where the TUI reads from (read-only in this phase). The real one is the
    # hub's JSON API through the CLI client; specs pass a fake.
    abstract class Source
      # GET /api/books
      abstract def books(params : HTTP::Params) : JSON::Any
      # GET /api/books/:id (with the description, which lists leave out)
      abstract def book(id : Int64) : JSON::Any
      # GET /api/categories
      abstract def categories : JSON::Any
      # GET /api/config
      abstract def config : JSON::Any
      # GET /api/lists
      abstract def lists : JSON::Any
    end

    class ApiSource < Source
      def initialize(@client : Cli::Client)
      end

      def books(params : HTTP::Params) : JSON::Any
        @client.get("/api/books", params)
      end

      def book(id : Int64) : JSON::Any
        @client.get("/api/books/#{id}")
      end

      def categories : JSON::Any
        @client.get("/api/categories")
      end

      def config : JSON::Any
        @client.get("/api/config")
      end

      def lists : JSON::Any
        @client.get("/api/lists")
      end
    end

    # A book of the API as the TUI shows it
    struct Book
      getter json : JSON::Any

      def initialize(@json)
      end

      def id : Int64
        @json["id"].as_i64
      end

      def title : String
        str("title") || ""
      end

      def authors : Array(String)
        strs("authors")
      end

      def tags : Array(String)
        strs("tags")
      end

      def languages : Array(String)
        strs("languages")
      end

      def formats : Array(String)
        strs("formats")
      end

      def series : String?
        str("series").presence
      end

      def series_index : Float64?
        @json["seriesIndex"]?.try { |i| i.as_f? || i.as_i64?.try(&.to_f) }
      end

      # "Dune [1]"
      def series_label : String
        s = series || return ""
        i = series_index
        i ? "#{s} [#{Book.number(i)}]" : s
      end

      def category(column : String?) : String?
        column.try { |c| @json["custom"]?.try(&.[c]?).try(&.as_s?).presence }
      end

      def comments : String
        str("comments") || ""
      end

      def publisher : String?
        str("publisher").presence
      end

      def rating : Float64?
        @json["rating"]?.try { |r| r.as_f? || r.as_i64?.try(&.to_f) }
      end

      def identifiers : Hash(String, String)
        @json["identifiers"]?.try(&.as_h?).try(&.transform_values { |v| v.as_s? || v.to_s }) || {} of String => String
      end

      def lists : Array(Int64)
        @json["lists"]?.try(&.as_a?).try(&.compact_map(&.as_i64?)) || [] of Int64
      end

      # YYYY-MM-DD; calibre's "no date" (year 101) is none
      def date(field : String) : String?
        d = str(field).try(&.[0, 10]?) || return nil
        d.starts_with?("0101") ? nil : d
      end

      private def str(field : String) : String?
        @json[field]?.try(&.as_s?)
      end

      private def strs(field : String) : Array(String)
        @json[field]?.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
      end

      # 3.0 -> "3", 1.5 -> "1.5"
      def self.number(n : Float64) : String
        n == n.round ? n.to_i64.to_s : n.to_s
      end
    end
  end
end
