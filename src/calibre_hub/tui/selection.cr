require "bubbletea"

module CalibreHub
  module Tui
    # "▕██████░░░░▏ 12/40"
    def self.progress(done : Int64, total : Int64?, width = 16) : String
      return "#{done}/?" unless total && total > 0
      full = (width * done.clamp(0, total) // total).to_i
      "▕#{"█" * full}#{"░" * (width - full)}▏ #{done}/#{total}"
    end

    # visual mode: the row it started on and the selection before it, like
    # the web app's keyboard.visual (an index: the rows load lazily)
    record Visual, anchor : Int32, base : Array(Int64)

    # The selection of the library, like the web app's selection and visual
    # mode (frontend/src/lib/selection.ts, components/keyboard.tsx): ids in
    # the order they were selected, a range while in visual mode, or all
    # matches of the query (a {query, expect} target for the bulk API).
    class App
      getter visual : Visual? = nil
      # all matches of this query are selected
      getter all : Query? = nil
      # where Shift+movement extends from: the book toggled last
      @anchor : Int64? = nil
      # a command waiting for the rows of a visual range
      @when_loaded : Later? = nil

      def visual? : Bool
        !@visual.nil?
      end

      def selecting? : Bool
        !@selection.empty? || !@visual.nil? || !@all.nil?
      end

      # rows from..to of the visual range
      def visual_range : Range(Int32, Int32)?
        v = @visual || return nil
        Math.min(v.anchor, @cursor)..Math.max(v.anchor, @cursor)
      end

      # what visual mode selects so far: the ids of loaded rows and how many
      # rows of the range aren't loaded yet
      def visual_ids : {Array(Int64), Int32}
        v = @visual || return {@selection, 0}
        ids = v.base.dup
        seen = ids.to_set
        missing = 0
        visual_range.not_nil!.each do |i|
          if b = @rows[i]
            ids << b.id if seen.add?(b.id)
          else
            missing += 1
          end
        end
        {ids, missing}
      end

      # how many books are selected (0: none)
      def selection_size : Int32
        return @rows.size if @all
        return @selection.size unless @visual
        ids, missing = visual_ids
        ids.size + missing
      end

      # marked in the table
      def selected?(id : Int64, index : Int32? = nil) : Bool
        return true if @all
        if index && (r = visual_range) && r.includes?(index)
          return true
        end
        (@visual.try(&.base) || @selection).includes?(id)
      end

      def selection_label : String
        return "alle #{@rows.size} Treffer ausgewählt" if @all
        n = selection_size
        return "-- VISUELL -- #{n}" if @visual
        n > 0 ? "#{n} ausgewählt" : ""
      end

      # --- changing it ------------------------------------------------------

      # v: starts visual mode at the cursor, again: ends it (the selection stays)
      def toggle_visual : Tea::Cmd?
        return end_visual if @visual
        return nil unless @rows[@cursor]
        @all = nil
        @visual = Visual.new(@cursor, @selection.dup)
        nil
      end

      def end_visual : Tea::Cmd?
        _, cmd = settle_visual { nil }
        cmd
      end

      # Ends visual mode, its range becoming the selection. A range with rows
      # not loaded yet loads them first, then `again` runs: {true, the
      # loading} until then, {false, nil} when the caller can go on now.
      def settle_visual(&again : -> Tea::Cmd?) : {Bool, Tea::Cmd?}
        return {false, nil} unless @visual
        ids, missing = visual_ids
        if missing > 0
          r = visual_range.not_nil!
          # the whole result from nothing: its query, no need to load it
          if r.begin == 0 && r.end >= @rows.size - 1 && @visual.not_nil!.base.empty?
            @visual = nil
            @all = @query
            return {false, nil}
          end
          @when_loaded = again
          @message = "Auswahl lädt (#{missing} Bücher) …"
          return {true, load_range(r.begin, r.end)}
        end
        @selection = ids
        @visual = nil
        {false, nil}
      end

      # the pages of rows from..to one after another (a long range doesn't
      # send all its requests at once)
      private def load_range(from : Int32, to : Int32) : Tea::Cmd?
        Tea.sequence(@rows.wanted(from, to).map { |p| fetch(p).as(Tea::Cmd?) })
      end

      # after a page arrived: the command waiting for the range, once it is there
      private def run_when_loaded : Tea::Cmd?
        w = @when_loaded || return nil
        return nil if @visual && visual_ids[1] > 0
        @when_loaded = nil
        w.call
      end

      private def drop_waiting : Nil
        @when_loaded = nil
      end

      # Space: the book in or out (all matches become the books picked by hand)
      def toggle_select : Tea::Cmd?
        # in visual mode: its end, the range stays selected
        return end_visual if @visual
        book = @rows[@detail || @cursor] || return nil
        @all = nil
        @anchor = book.id
        if @selection.includes?(book.id)
          @selection.delete(book.id)
        else
          @selection << book.id
        end
        nil
      end

      # Ctrl-a: all matches of the search (the web app's "Alle Treffer")
      def select_all : Tea::Cmd?
        @visual = nil
        drop_waiting
        @selection.clear
        @all = @query
        @message = @rows.loaded? ? "Alle #{@rows.size} Treffer ausgewählt" : nil
        nil
      end

      def clear_selection : Nil
        @selection.clear
        @visual = nil
        @all = nil
        @anchor = nil
        drop_waiting
      end

      # Shift+↓/↑: moves and adds the books from the anchor to the cursor
      private def extend_selection(delta : Int32) : Tea::Cmd?
        return nil unless @rows[@cursor]
        waiting, cmd = settle_visual { extend_selection(delta) }
        return cmd if waiting
        from = @anchor.try { |id| @selection.includes?(id) ? @rows.index_of(id) : nil } || @cursor
        @anchor = @rows[from].try(&.id)
        @all = nil
        cmd = move(delta)
        (Math.min(from, @cursor)..Math.max(from, @cursor)).each do |i|
          @rows[i].try { |b| @selection << b.id unless @selection.includes?(b.id) }
        end
        cmd
      end

      private def select_command(rest : String) : Tea::Cmd?
        case rest.strip.downcase
        when "none" then (t = @trash) ? t.clear : clear_selection; nil
        when "all"  then (t = @trash) ? (t.select_all; nil) : select_all
        else             fail("select all wählt alle Treffer aus, select none hebt die Auswahl auf")
        end
      end

      # --- the errors of the last job -----------------------------------------

      def show_job_errors : Tea::Cmd?
        return fail("Keine Fehler beim letzten Job") unless @job_errors
        @showing_errors = true
        nil
      end

      private def job_errors_view : String
        e = @job_errors.not_nil!
        lines = [Theme.title.render("Fehler: #{e.label}"), ""] of String
        e.errors.each do |(id, error)|
          title = loaded_book(id).try { |b| " #{b.title}" } || ""
          Text.wrap("##{id}#{title}: #{error}", Math.max(20, @width - 6)).each_with_index do |l, i|
            lines << (i == 0 ? "  #{Theme.text.render(l)}" : "    #{Theme.muted.render(l)}")
          end
        end
        h = body_height
        if lines.size > h - 2
          rest = lines.size - (h - 3)
          lines = lines.first(h - 3) << Theme.muted.render("  … #{rest} Zeilen mehr")
        end
        lines << ""
        lines << Theme.muted.render("Taste drücken zum Schließen")
        acc = lines.first(h)
        acc += [""] * Math.max(0, h - acc.size)
        Lipgloss::Style.new.padding(0, 2).render(acc.join('\n'))
      end
    end
  end
end
