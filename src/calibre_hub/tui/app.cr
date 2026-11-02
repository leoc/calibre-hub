require "bubbletea"
require "./text"
require "./keys"
require "./query"
require "./markdown"
require "./source"
require "./rows"
require "./sidebar"
require "./theme"

module CalibreHub
  module Tui
    # A page of books arrived (or failed) for the query of `generation`
    class PageMsg < Tea::Msg
      getter generation : Int32
      getter page : Int32
      getter result : JSON::Any?
      getter error : String?

      def initialize(@generation, @page, @result = nil, @error = nil)
      end
    end

    # One book with all fields (the detail), or why not
    class BookMsg < Tea::Msg
      getter id : Int64
      getter result : JSON::Any?
      getter error : String?

      def initialize(@id, @result = nil, @error = nil)
      end
    end

    # Sidebar data: config, categories, lists, count of books without category
    class MetaMsg < Tea::Msg
      getter config : JSON::Any?
      getter categories : JSON::Any?
      getter lists : JSON::Any?
      getter unsorted : Int64?
      getter error : String?

      def initialize(@config, @categories, @lists, @unsorted, @error = nil)
      end
    end

    # The library browser: sidebar | book table, a detail view, `/` search,
    # Vim movement. Read-only; all data comes from a `Source`.
    class App
      include Tea::Model

      enum Focus
        List
        Sidebar
      end

      # a step back (q/Esc): the query with the cursor where it was
      record Place, query : Query, cursor : Int32, offset : Int32

      SIDEBAR_WIDTH = 32
      # narrower than this, the sidebar only shows while it has the focus
      SIDEBAR_MIN = 90

      getter query = Query.new
      getter rows = Rows.new
      getter sidebar = Sidebar.new
      getter cursor = 0
      getter offset = 0
      getter focus = Focus::List
      getter width = 100
      getter height = 30
      getter detail : Int32? = nil
      getter detail_scroll = 0
      getter? help = false
      getter? searching = false
      getter message : String? = nil
      getter? error = false
      getter history = [] of Place
      getter category_column : String? = nil
      # "auto" from the terminal; specs pin it
      property glamour_style = "auto"
      @keys = KeyEngine.new
      @input : Bubbles::TextInput? = nil
      @detail_lines = [] of String
      @detail_for : {Int64, Int32, Bool}? = nil
      # books with all fields, by id (lists leave out the description)
      @full = {} of Int64 => Book
      @fetching = Set(Int64).new

      def initialize(@source : Source)
      end

      def init : Tea::Cmd?
        Tea.batch(load_meta, load_visible)
      end

      # --- update ---------------------------------------------------------

      def update(msg : Tea::Msg) : Tea::Cmd?
        case msg
        when Tea::KeyMsg
          key(msg)
        when Tea::WindowSizeMsg
          @width = Math.max(20, msg.width)
          @height = Math.max(6, msg.height)
          @input.try(&.configure(width: @width - 4))
          scroll_to_cursor
          @detail_for = nil
          load_visible
        when PageMsg
          page(msg)
        when MetaMsg
          meta(msg)
        when BookMsg
          @fetching.delete(msg.id)
          if r = msg.result
            @full[msg.id] = Book.new(r)
            @detail_for = nil
          else
            show_error(msg.error || "")
          end
          nil
        else
          # cursor blink of the search field
          @searching ? @input.try(&.update(msg)) : nil
        end
      end

      private def page(msg : PageMsg) : Tea::Cmd?
        if err = msg.error
          @rows.failed(msg.generation, msg.page)
          show_error(err)
          return nil
        end
        result = msg.result || return nil
        books = result["books"].as_a.map { |b| Book.new(b) }
        return nil unless @rows.store(msg.generation, msg.page, result["total"].as_i, books)
        @cursor = @cursor.clamp(0, Math.max(0, @rows.size - 1))
        scroll_to_cursor
        @detail_for = nil
        Tea.batch(load_visible, @detail.try { |d| load_full(d) })
      end

      private def meta(msg : MetaMsg) : Tea::Cmd?
        show_error(msg.error.not_nil!) if msg.error
        if c = msg.config
          @category_column = c["categoryColumn"]?.try(&.as_s?).presence
          @sidebar.category_column = @category_column
          @sidebar.fast_tags = c["fastTags"]?.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
        end
        @sidebar.categories = msg.categories if msg.categories
        @sidebar.lists = msg.lists if msg.lists
        @sidebar.unsorted_count = msg.unsorted
        @sidebar.changed
        @sidebar.fix_cursor
        nil
      end

      private def show_error(text : String) : Nil
        @message = text
        @error = true
      end

      private def key(msg : Tea::KeyMsg) : Tea::Cmd?
        return Tea.quit if msg.key == "ctrl+c"
        @message = nil
        @error = false
        return search_key(msg) if @searching
        if @help
          @help = false
          @keys.reset
          return nil
        end
        cmds = [] of Tea::Cmd?
        Tui.tokens(msg).each do |tok|
          r = @keys.feed(tok)
          next unless r.is_a?(KeyEngine::Fired)
          cmd = act(r.action, r.count, tok)
          return cmd if cmd.is_a?(Tea::ControlCmd) && cmd.type == "quit"
          cmds << cmd
        end
        Tea.batch(cmds)
      end

      # Enter searches (like the web app's search field), Esc cancels
      private def search_key(msg : Tea::KeyMsg) : Tea::Cmd?
        input = @input.not_nil!
        case msg.key
        when "enter"
          @searching = false
          @focus = Focus::List
          input.blur
          navigate(@query.copy_with(q: input.value.strip.presence))
        when "esc"
          @searching = false
          input.blur
          nil
        else
          input.update(msg)
        end
      end

      # what typed keys mean here, for the status line
      def pending_keys : String
        @keys.pending
      end

      private def act(action : Action, count : Int32?, token : String) : Tea::Cmd?
        case action
        when .quit?   then return Tea.quit
        when .help?   then @help = true; return nil
        when .search? then return start_search
        end
        return detail_act(action, count, token) if @detail
        return sidebar_act(action, count, token) if @focus.sidebar?
        list_act(action, count, token)
      end

      private def common_act(action : Action, token : String) : Tea::Cmd?
        case action
        when .sort?        then requery(@query.next_sort)
        when .order?       then requery(@query.reverse_order)
        when .go_library?  then navigate(Query.new)
        when .switch_pane? then @focus = @focus.list? ? Focus::Sidebar : Focus::List; nil
        when .back?        then back(token)
        end
      end

      private def list_act(action : Action, count : Int32?, token : String) : Tea::Cmd?
        n = count || 1
        page = Math.max(1, rows_height)
        case action
        when .down?      then move(n)
        when .up?        then move(-n)
        when .first?     then move_to(count ? count - 1 : 0)
        when .last?      then move_to(count ? count - 1 : @rows.size - 1)
        when .half_down? then scroll_by(n * Math.max(1, page // 2))
        when .half_up?   then scroll_by(-n * Math.max(1, page // 2))
        when .next_page? then scroll_by(n * page)
        when .prev_page? then scroll_by(-n * page)
        when .open?      then open_detail(@cursor)
        when .left?      then @focus = Focus::Sidebar; nil
        when .search_next?, .search_prev?
          return no_search unless @query.q.presence
          move(action.search_next? ? n : -n)
        else common_act(action, token)
        end
      end

      private def sidebar_act(action : Action, count : Int32?, token : String) : Tea::Cmd?
        n = count || 1
        half = Math.max(1, body_height // 2)
        sb = @sidebar
        case action
        when .down?      then sb.move(n)
        when .up?        then sb.move(-n)
        when .first?     then count ? sb.to(count - 1) : sb.to(0)
        when .last?      then count ? sb.to(count - 1) : sb.to_last
        when .half_down? then sb.move(n * half)
        when .half_up?   then sb.move(-n * half)
        when .next_page? then sb.move(n * body_height)
        when .prev_page? then sb.move(-n * body_height)
        when .open?
          e = sb.current || return nil
          if e.kind.more?
            sb.set_expanded(e, !e.expanded)
          elsif apply = e.apply
            return navigate(apply.call(@query))
          end
        when .right?
          e = sb.current || return nil
          if e.children && !e.expanded
            sb.set_expanded(e, true)
          elsif e.children
            sb.move(1)
          else
            @focus = Focus::List
          end
        when .left?
          e = sb.current || return nil
          if e.children && e.expanded
            sb.set_expanded(e, false)
          elsif i = sb.parent_index
            sb.to(i)
          end
        when .search_next?, .search_prev?
          return @query.q.presence ? (@focus = Focus::List; move(action.search_next? ? n : -n)) : no_search
        else return common_act(action, token)
        end
        sb.scroll(body_height)
        nil
      end

      private def detail_act(action : Action, count : Int32?, token : String) : Tea::Cmd?
        n = count || 1
        h = body_height
        case action
        when .down?      then scroll_detail(n)
        when .up?        then scroll_detail(-n)
        when .half_down? then scroll_detail(n * Math.max(1, h // 2))
        when .half_up?   then scroll_detail(-n * Math.max(1, h // 2))
        when .next_page? then scroll_detail(n * h)
        when .prev_page? then scroll_detail(-n * h)
        when .first?     then @detail_scroll = 0
        when .last?      then scroll_detail(Int32::MAX // 2)
        when .search_next?, .search_prev?
          # the next or previous book of the result
          target = (@detail.not_nil! + (action.search_next? ? n : -n)).clamp(0, Math.max(0, @rows.size - 1))
          move_to(target)
          return open_detail(target)
        when .back?, .left?
          @detail = nil
          return load_visible
        when .sort?, .order?, .go_library?
          @detail = nil
          return common_act(action, token)
        end
        nil
      end

      private def no_search : Nil
        @message = "Keine Suche aktiv (/ sucht)"
        nil
      end

      private def start_search : Tea::Cmd?
        @detail = nil
        @searching = true
        input = @input ||= Bubbles::TextInput.new(prompt: "/", width: @width - 4,
          placeholder: "calibre-Suche, z. B. title:dune or tags:sf",
          prompt_style: Theme.accent, placeholder_style: Theme.muted)
        input.value = @query.q || ""
        input.cursor_end
        input.focus
      end

      # q/Esc: close what is open, else the previous view; q at the start quits
      private def back(token : String) : Tea::Cmd?
        if place = @history.pop?
          set_query(place.query)
          @cursor = place.cursor
          @offset = place.offset
          return load_visible
        end
        return Tea.quit if token == "q"
        @focus = Focus::List if @focus.sidebar?
        nil
      end

      # A new view of the library; q/Esc go back to the one before
      def navigate(q : Query) : Tea::Cmd?
        return nil if q == @query
        @history << Place.new(@query, @cursor, @offset)
        set_query(q)
        load_visible
      end

      # sort and order change the view, not the place: no step back
      private def requery(q : Query) : Tea::Cmd?
        set_query(q)
        load_visible
      end

      private def set_query(q : Query) : Nil
        @query = q
        @rows.reset
        @cursor = 0
        @offset = 0
        @detail = nil
        @sidebar.query = q
      end

      # --- movement -------------------------------------------------------

      private def move(delta : Int32) : Tea::Cmd?
        move_to(@cursor + delta)
      end

      private def move_to(index : Int32) : Tea::Cmd?
        @cursor = index.clamp(0, Math.max(0, @rows.size - 1))
        scroll_to_cursor
        load_visible
      end

      # Ctrl-d/u, pages: cursor and screen move together, like Vim
      private def scroll_by(delta : Int32) : Tea::Cmd?
        last = Math.max(0, @rows.size - 1)
        @offset = (@offset + delta).clamp(0, Math.max(0, @rows.size - rows_height))
        @cursor = (@cursor + delta).clamp(0, last)
        scroll_to_cursor
        load_visible
      end

      private def scroll_to_cursor : Nil
        h = Math.max(1, rows_height)
        @offset = @cursor - h + 1 if @cursor >= @offset + h
        @offset = @cursor if @cursor < @offset
        @offset = @offset.clamp(0, Math.max(0, @rows.size - h))
      end

      private def scroll_detail(delta : Int32) : Nil
        render_detail
        max = Math.max(0, @detail_lines.size - body_height)
        @detail_scroll = (@detail_scroll.to_i64 + delta).clamp(0, max).to_i
      end

      private def open_detail(index : Int32) : Tea::Cmd?
        return nil if @rows.size == 0
        @detail = index
        @detail_scroll = 0
        @detail_for = nil
        Tea.batch(load_pages(index, index), load_full(index))
      end

      # the open book with its description, once per book
      private def load_full(index : Int32) : Tea::Cmd?
        id = @rows[index].try(&.id) || return nil
        return nil if @full.has_key?(id) || @fetching.includes?(id)
        @fetching << id
        source = @source
        Tea.cmd do
          begin
            BookMsg.new(id, source.book(id)).as(Tea::Msg)
          rescue ex
            BookMsg.new(id, error: ex.message || ex.class.name).as(Tea::Msg)
          end
        end
      end

      # --- loading --------------------------------------------------------

      # the pages on screen and one screen further
      private def load_visible : Tea::Cmd?
        h = Math.max(1, rows_height)
        from = @offset
        to = @offset + 2 * h
        d = @detail
        return Tea.batch(load_pages(from, to), load_pages(d, d)) if d
        load_pages(from, to)
      end

      private def load_pages(from : Int32, to : Int32) : Tea::Cmd?
        Tea.batch(@rows.wanted(from, to).map { |p| fetch(p) })
      end

      private def fetch(page : Int32) : Tea::Cmd
        generation = @rows.generation
        params = @query.params(page * @rows.page_size, @rows.page_size, @category_column)
        source = @source
        Tea.cmd do
          begin
            PageMsg.new(generation, page, source.books(params)).as(Tea::Msg)
          rescue ex
            PageMsg.new(generation, page, error: ex.message || ex.class.name).as(Tea::Msg)
          end
        end
      end

      private def load_meta : Tea::Cmd
        source = @source
        Tea.cmd do
          errors = [] of String
          get = ->(f : -> JSON::Any) {
            begin
              f.call
            rescue ex
              errors << (ex.message || ex.class.name)
              nil
            end
          }
          config = get.call(-> { source.config })
          categories = get.call(-> { source.categories })
          # older hubs have no lists
          lists = (source.lists rescue nil)
          column = config.try(&.["categoryColumn"]?).try(&.as_s?).presence
          unsorted = column.try do |c|
            p = HTTP::Params.new
            p["q"] = Query.unsorted_query(c)
            p["limit"] = "1"
            get.call(-> { source.books(p) }).try(&.["total"]?).try(&.as_i64?)
          end
          MetaMsg.new(config, categories, lists, unsorted, errors.first?).as(Tea::Msg)
        end
      end

      # --- view -----------------------------------------------------------

      def body_height : Int32
        Math.max(1, @height - 2)
      end

      # table lines without its header
      def rows_height : Int32
        Math.max(1, body_height - 1)
      end

      private def sidebar_visible? : Bool
        @width >= SIDEBAR_MIN || @focus.sidebar?
      end

      private def sidebar_width : Int32
        @width >= SIDEBAR_MIN ? SIDEBAR_WIDTH : @width
      end

      def view : String
        body = if @help
                 help_view
               elsif d = @detail
                 detail_view(d)
               elsif sidebar_visible? && sidebar_width >= @width
                 sidebar_view(@width)
               elsif sidebar_visible?
                 w = sidebar_width
                 Lipgloss.join_horizontal(:top, sidebar_view(w - 1), separator, table_view(@width - w))
               else
                 table_view(@width)
               end
        [header_view, body, status_view].join('\n')
      end

      private def separator : String
        Theme.border.render((["│"] * body_height).join('\n'))
      end

      private def header_view : String
        left = Theme.title.render("calibre-hub")
        chips = @query.chips(@sidebar.list_names).map do |(label, value)|
          Theme.chip.render(label.empty? ? value : "#{label}: #{value}")
        end
        s, o = @query.effective_sort
        count = @rows.loaded? ? "#{@rows.size} #{@rows.size == 1 ? "Buch" : "Bücher"}" : "lädt …"
        right = Theme.muted.render("#{count} · #{SORT_NAMES[s]? || s} #{o == "asc" ? "↑" : "↓"}")
        middle = chips.join(" ")
        used = Lipgloss.width(left) + Lipgloss.width(right) + 2
        middle = "" if Lipgloss.width(middle) > @width - used
        gap = Math.max(1, @width - used - Lipgloss.width(middle))
        "#{left} #{middle}#{" " * gap}#{right}"
      end

      private def status_view : String
        if @searching
          return @input.not_nil!.view
        end
        if m = @message
          return @error ? Theme.error.render(Text.truncate(m, @width)) : Theme.muted.render(Text.truncate(m, @width))
        end
        hint = if @detail
                 "j/k scrollen · n/N nächstes/voriges Buch · q zurück · ? Hilfe"
               elsif @focus.sidebar?
                 "Enter Filter · l/h auf/zu · Tab Bibliothek · ? Hilfe"
               else
                 "Enter öffnen · / suchen · h Seitenleiste · o Sortierung · ? Hilfe"
               end
        pos = @rows.size > 0 ? "#{(@detail || @cursor) + 1}/#{@rows.size}" : ""
        pending = @keys.pending
        right = [pending, pos].reject(&.empty?).join("  ")
        left = Text.truncate(hint, Math.max(0, @width - Text.width(right) - 2))
        Theme.muted.render(left) + " " * Math.max(1, @width - Text.width(left) - Text.width(right)) + Theme.accent.render(right)
      end

      record Column, title : String, weight : Int32, min : Int32

      COLUMNS = [
        Column.new("Titel", 40, 16),
        Column.new("Autor", 20, 10),
        Column.new("Serie", 14, 8),
        Column.new("Kategorie", 14, 8),
        Column.new("Tags", 12, 6),
      ]

      # column widths for `width` cells; the right ones go first when narrow
      def column_widths(width : Int32) : Array(Int32)
        cols = COLUMNS.dup
        cols.reject! { |c| c.title == "Kategorie" } unless @category_column
        while cols.size > 1 && cols.sum(&.min) + cols.size - 1 > width
          cols.pop
        end
        avail = width - (cols.size - 1)
        total = cols.sum(&.weight)
        widths = cols.map { |c| Math.max(c.min, avail * c.weight // total) }
        widths[0] += avail - widths.sum
        widths[0] = Math.max(1, widths[0])
        widths
      end

      private def table_view(width : Int32) : String
        widths = column_widths(width)
        titles = COLUMNS.reject { |c| c.title == "Kategorie" && !@category_column }.map(&.title)
        head = widths.map_with_index { |w, i| Text.fit(titles[i], w) }.join(" ")
        lines = [Theme.header.render(head)]
        h = rows_height
        if @rows.loaded? && @rows.size == 0
          lines << Theme.muted.render(@query.filters? ? "Keine Bücher gefunden." : "Die Bibliothek ist leer.")
        end
        (@offset...Math.min(@offset + h, @rows.size)).each do |i|
          lines << row_view(i, widths)
        end
        lines << Theme.muted.render("Lädt …") if !@rows.loaded? && @rows.loading?
        lines.concat([""] * Math.max(0, h + 1 - lines.size))
        lines.first(h + 1).join('\n')
      end

      private def row_view(i : Int32, widths : Array(Int32)) : String
        book = @rows[i]
        cells = if b = book
                  [b.title, b.authors.join(", "), b.series_label,
                   b.category(@category_column).try { |c| Tui.category_label(c) } || "", b.tags.join(", ")]
                else
                  ["…", "", "", "", ""]
                end
        cells.delete_at(3) unless @category_column
        if i == @cursor
          line = widths.map_with_index { |w, j| Text.fit(cells[j], w) }.join(" ")
          return Theme.cursor(@focus.list?).bold(@focus.list?).render(line)
        end
        widths.map_with_index do |w, j|
          text = Text.fit(cells[j], w)
          j == 0 ? Theme.text.render(text) : Theme.muted.render(text)
        end.join(" ")
      end

      private def sidebar_view(width : Int32) : String
        sb = @sidebar
        h = body_height
        sb.scroll(h)
        entries = sb.entries
        lines = (sb.offset...Math.min(sb.offset + h, entries.size)).map do |i|
          sidebar_line(entries[i], width, i == sb.cursor)
        end
        lines << Theme.muted.render(Text.fit("Lädt …", width)) if entries.size <= 1 && lines.size < h
        lines.concat([" " * width] * Math.max(0, h - lines.size))
        lines.join('\n')
      end

      private def sidebar_line(e : Sidebar::Entry, width : Int32, selected : Bool) : String
        if e.kind.header?
          return Theme.header.render(Text.fit(e.label.upcase, width))
        end
        marker = e.children ? (e.expanded ? "▾ " : "▸ ") : "  "
        label = "#{"  " * e.depth}#{marker}#{e.label}"
        label = "  #{e.label}" if e.kind.more?
        count = e.count.try(&.to_s) || ""
        left = Text.fit(label, Math.max(1, width - Text.width(count) - 2))
        line = Text.fit("#{left} #{count}", width)
        if selected && @focus.sidebar?
          Theme.cursor(true).bold.render(line)
        elsif e.active
          Theme.accent.bold.render(line)
        elsif e.kind.more?
          Theme.muted.italic.render(line)
        else
          Theme.text.render(line)
        end
      end

      private def detail_view(index : Int32) : String
        render_detail
        h = body_height
        @detail_scroll = @detail_scroll.clamp(0, Math.max(0, @detail_lines.size - h))
        lines = @detail_lines[@detail_scroll, h]? || [] of String
        lines += [""] * Math.max(0, h - lines.size)
        lines.join('\n')
      end

      # the open book's lines, rendered again when book or width change
      private def render_detail : Nil
        index = @detail || return
        row = @rows[index]
        unless row
          @detail_lines = [Theme.muted.render("  Lädt …")]
          @detail_for = nil
          return
        end
        full = @full[row.id]?
        key = {row.id, @width, !full.nil?}
        return if @detail_for == key
        @detail_for = key
        @detail_lines = detail_text(full || row, complete: !full.nil?).split('\n')
      end

      def detail_text(book : Book, complete = true) : String
        inner = Math.min(@width, 110) - 4
        cover_w = inner >= 60 ? 18 : 0
        meta_w = Math.max(10, inner - cover_w - (cover_w > 0 ? 2 : 0))
        meta = [] of String
        Text.wrap(book.title, meta_w).each { |l| meta << Theme.title.render(l) }
        authors = book.authors.join(", ")
        Text.wrap(authors, meta_w).each { |l| meta << Theme.text.render(l) } unless authors.empty?
        meta << ""
        fields = [] of {String, String}
        fields << {"Serie", book.series_label} if book.series
        book.category(@category_column).try { |c| fields << {"Kategorie", Tui.category_label(c)} }
        fields << {"Tags", book.tags.join(", ")} unless book.tags.empty?
        names = @sidebar.list_names
        lists = book.lists.compact_map { |id| names[id]? }
        fields << {"Listen", lists.join(", ")} unless lists.empty?
        fields << {"Sprachen", book.languages.join(", ")} unless book.languages.empty?
        book.publisher.try { |p| fields << {"Verlag", p} }
        book.date("pubdate").try { |d| fields << {"Erschienen", d} }
        book.date("added").try { |d| fields << {"Hinzugefügt", d} }
        book.rating.try { |r| fields << {"Bewertung", Detail.stars(r)} if r > 0 }
        fields << {"Formate", book.formats.join(", ")} unless book.formats.empty?
        ids = book.identifiers
        fields << {"Kennungen", ids.map { |k, v| "#{k}:#{v}" }.join(", ")} unless ids.empty?
        label_w = 12
        fields.each do |(label, value)|
          wrapped = Text.wrap(value, Math.max(4, meta_w - label_w))
          wrapped.each_with_index do |l, i|
            meta << Theme.muted.render(Text.fit(i == 0 ? label : "", label_w)) + Theme.text.render(l)
          end
        end
        top = meta.join('\n')
        if cover_w > 0
          cover = Theme.cover.width(cover_w - 2).height(9).render("Cover\n\n(im Terminal\nnoch nicht)")
          top = Lipgloss.join_horizontal(:top, cover, "  ", top)
        end
        top = Lipgloss::Style.new.padding(1, 2, 0, 2).render(top)
        description = Markdown.from_html(book.comments)
        return "#{top}\n\n  #{Theme.muted.render("Beschreibung lädt …")}\n" if description.empty? && !complete
        return top + "\n" if description.empty?
        rendered = begin
          Glamour.render(description, style: @glamour_style, width: inner)
        rescue ex
          Text.wrap(Markdown.plain(book.comments), inner).join('\n')
        end
        "#{top}\n#{rendered.rstrip}\n"
      end

      private def help_view : String
        lines = [Theme.title.render("Tastenkürzel"), ""] of String
        HELP_GROUPS.each do |(title, actions)|
          lines << Theme.header.render(title)
          actions.each do |a|
            keys = (DEFAULT_BINDINGS[a]? || [] of String).map { |k| Tui.format_keys(k) }.join(", ")
            lines << "  #{Theme.accent.render(Text.fit(keys, 24))} #{Theme.text.render(HELP_TEXT[a]? || a.name)}"
          end
          lines << ""
        end
        lines << Theme.muted.render("Taste drücken zum Schließen")
        h = body_height
        acc = lines.first(h)
        acc += [""] * Math.max(0, h - acc.size)
        Lipgloss::Style.new.padding(0, 2).render(acc.join('\n'))
      end
    end

    module Detail
      # rating in half stars (0..10) as five stars
      def self.stars(rating : Float64) : String
        full = (rating / 2).round.to_i.clamp(0, 5)
        "★" * full + "☆" * (5 - full)
      end
    end
  end
end
