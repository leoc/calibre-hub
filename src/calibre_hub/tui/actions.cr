require "json"
require "./source"
require "./query"

module CalibreHub
  module Tui
    # Runs over more books than this ask first (deleting always asks), as in
    # the web app
    CONFIRM_ABOVE = 50

    # What a command takes (the web app's ValueKind, plus what only the
    # command line has)
    enum ValueKind
      None
      Tag
      BookTag
      Kategorie
      Series
      Author
      Publisher
      Language
      Rating
      Year
      List
      BookList
      Name
      Format
      Sort
      Text
    end

    # A command on books. `id` is the web app's action id
    # (frontend/src/lib/book-actions.ts), and so are the semantics: one book
    # is changed right away (PATCH), several as a bulk job.
    record BookAction, id : String, label : String, value : ValueKind,
      allow_new : Bool = false, clearable : Bool = false, confirm : Bool = false,
      many : Bool = false, multi : Bool = false

    BOOK_ACTIONS = [
      BookAction.new("addTags", "Tags hinzufügen", ValueKind::Tag, allow_new: true, multi: true),
      BookAction.new("removeTags", "Tags entfernen", ValueKind::BookTag, multi: true),
      BookAction.new("kategorie", "Kategorie setzen", ValueKind::Kategorie, allow_new: true, clearable: true),
      BookAction.new("series", "Serie setzen", ValueKind::Series, allow_new: true, clearable: true),
      # volumes 1..n in the order the books were selected
      BookAction.new("seriesNumbered", "Serie nummerieren", ValueKind::Series, allow_new: true, many: true),
      BookAction.new("authors", "Autoren setzen", ValueKind::Author, allow_new: true, multi: true),
      BookAction.new("publisher", "Verlag setzen", ValueKind::Publisher, clearable: true),
      BookAction.new("language", "Sprache setzen", ValueKind::Language, multi: true),
      BookAction.new("rating", "Bewertung setzen", ValueKind::Rating),
      BookAction.new("year", "Erscheinungsjahr setzen", ValueKind::Year, clearable: true),
      BookAction.new("addToList", "Zu Liste hinzufügen", ValueKind::List, allow_new: true),
      BookAction.new("removeFromList", "Aus Liste entfernen", ValueKind::BookList),
      BookAction.new("newList", "Neue Liste", ValueKind::Name),
      BookAction.new("download", "Herunterladen", ValueKind::Format),
      BookAction.new("delete", "In den Papierkorb", ValueKind::None, confirm: true),
    ]

    def self.book_action(id : String) : BookAction?
      BOOK_ACTIONS.find { |a| a.id == id }
    end

    # The command line (`:`): what is typed, the CLI's words where the CLI
    # has the command (`tag add`, `list rm`), else German like the web
    # palette's keywords. The web action ids work as well (`:addTags x`).
    module Commands
      # {typed words, action or app command, what it does}
      NAMES = [
        {"tag add", "addTags", "Tags hinzufügen (mit Komma: mehrere)"},
        {"tag rm", "removeTags", "Tags entfernen"},
        {"kategorie", "kategorie", "Kategorie setzen (A/B, - leert)"},
        {"serie", "series", "Serie setzen (- leert)"},
        {"nummerieren", "seriesNumbered", "Serie setzen, Bände 1..n in Auswahlreihenfolge"},
        {"autor", "authors", "Autoren setzen (A & B)"},
        {"verlag", "publisher", "Verlag setzen (- leert)"},
        {"sprache", "language", "Sprachen setzen (deu, eng)"},
        {"bewertung", "rating", "Bewertung 0-5 Sterne"},
        {"jahr", "year", "Erscheinungsjahr (- leert)"},
        {"list add", "addToList", "zu einer Liste hinzufügen"},
        {"list rm", "removeFromList", "aus einer Liste entfernen"},
        {"list new", "newList", "neue Liste mit den Büchern"},
        {"trash", "delete", "in den Papierkorb (fragt)"},
        {"download", "download", "Datei ins aktuelle Verzeichnis (Format optional)"},
        {"edit", "edit", "Formular für das Buch"},
        {"open", "open", "Buch öffnen"},
        {"search", "search", "suchen (calibre-Suche)"},
        {"sort", "sort", "Sortierung: sort added desc"},
        {"undo", "undo", "letzte Änderung zurücknehmen"},
        {"select", "select", "select none: Auswahl aufheben"},
        {"help", "help", "Tastenkürzel und Befehle"},
        {"quit", "quit", "beenden"},
      ]

      ALIASES = {
        "q" => "quit", "kat" => "kategorie", "series" => "series", "authors" => "authors",
        "publisher" => "publisher", "language" => "language", "rating" => "rating", "year" => "year",
        "delete" => "delete", "s" => "search", "e" => "edit", "u" => "undo",
        "addTags" => "addTags", "removeTags" => "removeTags", "seriesNumbered" => "seriesNumbered",
        "addToList" => "addToList", "removeFromList" => "removeFromList", "newList" => "newList",
      }

      APP = %w(edit open search sort undo select help quit)

      # {action, the rest as typed}; a number alone is {"line", n}
      def self.parse(line : String) : {String, String}?
        text = line.strip.lchop(':').strip
        return nil if text.empty?
        return {"line", text} if text.matches?(/\A\d+\z/)
        action, n = parse_words(text) || return nil
        {action, rest(text, n)}
      end

      # the action and how many words name it
      def self.parse_words(text : String) : {String, Int32}?
        words = text.strip.split(/\s+/)
        return nil if words.empty? || words[0].empty?
        best = nil
        NAMES.each do |(typed, action, _)|
          w = typed.split(' ')
          # a subcommand needs its word ("tag" alone is no command)
          next unless words.size >= w.size && words[0, w.size].map(&.downcase) == w
          best = {action, w.size} if best.nil? || w.size > best[1]
        end
        return best if best
        a = ALIASES.find { |k, _| k.downcase == words[0].downcase }.try(&.[1]) || return nil
        {a, 1}
      end

      # the text after the first n words, as typed
      def self.rest(text : String, n : Int32) : String
        m = text.match(/\A\s*(?:\S+\s+){#{n}}/) || return ""
        text[m[0].size..].strip
      end

      def self.value_kind(action : String) : ValueKind
        return ValueKind::Sort if action == "sort"
        return ValueKind::Text if action == "search"
        Tui.book_action(action).try(&.value) || ValueKind::None
      end
    end

    # What completion offers: names from the hub and the target book
    class Choices
      property tags = [] of String
      property series = [] of String
      property authors = [] of String
      property languages = [] of String
      # paths, "A/B"
      property kategorien = [] of String
      # lists books can be put on (own, no magic shelves), by path
      property lists = [] of String
      # the target book's own tags, lists and formats (removing)
      property book_tags : Array(String)? = nil
      property book_lists : Array(String)? = nil
      property formats = [] of String

      def initialize
      end

      def for(kind : ValueKind) : Array(String)
        case kind
        when .tag?       then @tags
        when .book_tag?  then @book_tags || @tags
        when .kategorie? then @kategorien
        when .series?    then @series
        when .author?    then @authors
        when .language?  then @languages
        when .rating?    then %w(0 1 2 3 4 5)
        when .list?      then @lists
        when .book_list? then @book_lists || @lists
        when .format?    then @formats
        when .sort?      then SORTS
        else                  [] of String
        end
      end
    end

    module Completion
      # Items matching the typed text: starting with it first, then
      # containing it; case is ignored
      def self.matches(items : Array(String), text : String, limit = 50) : Array(String)
        t = text.strip.downcase
        return items.first(limit) if t.empty?
        starts = items.select(&.downcase.starts_with?(t))
        contains = items.select { |i| !i.downcase.starts_with?(t) && i.downcase.includes?(t) }
        (starts + contains).uniq.first(limit)
      end

      # Where the item being typed starts in a list value ("a, b, c" -> the
      # c): after the last separator and its spaces
      def self.item_start(text : String, separator : String) : Int32
        i = text.rindex(separator.strip) || return text.size - text.lstrip.size
        j = i + separator.strip.size
        while j < text.size && text[j] == ' '
          j += 1
        end
        j
      end

      def self.common_prefix(items : Array(String)) : String
        first = items.first? || return ""
        size = first.size
        items.each do |i|
          size = Math.min(size, i.size)
          while size > 0 && i[0, size].downcase != first[0, size].downcase
            size -= 1
          end
        end
        first[0, size]
      end

      # Completions of a command line: {where the completed part starts,
      # candidates for it, whether it is a command word (a space follows)}
      def self.command_line(line : String, choices : Choices) : {Int32, Array(String), Bool}
        unless line.includes?(' ')
          firsts = Commands::NAMES.map(&.[0].split(' ').first).uniq
          return {0, matches(firsts, line), true}
        end
        first, _, after = line.partition(' ')
        if {"tag", "list"}.includes?(first.downcase) && !after.lstrip.includes?(' ')
          subs = Commands::NAMES.compact_map { |(t, _, _)| t.split(' ').try { |w| w[0] == first.downcase && w.size > 1 ? w[1] : nil } }
          return {line.size - after.lstrip.size, matches(subs, after.lstrip), true}
        end
        if first.downcase == "select"
          return {line.size - after.lstrip.size, matches(%w(none), after.lstrip), false}
        end
        action, words = Commands.parse_words(line) || return {line.size, [] of String, false}
        start = line.match(/\A\s*(?:\S+\s+){#{words}}/).try(&.[0].size) || line.size
        value = line[start..]
        kind = Commands.value_kind(action)
        if kind.sort?
          parts = value.split(' ')
          return {start, matches(SORTS, value), true} if parts.size <= 1
          return {line.size - parts.last.size, matches(%w(asc desc), parts.last), false}
        end
        sep = kind.author? ? " & " : (Tui.book_action(action).try(&.multi) ? "," : nil)
        if sep
          offset = item_start(value, sep)
          return {start + offset, matches(choices.for(kind), value[offset..]), false}
        end
        {start, matches(choices.for(kind), value), false}
      end
    end

    # A category typed as a path, like the web app's parseCategory: "A/B"
    # or "A.B" is stored as "A.B"; with "/" a part must not contain dots
    def self.parse_category(text : String) : String?
      t = text.strip
      sep = t.matches?(/[\/›]/) ? /[\/›]/ : /\./
      parts = t.split(sep).map(&.strip).reject(&.empty?)
      if dotted = parts.find(&.includes?('.'))
        raise Invalid.new("„#{dotted}“: Punkte trennen Ebenen, als Pfad A/B schreiben")
      end
      parts.empty? ? nil : parts.join('.')
    end

    class Invalid < Exception
    end

    module Changes
      CLEAR = "-"

      def self.split(text : String, sep = ",") : Array(String)
        text.split(sep).map(&.strip).reject(&.empty?).uniq
      end

      # The field changes of an action with its typed value, as the bulk
      # API takes them (the web app's `changes`)
      def self.for(action : BookAction, text : String) : Hash(String, JSON::Any)
        v = text.strip
        clear = action.clearable && (v.empty? || v == CLEAR)
        need = -> { raise Invalid.new("#{action.label}: Wert fehlt") if v.empty? }
        h = {} of String => JSON::Any
        case action.id
        when "addTags", "removeTags"
          need.call
          h[action.id] = json(split(v))
        when "kategorie"
          h["kategorie"] = JSON::Any.new(clear ? nil : Tui.parse_category(v))
        when "series"
          h["series"] = JSON::Any.new(clear ? nil : v)
        when "seriesNumbered"
          need.call
          h["series"] = JSON::Any.new(v)
          h["numberSeries"] = JSON::Any.new(true)
        when "authors"
          need.call
          h["authors"] = json(split(v, "&"))
        when "publisher"
          h["publisher"] = JSON::Any.new(clear ? nil : v)
        when "language"
          need.call
          h["languages"] = json(split(v).map(&.downcase))
        when "rating"
          stars = v.empty? ? 0 : (v.to_i? || raise Invalid.new("Bewertung: 0 bis 5 Sterne"))
          raise Invalid.new("Bewertung: 0 bis 5 Sterne") unless 0 <= stars <= 5
          h["rating"] = stars == 0 ? JSON::Any.new(nil) : JSON::Any.new(stars.to_i64 * 2)
        when "year"
          if clear
            h["pubYear"] = JSON::Any.new(nil)
          else
            y = v.to_i? if v.matches?(/\A\d{1,4}\z/)
            raise Invalid.new("Jahr: eine Zahl wie 1999") unless y && y > 0
            h["pubYear"] = JSON::Any.new(y.to_i64)
          end
        end
        h
      end

      # The same change for one book as a PATCH body (the year keeps month
      # and day, like the bulk API's pubYear)
      def self.patch(changes : Hash(String, JSON::Any), book : Book) : Hash(String, JSON::Any)
        body = changes.dup
        if y = body.delete("pubYear")
          body["pubdate"] = if year = y.as_i64?
                              rest = book.date("pubdate").try(&.[4..]) || "-01-01"
                              JSON::Any.new("#{year.to_s.rjust(4, '0')}#{rest}")
                            else
                              JSON::Any.new(nil)
                            end
        end
        body.delete("numberSeries")
        body
      end

      # The book as it will look after a PATCH (optimistic update); fields
      # the TUI doesn't show stay
      def self.apply(book : Book, body : Hash(String, JSON::Any), column : String?) : Book
        fields = {} of String => JSON::Any
        b = book
        body.each do |k, v|
          case k
          when "addTags", "removeTags"
            tags = fields["tags"]?.try(&.as_a.map(&.as_s)) || book.tags
            list = v.as_a.map(&.as_s)
            if k == "addTags"
              list.each { |t| tags << t unless tags.any? { |x| x.downcase == t.downcase } }
            else
              tags = tags.reject { |t| list.any? { |x| x.downcase == t.downcase } }
            end
            fields["tags"] = json(tags)
          when "kategorie"
            b = b.with_category(column, v.as_s?) if column
          when "lastModified"
          else
            fields[k] = v
          end
        end
        b.merge(fields)
      end

      # The PATCH that puts back what `body` changes on `book`
      def self.undo(body : Hash(String, JSON::Any), book : Book, column : String?) : Hash(String, JSON::Any)
        u = {} of String => JSON::Any
        body.each_key do |k|
          case k
          when "addTags", "removeTags", "tags" then u["tags"] = json(book.tags)
          when "kategorie"                     then u["kategorie"] = JSON::Any.new(book.category(column))
          when "series"
            u["series"] = JSON::Any.new(book.series)
            book.series_index.try { |i| u["seriesIndex"] = JSON::Any.new(i) }
          when "seriesIndex" then book.series_index.try { |i| u["seriesIndex"] = JSON::Any.new(i) }
          when "rating"      then u["rating"] = (r = book.rating) && r > 0 ? JSON::Any.new(r.round.to_i64) : JSON::Any.new(nil)
          when "pubdate"     then u["pubdate"] = JSON::Any.new(book.date("pubdate"))
          when "lastModified"
          else
            book.json[k]?.try { |v| u[k] = v }
          end
        end
        u
      end

      private def self.json(value) : JSON::Any
        JSON.parse(value.to_json)
      end
    end
  end
end
