require "json"

module CalibreHub
  module Tui
    # The web app's sidebar as a list of lines: "Alle Bücher", lists,
    # categories (with "Ohne Kategorie"), fast tags, authors, series, tags,
    # languages. Trees fold open and closed; long sections show the most
    # frequent entries until "Alle N anzeigen".
    class Sidebar
      COLLAPSED = 8

      enum Kind
        Header
        Item
        More
      end

      # key: stable identity (cursor and folding survive rebuilds)
      record Entry, kind : Kind, key : String, label : String, depth : Int32 = 0,
        count : Int64? = nil, children : Bool = false, expanded : Bool = false,
        active : Bool = false, apply : Proc(Query, Query)? = nil do
        def selectable? : Bool
          kind != Kind::Header
        end
      end

      property categories : JSON::Any? = nil
      property lists : JSON::Any? = nil
      property fast_tags = [] of String
      property category_column : String? = nil
      property unsorted_count : Int64? = nil
      getter cursor = 0
      getter offset = 0
      @expanded = Set(String).new
      @collapsed = Set(String).new
      @entries : Array(Entry)? = nil
      @query = Query.new

      # names of the lists by id, for the header and the detail
      def list_names : Hash(Int64, String)
        h = {} of Int64 => String
        lists.try(&.as_a?).try &.each do |l|
          id = l["id"]?.try(&.as_i64?)
          name = l["name"]?.try(&.as_s?)
          h[id] = name if id && name
        end
        h
      end

      def query=(q : Query) : Query
        @entries = nil unless q == @query
        @query = q
      end

      def changed : Nil
        @entries = nil
      end

      def entries : Array(Entry)
        @entries ||= build
      end

      def current : Entry?
        entries[@cursor]?
      end

      # moves over selectable lines; keeps the cursor inside the list
      def move(delta : Int32) : Nil
        list = entries
        return if list.empty?
        step = delta >= 0 ? 1 : -1
        i = @cursor
        delta.abs.times do
          j = i + step
          while j >= 0 && j < list.size && !list[j].selectable?
            j += step
          end
          break unless j >= 0 && j < list.size
          i = j
        end
        @cursor = i
        fix_cursor
      end

      def to(index : Int32) : Nil
        @cursor = index
        fix_cursor
      end

      def to_last : Nil
        to(entries.size - 1)
      end

      # never on a header: the next selectable line, at the end the one before
      def fix_cursor : Nil
        list = entries
        if list.empty?
          @cursor = 0
          return
        end
        i = @cursor.clamp(0, list.size - 1)
        j = i
        while j < list.size && !list[j].selectable?
          j += 1
        end
        if j >= list.size
          j = i
          while j > 0 && !list[j].selectable?
            j -= 1
          end
        end
        @cursor = j
      end

      # scroll so the cursor is visible in `height` lines
      def scroll(height : Int32) : Nil
        @offset = @cursor - height + 1 if @cursor >= @offset + height
        @offset = @cursor if @cursor < @offset
        @offset = @offset.clamp(0, Math.max(0, entries.size - height))
      end

      def expanded?(key : String, default : Bool) : Bool
        default ? !@collapsed.includes?(key) : @expanded.includes?(key)
      end

      def set_expanded(e : Entry, on : Bool) : Nil
        key = e.key
        if on
          @expanded << key
          @collapsed.delete(key)
        else
          @expanded.delete(key)
          @collapsed << key
        end
        changed
        keep_cursor(key)
      end

      # back to the line with this key after a rebuild
      def keep_cursor(key : String) : Nil
        if i = entries.index { |e| e.key == key }
          @cursor = i
        end
        fix_cursor
      end

      # the line of the parent node (folding with h)
      def parent_index : Int32?
        e = current || return nil
        return nil if e.depth == 0
        (0...@cursor).reverse_each do |i|
          return i if entries[i].depth < e.depth && entries[i].kind.item?
        end
        nil
      end

      private def build : Array(Entry)
        q = @query
        acc = [] of Entry
        acc << Entry.new(Kind::Item, "all", "Alle Bücher", active: !q.filters?, apply: ->(_q : Query) { Query.new })
        build_lists(acc, q)
        build_categories(acc, q)
        build_fast_tags(acc, q)
        cats = @categories
        if cats
          named(acc, "authors", "Autoren", cats["authors"]?, q.author.try { |a| [a] } || [] of String) do |n|
            ->(x : Query) { x.copy_with(author: x.author == n ? nil : n) }
          end
          named(acc, "series", "Serien", cats["series"]?, q.series.try { |s| [s] } || [] of String) do |n|
            ->(x : Query) { x.copy_with(series: x.series == n ? nil : n) }
          end
          named(acc, "tags", "Tags", cats["tags"]?, q.tags) do |n|
            ->(x : Query) { x.toggle_tag(n) }
          end
          if (langs = cats["languages"]?.try(&.as_a?)) && langs.size > 1
            named(acc, "languages", "Sprachen", cats["languages"]?, q.lang.try { |l| [l] } || [] of String) do |n|
              ->(x : Query) { x.copy_with(lang: x.lang == n ? nil : n) }
            end
          end
        end
        acc
      end

      # lists as a tree by their path; a level without a list of its own
      # ("Reise" above "Reise/Meer") filters by listPath
      private def build_lists(acc, q : Query) : Nil
        all = @lists.try(&.as_a?) || return
        return if all.empty?
        by_name = {} of String => JSON::Any
        all.each { |l| l["name"]?.try(&.as_s?).try { |n| by_name[n] = l } }
        paths = Set(String).new
        by_name.each_key do |name|
          parts = name.split('/')
          (1..parts.size).each { |i| paths << parts[0, i].join('/') }
        end
        acc << Entry.new(Kind::Header, "h:lists", "Listen")
        list_nodes(acc, paths, by_name, nil, 0, q)
      end

      private def list_nodes(acc, paths : Set(String), by_name : Hash(String, JSON::Any), parent : String?,
                             depth : Int32, q : Query) : Nil
        children = ->(of : String?) {
          paths.select { |p| (i = p.rindex('/')) ? p[0, i] == of : of.nil? }.sort_by(&.downcase)
        }
        children.call(parent).each do |path|
          list = by_name[path]?
          id = list.try(&.["id"]?.try(&.as_i64?))
          count = list.try { |l| (l["totalCount"]? || l["count"]?).try(&.as_i64?) }
          kids = !children.call(path).empty?
          key = "l:#{path}"
          open = expanded?(key, true)
          active = id ? q.list == id : (q.list.nil? && q.list_path == path)
          apply = if id
                    ->(x : Query) { x.list == id ? Query.new : Query.new(list: id) }
                  else
                    ->(x : Query) { x.list_path == path && x.list.nil? ? Query.new : Query.new(list_path: path) }
                  end
          acc << Entry.new(Kind::Item, key, path.split('/').last, depth, count, kids, open, active, apply)
          list_nodes(acc, paths, by_name, path, depth + 1, q) if kids && open
        end
      end

      private def build_categories(acc, q : Query) : Nil
        column = @category_column || return
        nodes = @categories.try(&.["kategorie"]?).try(&.as_a?) || [] of JSON::Any
        unsorted = @unsorted_count
        return if nodes.empty? && (unsorted.nil? || unsorted == 0) && !q.unsorted
        acc << Entry.new(Kind::Header, "h:kategorie", "Kategorien")
        if (unsorted && unsorted > 0) || q.unsorted
          acc << Entry.new(Kind::Item, "unsorted", "Ohne Kategorie", count: unsorted, active: q.unsorted,
            apply: ->(x : Query) { x.copy_with(unsorted: !x.unsorted, kategorie: nil) })
        end
        category_nodes(acc, nodes, 0, q)
      end

      private def category_nodes(acc, nodes : Array(JSON::Any), depth : Int32, q : Query) : Nil
        nodes.each do |n|
          path = n["path"]?.try(&.as_s?) || next
          kids = n["children"]?.try(&.as_a?) || [] of JSON::Any
          key = "k:#{path}"
          # open above the active category, closed otherwise
          inside = q.kategorie.try { |k| k.starts_with?("#{path}.") } || false
          open = !kids.empty? && (inside ? !@collapsed.includes?(key) : @expanded.includes?(key))
          acc << Entry.new(Kind::Item, key, n["name"]?.try(&.as_s?) || path, depth,
            n["count"]?.try(&.as_i64?), !kids.empty?, open, q.kategorie == path,
            ->(x : Query) { x.copy_with(kategorie: x.kategorie == path ? nil : path, unsorted: false) })
          category_nodes(acc, kids, depth + 1, q) if open
        end
      end

      private def build_fast_tags(acc, q : Query) : Nil
        return if @fast_tags.empty?
        counts = {} of String => Int64
        @categories.try(&.["tags"]?).try(&.as_a?).try &.each do |t|
          name = t["name"]?.try(&.as_s?)
          counts[name] = t["count"]?.try(&.as_i64?) || 0_i64 if name
        end
        acc << Entry.new(Kind::Header, "h:fast", "Fast-Tags")
        @fast_tags.each do |tag|
          acc << Entry.new(Kind::Item, "f:#{tag}", tag, count: counts[tag]?, active: q.tags.includes?(tag),
            apply: ->(x : Query) { x.toggle_tag(tag) })
        end
      end

      # authors, series, tags: the most frequent ones, or all alphabetically
      private def named(acc, kind : String, title : String, items : JSON::Any?, selected : Array(String),
                        & : String -> Proc(Query, Query)) : Nil
        all = (items.try(&.as_a?) || return).compact_map do |i|
          name = i["name"]?.try(&.as_s?)
          name ? {name, i["count"]?.try(&.as_i64?) || 0_i64} : nil
        end
        return if all.empty?
        more = "more:#{kind}"
        open = @expanded.includes?(more)
        shown = if open
                  all.sort_by { |(n, _)| n.downcase }
                else
                  all.sort_by { |(n, c)| {-c, n.downcase} }.first(COLLAPSED)
                end
        # the selected ones stay visible
        missing = all.select { |(n, _)| selected.includes?(n) && !shown.any? { |(s, _)| s == n } }
        acc << Entry.new(Kind::Header, "h:#{kind}", title)
        (missing + shown).each do |(name, count)|
          acc << Entry.new(Kind::Item, "#{kind}:#{name}", name, count: count, active: selected.includes?(name),
            apply: yield name)
        end
        if all.size > COLLAPSED
          acc << Entry.new(Kind::More, more, open ? "Weniger" : "Alle #{all.size} anzeigen", expanded: open)
        end
      end
    end
  end
end
