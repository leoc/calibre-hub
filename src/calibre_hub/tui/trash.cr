require "bubbletea"
require "json"

module CalibreHub
  module Tui
    # The trash arrived (or failed)
    class TrashMsg < Tea::Msg
      getter result : JSON::Any?
      getter error : String?

      def initialize(@result = nil, @error = nil)
      end
    end

    # calibre's trash (GET /api/trash), like the web app's /trash: newest
    # first, restored books get a new id. Selection and visual mode as in
    # the library; all entries are loaded at once.
    class TrashView
      getter entries = [] of JSON::Any
      getter? loaded = false
      getter cursor = 0
      getter offset = 0
      getter selection = [] of Int64
      getter visual : Visual? = nil

      def entries=(list : Array(JSON::Any)) : Nil
        @entries = list
        @loaded = true
        ids = list.compact_map { |e| TrashView.id(e) }
        @selection.select! { |i| ids.includes?(i) }
        @visual = nil
        @cursor = @cursor.clamp(0, Math.max(0, list.size - 1))
      end

      def self.id(e : JSON::Any) : Int64?
        e["id"]?.try(&.as_i64?)
      end

      def size : Int32
        @entries.size
      end

      def current : JSON::Any?
        @entries[@cursor]?
      end

      def move_to(index : Int32, height : Int32) : Nil
        @cursor = index.clamp(0, Math.max(0, size - 1))
        h = Math.max(1, height)
        @offset = @cursor - h + 1 if @cursor >= @offset + h
        @offset = @cursor if @cursor < @offset
        @offset = @offset.clamp(0, Math.max(0, size - h))
      end

      def visual_range : Range(Int32, Int32)?
        v = @visual || return nil
        Math.min(v.anchor, @cursor)..Math.max(v.anchor, @cursor)
      end

      def selected_ids : Array(Int64)
        v = @visual || return @selection
        ids = v.base.dup
        visual_range.not_nil!.each { |i| @entries[i]?.try { |e| TrashView.id(e) }.try { |id| ids << id unless ids.includes?(id) } }
        ids
      end

      def selected?(index : Int32) : Bool
        return true if visual_range.try(&.includes?(index))
        id = @entries[index]?.try { |e| TrashView.id(e) } || return false
        (@visual.try(&.base) || @selection).includes?(id)
      end

      def selecting? : Bool
        !@selection.empty? || !@visual.nil?
      end

      def toggle : Nil
        return end_visual if @visual
        id = current.try { |e| TrashView.id(e) } || return
        @selection.includes?(id) ? @selection.delete(id) : (@selection << id)
      end

      def toggle_visual : Nil
        return end_visual if @visual
        @visual = Visual.new(@cursor, @selection.dup) if current
      end

      def end_visual : Nil
        @selection = selected_ids
        @visual = nil
      end

      def select_all : Nil
        @visual = nil
        @selection = @entries.compact_map { |e| TrashView.id(e) }
      end

      def clear : Nil
        @selection.clear
        @visual = nil
      end

      # what r restores: the selection, else the cursor entry
      def target_ids : Array(Int64)
        ids = selected_ids
        return ids.dup unless ids.empty?
        current.try { |e| TrashView.id(e) }.try { |id| [id] } || [] of Int64
      end

      def title(id : Int64) : String?
        @entries.find { |e| TrashView.id(e) == id }.try(&.["title"]?).try(&.as_s?)
      end
    end

    class App
      getter trash : TrashView? = nil

      # gt: the trash (again: reloaded)
      def open_trash : Tea::Cmd?
        @detail = nil
        @visual = nil
        drop_waiting
        @trash ||= TrashView.new
        load_trash
      end

      def close_trash : Nil
        @trash = nil
      end

      private def load_trash : Tea::Cmd
        source = @source
        Tea.cmd do
          begin
            TrashMsg.new(source.trash).as(Tea::Msg)
          rescue ex
            TrashMsg.new(error: App.error_text(ex)).as(Tea::Msg)
          end
        end
      end

      private def trash_loaded(msg : TrashMsg) : Tea::Cmd?
        t = @trash || return nil
        if err = msg.error
          return fail("Papierkorb: #{err}")
        end
        t.entries = msg.result.try(&.as_a?) || [] of JSON::Any
        t.move_to(t.cursor, rows_height)
        nil
      end

      # r: the selection or the cursor entry back into the library; several ask
      def restore_selected : Tea::Cmd?
        t = @trash || return fail("Wiederherstellen geht im Papierkorb (gt)")
        ids = t.target_ids
        return fail("Nichts im Papierkorb") if ids.empty?
        label = ids.size == 1 ? "„#{t.title(ids[0]) || "##{ids[0]}"}“" : "#{ids.size} Bücher"
        run = -> {
          t.clear
          restore(ids, label, undoable: true)
        }
        return ask("#{label} wiederherstellen?") { run.call } if ids.size > 1
        run.call
      end

      def trash_to(index : Int32) : Tea::Cmd?
        @trash.try(&.move_to(index, rows_height))
        nil
      end

      private def trash_act(action : Action, count : Int32?, token : String) : Tea::Cmd?
        t = @trash.not_nil!
        n = count || 1
        h = rows_height
        case action
        when .down?          then t.move_to(t.cursor + n, h)
        when .up?            then t.move_to(t.cursor - n, h)
        when .first?         then t.move_to(count ? count - 1 : 0, h)
        when .last?          then t.move_to(count ? count - 1 : t.size - 1, h)
        when .half_down?     then t.move_to(t.cursor + n * Math.max(1, h // 2), h)
        when .half_up?       then t.move_to(t.cursor - n * Math.max(1, h // 2), h)
        when .next_page?     then t.move_to(t.cursor + n * h, h)
        when .prev_page?     then t.move_to(t.cursor - n * h, h)
        when .toggle_select? then t.toggle
        when .visual?        then t.toggle_visual
        when .select_all?    then t.select_all
        when .restore?       then return restore_selected
        when .go_trash?      then return load_trash
        when .commands?      then return open_commands
        when .undo?          then return undo
        when .back?, .left?
          if t.selecting?
            @message = "Auswahl aufgehoben"
            t.clear
          else
            close_trash
            return load_visible
          end
        when .go_library?
          close_trash
          return Tea.batch(navigate(Query.new), load_visible)
        else
          @message = "Im Papierkorb: r stellt wieder her, q geht zurück"
        end
        nil
      end

      # --- view -------------------------------------------------------------

      TRASH_COLUMNS = [
        Column.new("Titel", 40, 16),
        Column.new("Autor", 20, 10),
        Column.new("Formate", 10, 7),
        Column.new("Gelöscht", 16, 16),
      ]

      private def trash_view(width : Int32) : String
        t = @trash.not_nil!
        cols = TRASH_COLUMNS.dup
        while cols.size > 1 && cols.sum(&.min) + cols.size - 1 > width
          cols.pop
        end
        avail = width - (cols.size - 1)
        total = cols.sum(&.weight)
        widths = cols.map { |c| Math.max(c.min, avail * c.weight // total) }
        widths[0] = Math.max(1, widths[0] + avail - widths.sum)
        lines = [Theme.header.render(widths.map_with_index { |w, i| Text.fit(cols[i].title, w) }.join(" "))]
        h = rows_height
        if !t.loaded?
          lines << Theme.muted.render("Lädt …")
        elsif t.size == 0
          lines << Theme.muted.render("Der Papierkorb ist leer.")
        end
        t.move_to(t.cursor, h)
        (t.offset...Math.min(t.offset + h, t.size)).each do |i|
          e = t.entries[i]
          deleted = e["deletedAt"]?.try(&.as_s?).try { |d| d[0, 16].sub('T', ' ') } || ""
          cells = [e["title"]?.try(&.as_s?) || "",
                   (e["authors"]?.try(&.as_a?) || [] of JSON::Any).compact_map(&.as_s?).join(", "),
                   (e["formats"]?.try(&.as_a?) || [] of JSON::Any).compact_map(&.as_s?).join(", "),
                   deleted]
          marked = t.selected?(i)
          cells[0] = "● #{cells[0]}" if marked
          line = widths.map_with_index { |w, j| Text.fit(cells[j], w) }
          if i == t.cursor
            lines << Theme.cursor(true).bold.render(line.join(" "))
          else
            lines << line.map_with_index { |c, j| j == 0 ? (marked ? Theme.accent.bold.render(c) : Theme.text.render(c)) : Theme.muted.render(c) }.join(" ")
          end
        end
        lines.concat([""] * Math.max(0, h + 1 - lines.size))
        lines.first(h + 1).join('\n')
      end

      private def trash_status_right : String
        t = @trash.not_nil!
        sel = if t.visual
                "-- VISUELL -- #{t.selected_ids.size}"
              elsif !t.selection.empty?
                "#{t.selection.size} ausgewählt"
              else
                ""
              end
        pos = t.size > 0 ? "#{t.cursor + 1}/#{t.size}" : ""
        [@keys.pending, sel, pos].reject(&.empty?).join("  ")
      end
    end
  end
end
