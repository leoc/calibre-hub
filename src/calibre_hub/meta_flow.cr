require "json"
require "./book"
require "./meta_confidence"
require "./meta_filename"
require "./meta_sources"

module CalibreHub
  module Meta
    # What a book is called, decided from the book first, the file name last.
    # One flow for the import and the repair:
    #
    # 1. An ISBN in the book (first and last pages, by OCR when there is no
    #    text layer) whose catalog record fits the book's text (Fit) wins
    #    over everything, also the file name.
    # 2. Else the metadata in the file: EPUB, an OPF, calibre's are trusted,
    #    the others (a PDF, a DjVu, MOBI, CHM) only field by field when they
    #    fit the text or the name.
    # 3. Else the file name (FileName.decide).
    #
    # What's still missing comes from the catalogs when two of them agree.
    # Every decision has a confidence (Confidence), which decides what may
    # be written: below REVIEW no title or author changes, the book gets
    # Meta.unsure_tag and what is known as a suggestion. A field edited by
    # hand never changes. An ISBN is never replaced: a different one in the
    # book, or the same one on another book, is a Note for the review.
    module Flow
      LEVEL_ISBN = 1
      LEVEL_META = 2
      LEVEL_NAME = 3

      # ISBNs of a book asked at the catalogs at most
      MAX_ISBNS = 4
      # text of a book long enough to contradict a name
      MIN_WORDS = 100
      # what the book's own ISBN came from
      SOURCE_TEXT    = "text"
      SOURCE_OCR     = "ocr"
      SOURCE_OPF     = "opf"
      SOURCE_CALIBRE = "calibre"

      # kind: duplicateIsbn (the ISBN is on other books too), isbnConflict
      # (the book has another ISBN than the one in its pages)
      record Note, kind : String, isbn : String, books : Array(Int64) = [] of Int64 do
        include JSON::Serializable
      end

      # changes: for the review or to write. how: who decided, as the
      # proposals show it. source: the level's source (a catalog, file,
      # calibre, rules). title, authors: their confidence. isbn: the book's
      # ISBN after this, isbn_source: where it comes from.
      record Decision, changes : Array(Change), how : String, level : Int32, source : String,
        title : Int32, authors : Int32, isbn : String? = nil, isbn_source : String? = nil,
        notes : Array(Note) = [] of Note do
        def confidence : Int32
          value = Confidence.book(title, authors)
          notes.empty? ? value : {value, Confidence::CONFLICT}.min
        end

        def band : String
          Confidence.band(confidence)
        end
      end

      alias Lookup = Proc(String, Array(Candidate))
      alias Owners = Proc(String, Array(Int64))

      class Input
        getter book : Book
        # the field's value at the import, nil when someone changed it
        # (FileName.decide)
        getter imported : Proc(String, JSON::Any?)
        # the name of the file the book came from, nil: an upload, the inbox,
        # a calibre folder
        property name : String?
        property hint : Symbol?
        property info : FileMeta::Info?
        # asks the catalogs for an ISBN (Metadata#isbn_lookup)
        property by_isbn : Lookup?
        property decider : FileName::Decider?
        property checker : FileName::Checker?
        # the books that have this ISBN (the book itself may be among them)
        property owners : Owners?
        # fields edited by hand
        property hand : Set(String) = Set(String).new

        def initialize(@book, @imported, @name = nil, @hint = nil, @info = nil)
        end
      end

      def self.decide(input : Input) : Decision?
        book = input.book
        info = input.info
        return nil if Norms.parse(book, info.try(&.cover))
        words = info.try(&.words)
        reading = reading(input)
        decision = by_isbn(input, words, reading) || by_metadata(input, words, reading) || by_name(input, words, reading)
        decision.try { |d| finish(input, d) }
      end

      # the file name's reading, nil when it has none or says nothing
      private def self.reading(input : Input) : Guess?
        name = input.name || return nil
        g = FileName.parse(name, input.hint) || return nil
        FileName.bad_title?(g.title) ? nil : g
      end

      # An ISBN's level: {isbn, how it came, strict}
      private def self.isbns(input : Input) : Array({String, String, Bool})
        info = input.info || return [] of {String, String, Bool}
        text = info.ocr ? SOURCE_OCR : SOURCE_TEXT
        own = own_isbn(input.book)
        found = info.found
        # the book's own first when its pages have it
        found = found.sort_by { |f| f.isbn == own ? 0 : 1 } if own
        list = found.reject(&.strict).map { |f| {f.isbn, text, false} }
        info.record.isbn.try { |i| Isbn.normalize(i).try { |n| list << {n, SOURCE_OPF, false} } }
        own.try { |i| list << {i, SOURCE_CALIBRE, false} }
        list += found.select(&.strict).map { |f| {f.isbn, text, true} }
        list.uniq(&.[0]).first(MAX_ISBNS)
      end

      private def self.own_isbn(book : Book) : String?
        book.identifiers["isbn"]?.try { |i| Isbn.normalize(i) }
      end

      private def self.by_isbn(input : Input, words : Words?, reading : Guess?) : Decision?
        lookup = input.by_isbn || return nil
        return nil unless words
        isbns(input).each do |isbn, source, strict|
          fits = lookup.call(isbn).compact_map do |c|
            fit = Fit.check(c.fields, words)
            next if strict ? !c.fields.title.try { |t| Fit.title?(t, words, strict: true) } : !fit.any?
            {c, fit}
          end
          next if fits.empty?
          c, fit = fits.sort_by { |x, f| {f.both? ? 0 : 1, f.title ? 0 : 1, Merge::PRECEDENCE["authors"].index(x.source) || 9} }.first
          return level_isbn(input, c, fit, isbn, source, reading)
        end
        nil
      end

      private def self.level_isbn(input : Input, c : Candidate, fit : Fit::Result, isbn : String, isbn_source : String, reading : Guess?) : Decision
        book = input.book
        changes = [] of Change
        title_value = catalog_title(c.fields)
        own = own_title(book, reading)
        # a translation: the catalog's title isn't this book's. Catalogs
        # write titles like sentences, the book's form of the same title stays
        same = own && Text.key(Text.main_title(own)) == Text.key(Text.main_title(title_value))
        title = (fit.title && !same ? title_value : own) || title_value
        unless keep_title?(book, title)
          changes << Change.new("title", JSON::Any.new(book.title), JSON::Any.new(title), c.source)
        end
        people = own_people(c.fields, input.info.try(&.words), reading)
        unless people.empty? || keep_authors?(book, people)
          changes.concat(author_changes(book, people, c.source))
        end
        t = fit.title ? Confidence::ISBN_BOTH : Confidence::ISBN_ONE
        a = fit.authors ? Confidence::ISBN_BOTH : Confidence::ISBN_ONE
        if reading && !reading.authors.empty? && !people.empty? && !FileName.same_book?(reading.title, title) &&
           Score.authors(reading.authors, people) < 0.5
          t -= Confidence::ISBN_AGAINST_NAME
          a -= Confidence::ISBN_AGAINST_NAME
        end
        notes = [] of Note
        have = own_isbn(book)
        if have && have != isbn
          notes << Note.new("isbnConflict", isbn)
          isbn, isbn_source = have, SOURCE_CALIBRE
        elsif have.nil?
          others = (input.owners.try(&.call(isbn)) || [] of Int64) - [book.id]
          if others.empty?
            changes << Change.new("isbn", JSON::Any.new(book.identifiers["isbn"]?), JSON::Any.new(isbn), c.source)
          else
            notes << Note.new("duplicateIsbn", isbn, others)
          end
        end
        changes.concat(name_extras(input))
        Decision.new(changes, c.source, LEVEL_ISBN, c.source, t, a, isbn, isbn_source, notes)
      end

      # The record's persons: those in the book's text when any is ("Cambridge
      # India" isn't), the one the name knows first
      private def self.own_people(r : Record, words : Words?, reading : Guess?) : Array(String)
        people = CrossCheck.people(r)
        here = words ? people.select { |a| words.person?(a) } : people
        people = here unless here.empty?
        return people unless reading
        people.each_with_index.to_a.sort_by { |a, i| {Score.authors([a], reading.authors) >= 0.8 ? 0 : 1, i} }.map(&.[0])
      end

      # The record's title with its subtitle
      private def self.catalog_title(r : Record) : String
        t = Text.main_title(r.title || "").strip
        sub = r.subtitle.try(&.strip)
        sub && Merge.subtitle?(sub, t) ? "#{t}: #{sub}" : t
      end

      # what the book itself says it is called, besides a catalog: its name,
      # else a title that says something
      private def self.own_title(book : Book, reading : Guess?) : String?
        reading.try(&.title) || (book.title unless FileName.leftover_title?(book.title))
      end

      # the same book under a title that is in order stays
      private def self.keep_title?(book : Book, title : String) : Bool
        return true if FileName.same_text?(book.title, title)
        return false if FileName.leftover_title?(book)
        FileName.same_book?(book.title, title)
      end

      # the same people stay: "Carr" gets the catalog's name in full, "Donald
      # Knuth" isn't "Donald E. Knuth" enough for a change
      private def self.keep_authors?(book : Book, theirs : Array(String)) : Bool
        return false if FileName.weak_authors?(book) || book.authors.size != theirs.size
        book.authors.all? do |m|
          words = Text.tokens(m)
          words.size >= 2 && theirs.any? { |o| Text.tokens(o).last? == words.last }
        end
      end

      private def self.author_changes(book : Book, authors : Array(String), source : String) : Array(Change)
        list = [Change.new("authors", JSON.parse(book.authors.to_json), JSON.parse(authors.to_json), source)]
        sort = AuthorSort.for(authors)
        list << Change.new("authorSort", JSON::Any.new(book.author_sort), JSON::Any.new(sort), source) unless book.author_sort == sort
        list
      end

      # publisher, year and series of the name fill what a book misses at
      # every level
      private def self.name_extras(input : Input) : Array(Change)
        name = input.name || return [] of Change
        d = FileName.decide(input.book, name, input.hint, input.imported) || return [] of Change
        d[0].reject { |c| FileName::NAME_FIELDS.includes?(c.field) || c.field.in?("tags", FileName::CANDIDATE) }
      end

      # the file's title as a title: no junk, no list code in front
      private def self.meta_title(title : String?) : String?
        t = title.try { |x| x.gsub(/[\s\x{A0}]+/, " ").strip.sub(FileName::CODE_PREFIX, "") }.presence || return nil
        return nil if FileName.leftover_title?(t.sub(/\s*\(\d.*\z/, "")) || Clean.junk?(t) || Clean.broken_case?(t)
        FileName.clean_title(t).presence
      end

      # The metadata of the file, field by field, or calibre's for a book
      # without a file name that has what a book should have
      private def self.by_metadata(input : Input, words : Words?, reading : Guess?) : Decision?
        book = input.book
        record = input.info.try(&.record)
        title = meta_title(record.try(&.title))
        authors = Clean.authors((record.try(&.authors) || [] of String).map { |a| FileName.clean_author(a) }).reject { |a| FileName.bad_author?(a) }
        trusted = input.info.try(&.format) == "EPUB"
        unless trusted
          title = nil unless title && fits?(title, words, input.name)
          authors = authors.select { |a| person_fits?(a, words, input.name) }
        end
        if title.nil?
          return nil if input.name || FileName.leftover_title?(book) || FileName.weak_authors?(book)
          return Decision.new([] of Change, "calibre", LEVEL_META, "calibre", Confidence::META_NOTHING, Confidence::META_NOTHING,
            own_isbn(book), own_isbn(book) ? SOURCE_CALIBRE : nil)
        end
        level_meta(input, title, authors, words, reading)
      end

      private def self.fits?(title : String, words : Words?, name : String?) : Bool
        return true if words.try { |w| Fit.title?(title, w) }
        name ? Fit.title?(title, Words.new(name)) : false
      end

      private def self.person_fits?(author : String, words : Words?, name : String?) : Bool
        return true if words.try(&.person?(author))
        return false unless name
        list = Words.new(name)
        list.person?(author) || Text.tokens(author).last?.try { |w| list.has?(w) } || false
      end

      private def self.level_meta(input : Input, title : String, authors : Array(String), words : Words?, reading : Guess?) : Decision?
        book = input.book
        # a book without a file name: its own title and authors say what a
        # name would say
        said = reading || (Guess.new(book.title, book.authors) unless input.name || FileName.leftover_title?(book))
        title_fits = said.try { |r| FileName.same_book?(r.title, title) }
        t = case title_fits
            when true  then Confidence::META_NAME
            when false then Confidence::META_NAME - Confidence::META_AGAINST_NAME
            else            Confidence::META_NOTHING
            end
        changes = [] of Change
        unless keep_title?(book, title)
          changes << Change.new("title", JSON::Any.new(book.title), JSON::Any.new(title), "file")
        end
        how, source = "file", "file"
        a = 0
        if authors.empty?
          # no author in the file: the name's, what the book has, the catalogs
          if reading && title_fits && !reading.authors.empty?
            authors = reading.authors
            a = name_value(authors)
          elsif !FileName.weak_authors?(book)
            authors = book.authors
            a = Confidence::KEPT
          elsif verdict = input.checker.try(&.call(book, Guess.new(title, [] of String)))
            if verdict.confirmed && verdict.sources.size >= 2
              authors = verdict.authors
              a = Confidence::CATALOGS
              how = source = verdict.source
            else
              changes << suggestion(verdict.title || title, verdict.authors, verdict.source)
              a = Confidence::CATALOG
              how = FileName::UNSURE
            end
          else
            a = Confidence::UNCLEAR
          end
        else
          said_authors = said.try(&.authors) || [] of String
          a = if said_authors.empty? || Clean.unknown_authors?(said_authors)
                title_fits ? Confidence::META_NAME : Confidence::META_NOTHING
              elsif Score.authors(said_authors, authors) >= 0.8
                Confidence::META_NAME
              else
                Confidence::META_NAME - Confidence::META_AGAINST_NAME
              end
        end
        if !authors.empty? && !keep_authors?(book, authors) && !same_people?(book.authors, authors)
          changes.concat(author_changes(book, authors, source))
        end
        changes.concat(name_extras(input))
        isbn, isbn_source = meta_isbn(input, changes)
        Decision.new(changes, how, LEVEL_META, source, t, a, isbn, isbn_source, isbn_notes(input))
      end

      private def self.same_people?(mine : Array(String), theirs : Array(String)) : Bool
        mine.map { |a| Text.key(a) }.sort == theirs.map { |a| Text.key(a) }.sort
      end

      # the ISBN of the file's own metadata fills a book without one
      private def self.meta_isbn(input : Input, changes : Array(Change)) : {String?, String?}
        own = own_isbn(input.book)
        return {own, in_book?(input, own) ? text_source(input) : SOURCE_CALIBRE} if own
        isbn = input.info.try(&.record.isbn).try { |i| Isbn.normalize(i) } || return {nil, nil}
        return {nil, nil} unless ((input.owners.try(&.call(isbn)) || [] of Int64) - [input.book.id]).empty?
        changes << Change.new("isbn", JSON::Any.new(nil), JSON::Any.new(isbn), "file")
        {isbn, SOURCE_OPF}
      end

      private def self.in_book?(input : Input, isbn : String) : Bool
        input.info.try(&.found.any? { |f| f.isbn == isbn }) || false
      end

      private def self.text_source(input : Input) : String
        input.info.try(&.ocr) ? SOURCE_OCR : SOURCE_TEXT
      end

      # the file's other ISBN against the one the book has
      private def self.isbn_notes(input : Input) : Array(Note)
        notes = [] of Note
        own = own_isbn(input.book) || return notes
        other = input.info.try(&.record.isbn).try { |i| Isbn.normalize(i) }
        notes << Note.new("isbnConflict", other) if other && other != own
        notes
      end

      # the value of a name's authors
      private def self.name_value(authors : Array(String)) : Int32
        authors.all? { |a| Text.tokens(a).size < 2 } ? Confidence::NAME_SURNAME : Confidence::NAME_FULL
      end

      private def self.suggestion(title : String?, authors : Array(String), source : String) : Change
        Change.new(FileName::CANDIDATE, JSON::Any.new(nil), JSON.parse({title: title, authors: authors, source: source}.to_json), source)
      end

      # The file name, or a book's title read like one (FileName.decide_own)
      private def self.by_name(input : Input, words : Words?, reading : Guess?) : Decision?
        book = input.book
        seen = nil.as(Verdict?)
        wrapped = input.checker.try do |c|
          ->(b : Book, g : Guess) do
            v = c.call(b, g)
            seen = v
            v
          end
        end
        decided = if name = input.name
                    FileName.decide(book, name, input.hint, input.imported, input.decider, wrapped) || return nil
                  else
                    FileName.decide_own(book, input.imported, wrapped) || {[] of Change, FileName::NAME}
                  end
        changes, how = decided
        title = changes.find { |c| c.field == "title" }.try(&.new.as_s?) || book.title
        authors = changes.find { |c| c.field == "authors" }.try(&.new.as_a?.try(&.map(&.as_s))) || book.authors
        t, a = name_values(book, how, seen, reading, title, authors)
        if (w = words) && w.size >= MIN_WORDS && !Fit.title?(title, w) && !authors.any? { |x| w.person?(x) }
          t -= Confidence::TEXT_AGAINST_NAME
          a -= Confidence::TEXT_AGAINST_NAME
        end
        source = changes.find { |c| c.field.in?("title", "authors") }.try(&.source) || "rules"
        isbn = own_isbn(book)
        Decision.new(changes, how, LEVEL_NAME, how == FileName::UNSURE ? "rules" : source, t, a, isbn,
          isbn.try { |i| in_book?(input, i) ? text_source(input) : SOURCE_CALIBRE }, isbn_notes(input))
      end

      private def self.name_values(book : Book, how : String, seen : Verdict?, reading : Guess?, title : String, authors : Array(String)) : {Int32, Int32}
        return {Confidence::NOTHING, Confidence::NOTHING} if FileName.bad_title?(title)
        case how
        when FileName::UNSURE
          value = seen ? Confidence::CATALOG : Confidence::UNCLEAR
          {value, value}
        when "model"
          {Confidence::MODEL, Confidence::MODEL}
        when FileName::NAME, FileName::FOLDER, "file"
          named = !Clean.unknown_authors?(authors) && reading && !reading.authors.empty?
          value = named ? name_value(authors) : Confidence::NAME_SURNAME
          kept = Clean.unknown_authors?(authors) || FileName.bad_author?(authors.first) ? Confidence::UNCLEAR : Confidence::KEPT
          {value, named ? value : kept}
        else
          # a catalog: for a name without an author, or between two readings
          return {Confidence::CATALOG_NAME, Confidence::CATALOG_NAME} unless seen
          value = seen.confirmed && seen.sources.size >= 2 ? Confidence::CATALOGS : Confidence::CATALOG
          {value, value}
        end
      end

      # A hand's fields stay; below the threshold title and authors stay
      # too, what was found becomes a suggestion and the book is tagged.
      # Above it, a book that was tagged isn't unsure any more.
      private def self.finish(input : Input, d : Decision) : Decision
        book = input.book
        hand = input.hand
        hand = hand + Set{"authorSort"} if hand.includes?("authors")
        changes = d.changes.reject { |c| hand.includes?(c.field) }
        t = hand.includes?("title") ? Confidence::HAND : d.title
        a = hand.includes?("authors") ? Confidence::HAND : d.authors
        d = d.copy_with(changes: changes, title: t, authors: a)
        unsure_tag = Meta.unsure_tag
        tags = Merge.value(book, "tags").as_a.map(&.as_s)
        if d.confidence < Confidence::REVIEW
          names = changes.select { |c| FileName::NAME_FIELDS.includes?(c.field) }
          changes -= names
          unless names.empty? || changes.any? { |c| c.field == FileName::CANDIDATE }
            title = names.find { |c| c.field == "title" }.try(&.new.as_s?)
            authors = names.find { |c| c.field == "authors" }.try(&.new.as_a?.try(&.map(&.as_s))) || [] of String
            changes << suggestion(title, authors, names.first.source)
          end
          unless tags.includes?(unsure_tag) || changes.any? { |c| c.field == "tags" }
            changes << Change.new("tags", JSON.parse(tags.to_json), JSON.parse((tags + [unsure_tag]).to_json), d.source)
          end
        elsif tags.includes?(unsure_tag)
          changes = changes.reject { |c| c.field == "tags" }
          changes << Change.new("tags", JSON.parse(tags.to_json), JSON.parse((tags - [unsure_tag]).to_json), d.source)
        else
          changes = changes.reject { |c| c.field == "tags" }
        end
        d.copy_with(changes: changes)
      end
    end
  end
end
