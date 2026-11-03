require "bubbletea"
require "./actions"
require "./markdown"
require "./source"
require "./text"
require "./theme"

module CalibreHub
  module Tui
    # The edit form of one book (the web app's BookEdit): every field as a
    # text input, the description as a text area. Tab completes from the
    # hub's names, only changed fields are sent, with the lastModified read;
    # a 409 shows both versions to keep mine or take theirs.
    # A text input or (the description) a text area, one type for the form
    class FormInput
      def initialize(@line : Bubbles::TextInput? = nil, @area : Bubbles::TextArea? = nil)
      end

      def area? : Bool
        !@area.nil?
      end

      def value : String
        (l = @line) ? l.value : @area.not_nil!.value
      end

      def value=(text : String) : String
        if l = @line
          l.value = text
          l.cursor_end
        else
          @area.not_nil!.value = text
        end
        text
      end

      def update(msg : Tea::Msg) : Tea::Cmd?
        (l = @line) ? l.update(msg) : @area.not_nil!.update(msg)
      end

      def view : String
        (l = @line) ? l.view : @area.not_nil!.view
      end

      def focus : Tea::Cmd?
        if l = @line
          cmd = l.focus
          l.cursor_end
          return cmd
        end
        @area.not_nil!.focus
      end

      def blur : Nil
        (l = @line) ? l.blur : @area.not_nil!.blur
      end

      def resize(width : Int32, height : Int32) : Nil
        if l = @line
          l.configure(width: width)
        else
          @area.not_nil!.configure(width: width, height: height)
        end
      end

      # the cursor is on the first or last line (always, for an input)
      def first_line? : Bool
        (a = @area) ? a.line == 0 : true
      end

      def last_line? : Bool
        (a = @area) ? a.line >= a.line_count - 1 : true
      end
    end

    class EditForm
      record Field, key : String, label : String, suggest : ValueKind = ValueKind::None,
        sep : String? = nil, area : Bool = false, hint : String = ""

      FIELDS = [
        Field.new("title", "Titel"),
        Field.new("authors", "Autoren", ValueKind::Author, " & ", hint: "A & B"),
        Field.new("series", "Serie", ValueKind::Series),
        Field.new("seriesIndex", "Band", hint: "z. B. 2 oder 1.5"),
        Field.new("kategorie", "Kategorie", ValueKind::Kategorie, hint: "A/B"),
        Field.new("tags", "Tags", ValueKind::Tag, ", "),
        Field.new("languages", "Sprachen", ValueKind::Language, ", ", hint: "deu, eng"),
        Field.new("publisher", "Verlag"),
        Field.new("pubdate", "Erschienen", hint: "JJJJ-MM-TT"),
        Field.new("rating", "Bewertung", ValueKind::Rating, hint: "0-5 Sterne"),
        Field.new("identifiers", "Kennungen", sep: ", ", hint: "isbn:978…, asin:…"),
        Field.new("comments", "Beschreibung", area: true),
      ]

      LABEL_WIDTH = 13

      # the book's fields as the form shows them (the web app's toForm)
      def self.values(book : Book, column : String?) : Hash(String, String)
        {
          "title"       => book.title,
          "authors"     => book.authors.join(" & "),
          "series"      => book.series || "",
          "seriesIndex" => book.series_index.try { |i| Book.number(i) } || "",
          "kategorie"   => book.category(column).try { |c| Tui.category_label(c) } || "",
          "tags"        => book.tags.join(", "),
          "languages"   => book.languages.join(", "),
          "publisher"   => book.publisher || "",
          "pubdate"     => book.date("pubdate") || "",
          "rating"      => book.rating.try { |r| (r / 2).round.to_i.to_s } || "0",
          "identifiers" => book.identifiers.map { |k, v| "#{k}:#{v}" }.join(", "),
          "comments"    => Markdown.from_html(book.comments),
        }
      end

      # Only changed fields, with the lastModified read (the web app's
      # toPatch); nil when nothing changed. Raises Invalid for what the hub
      # would refuse.
      def self.patch(original : Hash(String, String), form : Hash(String, String),
                     last_modified : String?, column : String?) : Hash(String, JSON::Any)?
        p = {} of String => JSON::Any
        changed = ->(k : String) { form[k]? && form[k].strip != original[k]?.to_s.strip }
        list = ->(k : String, sep : String) { Changes.split(form[k], sep) }
        if changed.call("title")
          raise Invalid.new("Titel darf nicht leer sein") if form["title"].strip.empty?
          p["title"] = JSON::Any.new(form["title"].strip)
        end
        authors = list.call("authors", "&")
        if authors != Changes.split(original["authors"], "&")
          raise Invalid.new("Mindestens ein Autor") if authors.empty?
          p["authors"] = JSON.parse(authors.to_json)
        end
        p["series"] = JSON::Any.new(form["series"].strip.presence) if changed.call("series")
        if changed.call("seriesIndex") || (p["series"]?.try(&.as_s?) && original["series"].empty?)
          text = form["seriesIndex"].strip.sub(',', '.')
          unless text.empty?
            n = text.to_f? || raise Invalid.new("Band: eine Zahl wie 2 oder 1.5")
            raise Invalid.new("Band darf nicht negativ sein") if n < 0
            p["seriesIndex"] = JSON::Any.new(n)
          end
        end
        if column && changed.call("kategorie")
          k = Tui.parse_category(form["kategorie"])
          p["kategorie"] = JSON::Any.new(k) unless k == Tui.parse_category(original["kategorie"])
        end
        {"tags" => ",", "languages" => ","}.each do |k, sep|
          v = list.call(k, sep)
          p[k] = JSON.parse(v.to_json) unless v == Changes.split(original[k], sep)
        end
        p["publisher"] = JSON::Any.new(form["publisher"].strip.presence) if changed.call("publisher")
        if changed.call("pubdate")
          d = form["pubdate"].strip
          raise Invalid.new("Erschienen: JJJJ-MM-TT") unless d.empty? || d.matches?(/\A\d{4}-\d{2}-\d{2}\z/)
          p["pubdate"] = JSON::Any.new(d.presence)
        end
        if changed.call("rating")
          r = form["rating"].strip
          stars = r.empty? ? 0 : (r.to_i? || raise Invalid.new("Bewertung: 0 bis 5 Sterne"))
          raise Invalid.new("Bewertung: 0 bis 5 Sterne") unless 0 <= stars <= 5
          p["rating"] = stars == 0 ? JSON::Any.new(nil) : JSON::Any.new(stars.to_i64 * 2)
        end
        ids = identifiers(form["identifiers"])
        p["identifiers"] = JSON.parse(ids.to_json) unless ids == identifiers(original["identifiers"])
        if form["comments"].strip != original["comments"].strip
          p["comments"] = JSON::Any.new(form["comments"].strip.presence.try { |md| Markdown.to_html(md) })
        end
        return nil if p.empty?
        last_modified.try { |lm| p["lastModified"] = JSON::Any.new(lm) }
        p
      end

      # "isbn:978…, asin:B0…" -> {"isbn" => "978…", …}
      def self.identifiers(text : String) : Hash(String, String)
        h = {} of String => String
        Changes.split(text, ",").each do |pair|
          k, sep, v = pair.partition(':')
          raise Invalid.new("Kennungen: typ:wert, nicht „#{pair}“") if sep.empty? || k.strip.empty?
          h[k.strip.downcase] = v.strip unless v.strip.empty?
        end
        h
      end

      getter base : Book
      getter original : Hash(String, String)
      getter fields : Array(Field)
      getter focus = 0
      # the hub's version after a 409
      getter conflict : Book? = nil
      property error : String? = nil
      getter? saving = false
      getter candidates = [] of String
      getter chosen : Int32? = nil
      @cycle_start = 0
      @inputs : Array(FormInput)

      def initialize(@base : Book, @column : String?, width = 80, height = 24)
        @fields = FIELDS.reject { |f| f.key == "kategorie" && !@column }
        @original = EditForm.values(@base, @column)
        @inputs = @fields.map do |f|
          v = @original[f.key]
          if f.area
            FormInput.new(area: Bubbles::TextArea.new(value: v, width: input_width(width), height: area_height(height),
              show_line_numbers: false, placeholder: "Beschreibung (Markdown)"))
          else
            FormInput.new(line: Bubbles::TextInput.new(value: v, prompt: "", width: input_width(width), placeholder: f.hint,
              placeholder_style: Theme.muted))
          end
        end
      end

      def start : Tea::Cmd?
        focus_field(0)
      end

      def resize(width : Int32, height : Int32) : Nil
        @inputs.each(&.resize(input_width(width), area_height(height)))
      end

      private def input_width(width : Int32) : Int32
        Math.max(10, Math.min(width, 110) - LABEL_WIDTH - 6)
      end

      private def area_height(height : Int32) : Int32
        (height - FIELDS.size - 6).clamp(3, 12)
      end

      def values : Hash(String, String)
        @fields.each_with_index.to_h { |f, i| {f.key, @inputs[i].value} }
      end

      def value(key : String) : String
        i = @fields.index { |f| f.key == key } || return ""
        @inputs[i].value
      end

      def set(key : String, text : String) : Nil
        i = @fields.index { |f| f.key == key } || return
        @inputs[i].value = text
      end

      # the PATCH body; raises Invalid
      def patch : Hash(String, JSON::Any)?
        EditForm.patch(@original, values, @base.last_modified, @column)
      end

      def dirty? : Bool
        !patch.nil?
      rescue Invalid
        true
      end

      def saving=(on : Bool)
        @saving = on
      end

      def conflict=(book : Book?)
        @conflict = book
        @saving = false
      end

      # keep my changes on top of the hub's version (save again to write)
      def keep_mine : Nil
        current = @conflict || return
        @base = current
        @original = EditForm.values(current, @column)
        @conflict = nil
      end

      # the hub's version, my changes gone
      def take_theirs : Nil
        current = @conflict || return
        @base = current
        @original = EditForm.values(current, @column)
        @fields.each_with_index { |f, i| @inputs[i].value = @original[f.key] }
        @conflict = nil
      end

      # fields that differ between my form and the hub's version
      def conflict_rows : Array({String, String, String})
        current = @conflict || return [] of {String, String, String}
        theirs = EditForm.values(current, @column)
        mine = values
        @fields.compact_map do |f|
          next nil if mine[f.key].strip == theirs[f.key].strip
          {f.label, mine[f.key], theirs[f.key]}
        end
      end

      # :save, :cancel, :mine, :theirs or nil (still editing)
      def key(msg : Tea::KeyMsg, choices : Choices) : {Symbol?, Tea::Cmd?}
        if @conflict
          case msg.key
          when "m"      then return {:mine, nil}
          when "t"      then return {:theirs, nil}
          when "esc"    then return {:cancel, nil}
          when "ctrl+c" then return {:cancel, nil}
          end
          return {nil, nil}
        end
        @error = nil
        field = @fields[@focus]
        input = @inputs[@focus]
        case msg.key
        when "ctrl+s"
          return {:save, nil}
        when "esc"
          return {:cancel, nil}
        when "tab"
          return {nil, complete(choices, 1) ? nil : focus_field(@focus + 1)}
        when "shift+tab"
          return {nil, cycling? ? (complete(choices, -1); nil) : focus_field(@focus - 1)}
        when "enter"
          return {nil, focus_field(@focus + 1)} unless field.area
        when "up"
          if input.first_line?
            return {nil, focus_field(@focus - 1)}
          end
        when "down"
          if input.last_line?
            return {nil, focus_field(@focus + 1)}
          end
        end
        reset_completion
        {nil, input.update(msg)}
      end

      # other messages (cursor blink) for the focused input
      def update_focused(msg : Tea::Msg) : Tea::Cmd?
        @inputs[@focus].update(msg)
      end

      def focus_field(index : Int32) : Tea::Cmd?
        reset_completion
        @inputs[@focus].blur
        @focus = index.clamp(0, @fields.size - 1)
        @inputs[@focus].focus
      end

      private def cycling? : Bool
        !@candidates.empty? && !@chosen.nil?
      end

      # the item being typed in the focused field: {start, text}
      private def current_item : {Int32, String}
        f = @fields[@focus]
        text = @inputs[@focus].value
        start = f.sep ? Completion.item_start(text, f.sep.not_nil!) : 0
        {start, text[start..]}
      end

      # suggestions for the focused field
      def suggestions(choices : Choices, limit = 8) : Array(String)
        f = @fields[@focus]
        return [] of String if f.suggest.none?
        _, typed = current_item
        found = Completion.matches(choices.for(f.suggest), typed, limit + 1)
        # nothing to offer when the value is already one of them
        found.size == 1 && found[0] == typed ? [] of String : found.first(limit)
      end

      # Tab: insert the common part, then cycle; false when there is nothing
      # to complete (Tab moves on)
      private def complete(choices : Choices, step : Int32) : Bool
        input = @inputs[@focus]
        if cycling?
          @chosen = (@chosen.not_nil! + step) % @candidates.size
          input.value = input.value[0, @cycle_start] + @candidates[@chosen.not_nil!]
          return true
        end
        f = @fields[@focus]
        return false if f.suggest.none? || f.area
        start, typed = current_item
        return false if typed.strip.empty?
        found = Completion.matches(choices.for(f.suggest), typed)
        return false if found.empty? || (found.size == 1 && found[0] == typed)
        text = input.value
        if found.size == 1
          input.value = text[0, start] + found[0]
          reset_completion
          return true
        end
        @candidates = found
        @cycle_start = start
        prefix = Completion.common_prefix(found)
        if prefix.size > typed.size
          input.value = text[0, start] + prefix
          @chosen = nil
        else
          @chosen = 0
          input.value = text[0, start] + found[0]
        end
        true
      end

      private def reset_completion : Nil
        @candidates = [] of String
        @chosen = nil
      end

      # --- view -------------------------------------------------------------

      def view(width : Int32, height : Int32, choices : Choices) : String
        return conflict_view(width, height) if @conflict
        lines = [] of String
        focus_line = 0
        lines << Theme.title.render(Text.truncate("Bearbeiten: #{@base.title}", width - 2))
        lines << ""
        sugg_w = Math.max(10, Math.min(width, 110) - LABEL_WIDTH - 6)
        @fields.each_with_index do |f, i|
          label = Text.fit(f.label, LABEL_WIDTH)
          label_s = i == @focus ? Theme.accent.bold.render(label) : Theme.muted.render(label)
          focus_line = lines.size if i == @focus
          view = @inputs[i].view
          if f.area
            lines << label_s
            view.split('\n').each { |l| lines << " " * LABEL_WIDTH + l }
          else
            lines << label_s + view
          end
          next unless i == @focus
          if @candidates.size > 1
            lines << " " * LABEL_WIDTH + wildmenu(sugg_w)
          elsif !(s = suggestions(choices)).empty?
            lines << " " * LABEL_WIDTH + Theme.muted.render(Text.truncate("Tab: " + s.join(" · "), sugg_w))
          end
        end
        if e = @error
          lines << ""
          lines << Theme.error.render(Text.truncate(e, width - 2))
        end
        # keep the focused field on screen
        top = Math.max(0, Math.min(focus_line - 2, lines.size - height))
        top = 0 if lines.size <= height
        shown = lines[top, height]? || [] of String
        shown += [""] * Math.max(0, height - shown.size)
        Lipgloss::Style.new.padding(0, 2).render(shown.join('\n'))
      end

      private def wildmenu(width : Int32) : String
        used = 0
        acc = ""
        @candidates.each_with_index do |c, i|
          w = Text.width(c) + 2
          break if used + w > width
          acc += i == @chosen ? Theme.cursor(true).bold.render(" #{c} ") : Theme.muted.render(" #{c} ")
          used += w
        end
        acc
      end

      private def conflict_view(width : Int32, height : Int32) : String
        lines = [Theme.error.render("Das Buch wurde inzwischen geändert, nichts gespeichert."), ""] of String
        col = Math.max(8, (Math.min(width, 110) - LABEL_WIDTH - 8) // 2)
        lines << Theme.header.render(Text.fit("Feld", LABEL_WIDTH) + Text.fit("Deins", col) + "  " + Text.fit("Jetzt", col))
        conflict_rows.each do |(label, mine, theirs)|
          lines << Theme.muted.render(Text.fit(label, LABEL_WIDTH)) + Theme.text.render(Text.fit(mine, col)) + "  " +
                   Theme.accent.render(Text.fit(theirs, col))
        end
        lines << ""
        lines << Theme.text.render("m: meine Änderungen auf die neue Fassung (dann Strg+S)  ·  t: neue Fassung übernehmen  ·  Esc: abbrechen")
        shown = lines.first(height)
        shown += [""] * Math.max(0, height - shown.size)
        Lipgloss::Style.new.padding(0, 2).render(shown.join('\n'))
      end
    end
  end
end
