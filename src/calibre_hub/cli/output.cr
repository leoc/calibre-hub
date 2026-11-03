require "html"
require "json"

module CalibreHub
  module Cli
    # Human-readable output; --json prints the API's JSON instead
    module Output
      # Control characters out of text from the library (titles,
      # descriptions, list names): an escape sequence in a book's metadata
      # must not reach the terminal (set its title, write the clipboard via
      # OSC 52). Newlines and tabs stay.
      def self.clean(text : String) : String
        text.gsub(/[\x00-\x08\x0b-\x1f\x7f\x{80}-\x{9f}]/, "")
      end

      # Columns padded to their widest cell, cells cut at max[i] characters
      def self.table(io : IO, headers : Array(String), rows : Array(Array(String)), max = [] of Int32?)
        cells = rows.map { |r| r.map_with_index { |c, i| cut(clean(c.gsub(/\s+/, " ")), max[i]?) } }
        widths = headers.map_with_index { |h, i| ([h] + cells.map(&.[i])).max_of(&.size) }
        ([headers] + cells).each do |row|
          line = row.map_with_index { |c, i| i == row.size - 1 ? c : c.ljust(widths[i]) }.join("  ")
          io.puts line.rstrip
        end
      end

      def self.cut(text : String, max : Int32?) : String
        return text unless max && text.size > max
        text[0, max - 1] + "…"
      end

      # one value of a book for tables and diffs
      def self.value(v : JSON::Any?) : String
        return "-" if v.nil?
        case raw = v.raw
        when Nil    then "-"
        when Array  then raw.empty? ? "-" : v.as_a.map { |x| value(x) }.join(", ")
        when Hash   then raw.empty? ? "-" : v.as_h.map { |k, x| "#{k}:#{value(x)}" }.join(", ")
        when Float  then number(raw)
        when String then raw.empty? ? "-" : clean(raw)
        else             raw.to_s
        end
      end

      # 3.0 -> "3", 1.5 -> "1.5"
      def self.number(n : Float64) : String
        n == n.round ? n.to_i64.to_s : n.to_s
      end

      def self.date(v : JSON::Any?) : String
        v.try(&.as_s?).try(&.[0, 10]) || "-"
      end

      def self.series(book : JSON::Any) : String
        name = book["series"]?.try(&.as_s?) || return "-"
        index = book["seriesIndex"]?.try { |i| i.as_f? || i.as_i64?.try(&.to_f) }
        name = clean(name)
        index ? "#{name} [#{number(index)}]" : name
      end

      def self.size(bytes : Int64) : String
        return "#{bytes} B" if bytes < 1024
        return "#{(bytes / 1024).round(1)} KB" if bytes < 1024 * 1024
        "#{(bytes / 1024 / 1024).round(1)} MB"
      end

      # HTML comments as plain text with paragraphs
      def self.plain(html : String) : String
        text = html.gsub(/<br\s*\/?>/i, "\n").gsub(/<\/(p|div|h\d|li|ul|ol|blockquote)>/i, "\n")
          .gsub(/<li[^>]*>/i, "- ").gsub(/<[^>]*>/, "")
        clean(HTML.unescape(text)).gsub(/[ \t]+/, " ").gsub(/ *\n */, "\n").gsub(/\n{3,}/, "\n\n").strip
      end

      def self.book_rows(books : Array(JSON::Any), category : String?) : Array(Array(String))
        books.map do |b|
          row = [b["id"].to_s, value(b["title"]?), value(b["authors"]?), series(b)]
          row << value(b["custom"]?.try(&.[category]?)) if category
          row << value(b["tags"]?)
          row
        end
      end

      def self.books(io : IO, books : Array(JSON::Any), category : String?)
        headers = ["ID", "Title", "Authors", "Series"]
        headers << category.capitalize if category
        headers << "Tags"
        max = category ? [nil, 50, 30, 28, 28, 40] : [nil, 50, 30, 28, 40]
        table(io, headers, book_rows(books, category), max)
      end

      def self.book(io : IO, b : JSON::Any)
        io.puts "##{b["id"]}  #{value(b["title"]?)}"
        fields = [
          {"Authors", value(b["authors"]?)},
          {"Series", series(b)},
          {"Tags", value(b["tags"]?)},
        ]
        b["custom"]?.try(&.as_h?).try &.each { |k, v| fields << {k.capitalize, value(v)} }
        rating = b["rating"]?.try { |r| r.as_f? || r.as_i64?.try(&.to_f) }
        fields.concat([
          {"Publisher", value(b["publisher"]?)},
          {"Published", date(b["pubdate"]?)},
          {"Rating", rating ? "#{number(rating)}/10" : "-"},
          {"Languages", value(b["languages"]?)},
          {"Identifiers", value(b["identifiers"]?)},
          {"Formats", value(b["formats"]?)},
          {"Added", date(b["added"]?)},
          {"Modified", value(b["lastModified"]?)},
        ])
        width = fields.max_of(&.[0].size) + 1
        fields.each { |(k, v)| io.puts "#{"#{k}:".ljust(width)} #{v}" }
        if (c = b["comments"]?.try(&.as_s?)) && !(text = plain(c)).empty?
          io.puts
          io.puts text
        end
      end

      FIELDS = %w(title authors series seriesIndex tags publisher pubdate rating languages identifiers comments formats)

      # fields that differ between two versions of a book, custom columns too
      def self.changed(a : JSON::Any, b : JSON::Any) : Array(String)
        customs = ((a["custom"]?.try(&.as_h?.try(&.keys)) || [] of String) +
                   (b["custom"]?.try(&.as_h?.try(&.keys)) || [] of String)).uniq
        FIELDS.select { |f| a[f]? != b[f]? } +
          customs.select { |c| a["custom"]?.try(&.[c]?) != b["custom"]?.try(&.[c]?) }
      end

      def self.field(book : JSON::Any, name : String) : JSON::Any?
        book[name]? || book["custom"]?.try(&.[name]?)
      end

      # categories: kategorie tree, others flat
      def self.tree(io : IO, nodes : Array(JSON::Any), depth = 0)
        nodes.each do |n|
          io.puts "#{"  " * depth}#{clean(n["name"].to_s)}  (#{n["count"]})"
          tree(io, n["children"]?.try(&.as_a) || [] of JSON::Any, depth + 1)
        end
      end

      def self.counts(io : IO, items : Array(JSON::Any))
        table(io, ["Count", "Name"], items.map { |i| [i["count"].to_s, i["name"].to_s] })
      end
    end
  end
end
