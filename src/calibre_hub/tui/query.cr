require "http/params"

module CalibreHub
  module Tui
    SORTS      = %w(title author added modified published series rating)
    LIST_SORTS = %w(listAdded title author series)
    SORT_NAMES = {"title" => "Titel", "author" => "Autor", "added" => "Hinzugefügt", "modified" => "Geändert",
                  "published" => "Erschienen", "series" => "Serie", "rating" => "Bewertung",
                  "listAdded" => "Zuletzt hinzugefügt"}
    PAGE_SIZE = 60

    # What the library shows: the web app's LibrarySearch (frontend/src/lib/search.ts)
    # without page and open book.
    record Query,
      q : String? = nil,
      kategorie : String? = nil,
      tags : Array(String) = [] of String,
      author : String? = nil,
      series : String? = nil,
      lang : String? = nil,
      unsorted : Bool = false,
      list : Int64? = nil,
      list_path : String? = nil,
      sort : String? = nil,
      order : String? = nil do
      def filters? : Bool
        !!(q.presence || kategorie || !tags.empty? || author || series || lang || unsorted || list || list_path)
      end

      def list_view? : Bool
        !list.nil? || !!list_path.presence
      end

      def sorts : Array(String)
        list_view? ? LIST_SORTS : SORTS
      end

      # explicit choice, else series order inside a series, else newest
      # first (in a list: most recently added to it)
      def effective_sort : {String, String}
        if (s = sort) && sorts.includes?(s)
          return {s, order || Query.default_order(s)}
        end
        return {"listAdded", "desc"} if list_view?
        return {"series", "asc"} if series
        {"added", "desc"}
      end

      def self.default_order(sort : String) : String
        {"added", "listAdded", "modified", "published", "rating"}.includes?(sort) ? "desc" : "asc"
      end

      # Filter changes keep the sort, like withFilter in the web app
      def toggle_tag(tag : String) : Query
        copy_with(tags: tags.includes?(tag) ? tags - [tag] : tags + [tag])
      end

      # the next sort the library offers
      def next_sort : Query
        current = effective_sort[0]
        list = sorts
        s = list[((list.index(current) || -1) + 1) % list.size]
        copy_with(sort: s, order: Query.default_order(s))
      end

      def reverse_order : Query
        s, o = effective_sort
        copy_with(sort: s, order: o == "asc" ? "desc" : "asc")
      end

      # GET /api/books parameters (toBookQuery in the web app)
      def params(offset : Int32, limit : Int32, category_column : String?) : HTTP::Params
        p = HTTP::Params.new
        parts = [] of String
        q.try(&.strip.presence).try { |x| parts << "(#{x})" }
        lang.try { |l| parts << %(languages:"=#{Query.quote(l)}") }
        parts << Query.unsorted_query(category_column) if unsorted && category_column
        p["q"] = parts.join(" and ") unless parts.empty?
        kategorie.try { |k| p["kategorie"] = k }
        tags.each { |t| p.add("tag", t) }
        author.try { |a| p["author"] = a }
        series.try { |s| p["series"] = s }
        if l = list
          p["list"] = l.to_s
        elsif lp = list_path.presence
          p["listPath"] = lp
        end
        s, o = effective_sort
        p["sort"] = s
        p["order"] = o
        p["offset"] = offset.to_s
        p["limit"] = limit.to_s
        p
      end

      def self.quote(v : String) : String
        v.gsub('\\', "\\\\").gsub('"', "\\\"")
      end

      # calibre search for books with an empty category column
      def self.unsorted_query(column : String) : String
        "##{column}:false"
      end

      # the active filters as {label, value}, for the header
      def chips(list_names : Hash(Int64, String) = {} of Int64 => String) : Array({String, String})
        out = [] of {String, String}
        if l = list
          out << {"Liste", list_names[l]? || "##{l}"}
        elsif lp = list_path.presence
          out << {"Liste", lp}
        end
        q.presence.try { |x| out << {"Suche", x} }
        kategorie.try { |k| out << {"Kategorie", Tui.category_label(k)} }
        out << {"", "Ohne Kategorie"} if unsorted
        author.try { |a| out << {"Autor", a} }
        series.try { |s| out << {"Serie", s} }
        tags.each { |t| out << {"Tag", t} }
        lang.try { |l| out << {"Sprache", l} }
        out
      end
    end

    # Categories are stored with dots, shown as a path ("Sachbuch/Geschichte")
    def self.category_label(stored : String) : String
      stored.split('.').join('/')
    end
  end
end
