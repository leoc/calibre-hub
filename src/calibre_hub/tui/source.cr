require "json"
require "http/params"
require "../cli/args"
require "../cli/client"

module CalibreHub
  module Tui
    # What the TUI reads and writes. The real one is the hub's JSON API
    # through the CLI client; specs pass a fake. Errors of the hub are
    # `Cli::HttpError` (409 with the current book on a conflict).
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

      # PATCH /api/books/:id: the book as changed
      abstract def patch_book(id : Int64, body : Hash(String, JSON::Any)) : JSON::Any
      # DELETE /api/books/:id (to calibre's trash): {book}
      abstract def delete_book(id : Int64) : JSON::Any
      # POST /api/trash/:id/restore: {book}
      abstract def restore_book(id : Int64) : JSON::Any
      # POST /api/books/bulk {target, changes}: {jobId, total}
      abstract def bulk(target : JSON::Any, changes : Hash(String, JSON::Any)) : JSON::Any
      # GET /api/jobs/:id
      abstract def job(id : String) : JSON::Any
      # POST /api/jobs/:id/undo: {jobId, total} (hubs after 88ba458)
      abstract def undo_job(id : String) : JSON::Any
      # POST /api/lists/:id/books(/remove) {bookIds}: {list, added | removed}
      abstract def list_books(list : Int64, ids : Array(Int64), remove : Bool) : JSON::Any
      # the same with a bulk target ({query, expect, all?}) instead of ids
      abstract def list_target(list : Int64, target : JSON::Any, remove : Bool) : JSON::Any
      # GET /api/trash: [{id, title, authors, formats, deletedAt}]
      abstract def trash : JSON::Any
      # POST /api/lists {name}: the new list
      abstract def create_list(name : String) : JSON::Any
      # GET /api/books/:id/download/:format into path; the bytes written
      abstract def download(id : Int64, format : String, path : String) : Int64
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

      def patch_book(id : Int64, body : Hash(String, JSON::Any)) : JSON::Any
        @client.patch("/api/books/#{id}", body)
      end

      def delete_book(id : Int64) : JSON::Any
        @client.json("DELETE", "/api/books/#{id}")
      end

      def restore_book(id : Int64) : JSON::Any
        @client.post("/api/trash/#{id}/restore", {} of String => String)
      end

      def bulk(target : JSON::Any, changes : Hash(String, JSON::Any)) : JSON::Any
        @client.post("/api/books/bulk", {"target" => target, "changes" => changes})
      end

      def job(id : String) : JSON::Any
        @client.get("/api/jobs/#{URI.encode_path_segment(id)}")
      end

      def undo_job(id : String) : JSON::Any
        @client.post("/api/jobs/#{URI.encode_path_segment(id)}/undo", {} of String => String)
      end

      def list_books(list : Int64, ids : Array(Int64), remove : Bool) : JSON::Any
        @client.post("/api/lists/#{list}/books#{remove ? "/remove" : ""}", {"bookIds" => ids})
      end

      def list_target(list : Int64, target : JSON::Any, remove : Bool) : JSON::Any
        @client.post("/api/lists/#{list}/books#{remove ? "/remove" : ""}", {"target" => target})
      end

      def trash : JSON::Any
        @client.get("/api/trash")
      end

      def create_list(name : String) : JSON::Any
        @client.post("/api/lists", {"name" => name})
      end

      # via a .part file, like `hub download`
      def download(id : Int64, format : String, path : String) : Int64
        part = "#{path}.part"
        bytes = 0_i64
        begin
          @client.download("/api/books/#{id}/download/#{format}") do |r|
            File.open(part, "w") { |f| bytes = IO.copy(r.body_io, f) }
          end
          File.rename(part, path)
        ensure
          File.delete?(part)
        end
        bytes
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

      def last_modified : String?
        str("lastModified")
      end

      # this book with some fields replaced (optimistic updates)
      def merge(fields : Hash(String, JSON::Any)) : Book
        Book.new(JSON::Any.new((@json.as_h? || {} of String => JSON::Any).merge(fields)))
      end

      # the category column with a new value (stored, "A.B")
      def with_category(column : String, value : String?) : Book
        custom = (@json["custom"]?.try(&.as_h?) || {} of String => JSON::Any).dup
        custom[column] = JSON::Any.new(value)
        merge({"custom" => JSON::Any.new(custom)})
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
