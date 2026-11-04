require "json"
require "./book"
require "./meta_confidence"
require "./meta_filename"
require "./meta_quality"
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

      # An ISBN's level: {isbn, how it came, strict}. The book's own first:
      # another edition's ISBN in its pages is no contradiction when its
      # own record fits.
      private def self.isbns(input : Input) : Array({String, String, Bool})
        info = input.info || return [] of {String, String, Bool}
        text = info.ocr ? SOURCE_OCR : SOURCE_TEXT
        own = own_isbn(input.book)
        found = info.found
        list = [] of {String, String, Bool}
        own.try { |i| list << {i, found.any? { |f| f.isbn == i } ? text : SOURCE_CALIBRE, false} }
        list += found.reject(&.strict).map { |f| {f.isbn, text, false} }
        info.record.isbn.try { |i| Isbn.normalize(i).try { |n| list << {n, SOURCE_OPF, false} } }
        list += found.select(&.strict).map { |f| {f.isbn, text, true} }
        list.uniq(&.[0]).first(MAX_ISBNS)
      end

      private def self.own_isbn(book : Book) : String?
        book.identifiers["isbn"]?.try { |i| Isbn.normalize(i) }
      end

      private def self.by_isbn(input : Input, words : Words?, reading : Guess?) : Decision?
        lookup = input.by_isbn || return nil
        return nil unless words
        page = input.info.try(&.found.select(&.copyright).map(&.isbn)) || [] of String
        isbns(input).each do |isbn, source, strict|
          fits = lookup.call(isbn).compact_map do |c|
            next if Text.tokens(c.fields.title || "").empty?
            fit = Fit.check(c.fields, words)
            next if strict ? !c.fields.title.try { |t| Fit.title?(t, words, strict: true) } : !fit.any?
            {c, fit}
          end
          next if fits.empty?
          c, fit = fits.sort_by { |x, f| {f.both? ? 0 : 1, f.title ? 0 : 1, Merge::PRECEDENCE["authors"].index(x.source) || 9} }.first
          verdict = judge(input, c.fields, fit, words, reading, source != SOURCE_TEXT && source != SOURCE_OCR || page.includes?(isbn))
          next if verdict == :quoted
          return level_isbn(input, c, fit, isbn, source, reading, words, verdict)
        end
        nil
      end

      # what the book says it is: its name and its title, as far as they say
      # something. A surname, a code or "New Page 12" is no title.
      private def self.own_titles(input : Input, reading : Guess?, r : Record) : Array(String)
        book = input.book
        names = (book.authors + (reading.try(&.authors) || [] of String) + (r.authors || [] of String)).flat_map { |a| Text.tokens(a) }.to_set
        [reading.try(&.title), book.title].compact.uniq.select do |t|
          words = Text.tokens(t)
          !FileName.bad_title?(t) && !Quality.file_name?(t) && FileName.side_score(t) < 2 &&
            !FileName.known_publisher?(t) && !(words.size == 1 && names.includes?(words.first))
        end
      end

      # the same title, also in another spelling
      private def self.same_title?(a : String, b : String) : Bool
        x, y = Text.key(a), Text.key(b)
        return true if Text.key(Text.main_title(a)) == Text.key(Text.main_title(b))
        short, long = x.size < y.size ? {x, y} : {y, x}
        return false if short.empty?
        return true if long.includes?(short) && (Text.tokens(x.size < y.size ? a : b).size >= 2 || short.size * 2 >= long.size)
        Text.similarity(a, b) >= 0.6 || Levenshtein.distance(x, y) * 7 <= long.size
      end

      TRANSLATED = /original(?:titel|ausgabe)|orginalausgabe|titel der original|aus dem \p{L}+ von|übersetz|translated (?:from|by)/i

      # The text names the record's title as the original's, or is in another
      # language than the title and has this ISBN on its copyright page
      private def self.translated?(input : Input, title : String, on_copyright_page : Bool) : Bool
        front = input.info.try(&.front) || return false
        front.scan(TRANSLATED) do |m|
          return true if Fit.title?(title, Words.new(front[m.end(0), 200]? || ""))
        end
        return false unless on_copyright_page
        case Lang.of_text(front)
        when "deu" then !Lang.german_title?(title)
        when "eng" then Lang.german_title?(title)
        else            false
        end
      end

      # How the record stands to what the book says it is. An ISBN in a book
      # is not always the book's: a guidance quotes its sources, a foreword
      # the English edition. So a title or name that says something and
      # disagrees is a contradiction, which only the title page settles.
      # :agrees; :translation (the author fits, another language, the ISBN on
      # the copyright page, or the text names it the original); :subtitle (the book's title is the record's
      # subtitle); :confirmed (the title page shows the record, not the book's
      # title); :quoted (the text has the book's title: the record is
      # something it quotes); :against (nothing says which is right)
      private def self.judge(input : Input, r : Record, fit : Fit::Result, words : Words, reading : Guess?, on_copyright_page : Bool) : Symbol
        title = catalog_title(r)
        owns = own_titles(input, reading, r)
        return :agrees if owns.empty? || owns.any? { |t| same_title?(t, title) }
        return :translation if fit.authors && translated?(input, title, on_copyright_page)
        main = Text.tokens(Text.main_title(title))
        return :subtitle if owns.any? { |t| words.phrase?(main + Text.tokens(t)) }
        return :confirmed if on_copyright_page && Fit.title_page?(title, words) && !owns.any? { |t| Fit.title_page?(t, words) }
        return :quoted if owns.any? { |t| Fit.title?(t, words) }
        :against
      end

      private def self.level_isbn(input : Input, c : Candidate, fit : Fit::Result, isbn : String, isbn_source : String,
                                  reading : Guess?, words : Words, verdict : Symbol) : Decision
        book = input.book
        changes = [] of Change
        record_title = catalog_title(c.fields)
        owns = own_titles(input, reading, c.fields)
        title = case verdict
                when :agrees      then chosen_title(book, reading, record_title, words)
                when :translation then (owns.includes?(book.title) ? book.title : owns.first?) || record_title
                when :subtitle    then "#{Text.main_title(record_title)}: #{owns.first}"
                else                   record_title
                end
        authors, known = authors_for(book, reading, c.fields, title, words)
        # "Buss - 3D Computer Graphics": the author in front of a title in order
        parts = book.title.split(/\s+[-–]\s+/)
        named = parts.size >= 2 && authors.any? { |x| People.tokens(x).last? == Text.key(parts.first) }
        unless verdict != :subtitle && !named && keep_title?(book, title)
          changes << Change.new("title", JSON::Any.new(book.title), JSON::Any.new(title), c.source) unless FileName.same_text?(book.title, title)
        end
        changes.concat(author_changes(book, authors, c.source)) unless authors.empty? || FileName.same_authors?(book.authors, authors)
        t = fit.title && verdict == :agrees ? Confidence::ISBN_BOTH : Confidence::ISBN_ONE
        a = fit.authors ? Confidence::ISBN_BOTH : Confidence::ISBN_ONE
        a = {a, Confidence::ISBN_OTHER_PEOPLE}.min unless known
        case verdict
        when :confirmed then t = a = Confidence::ISBN_CONFIRMED
        when :against   then t = a = Confidence::ISBN_AGAINST
        end
        notes = [] of Note
        own = own_isbn(book)
        if own && own != isbn
          notes << Note.new("isbnConflict", isbn)
          isbn, isbn_source = own, SOURCE_CALIBRE
        elsif own.nil?
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

      # The authors after a record: its persons in the book's text when any
      # is ("Cambridge India" isn't), merged with the book's and its name's
      # (People.merge). The book's own count only for this title: a file with
      # another book's metadata has that book's authors.
      private def self.authors_for(book : Book, reading : Guess?, r : Record, title : String, words : Words) : {Array(String), Bool}
        people = CrossCheck.people(r)
        here = people.select { |a| words.person?(a) }
        people = here unless here.empty?
        own = !FileName.bad_title?(book.title) && FileName.same_book?(book.title, title) ? People.clean(book.authors) : [] of String
        # "Glitch - The Hidden Impact…", "OpenGL": a word of the title is nobody
        title_words = Text.tokens(catalog_title(r))
        name = reading.try(&.authors) || [] of String
        # the book and the record agree: a name doesn't add anybody, its
        # "D. Clark" is the series' editor
        if own.any? { |a| people.any? { |t| People.same?(a, t) } }
          name = name.select { |a| (own + people).any? { |t| People.same?(a, t) } }
        end
        named = (own + name).reject { |a| People.tokens(a).size < 2 && People.tokens(a).all? { |w| title_words.includes?(w) } }
        People.merge(named, people, words)
      end

      # what a shop adds to a title: "…, with CDROM", "(with CD-ROM)"
      SHOP_NOTE = /[,:]?\s*\(?\b(?:with|incl\.?|includes|\+)\s+(?:a\s+|an\s+)?(?:cd-?rom|dvd|cd)\b\)?\s*\z/i

      # The record's title with its subtitle, without a series in parentheses
      # or a note
      private def self.catalog_title(r : Record) : String
        t = Text.main_title(r.title || "").strip.sub(/\s*\([^()]*\)\z/, "")
        t = t.sub(SHOP_NOTE, "")
        sub = r.subtitle.try(&.strip.sub(SHOP_NOTE, ""))
        return "#{t}: #{sub}" if sub && Merge.subtitle?(sub, t)
        t
      end

      # what the book itself says it is called, besides a catalog: its name,
      # else a title that says something
      private def self.own_title(book : Book, reading : Guess?) : String?
        reading.try(&.title) || (book.title unless FileName.leftover_title?(book.title))
      end

      # Of two forms of a title the book's, when the catalog's has nothing
      # more: catalogs write titles like sentences, abbreviate ("Bd. 1"), lose
      # the volume
      private def self.chosen_title(book : Book, reading : Guess?, record : String, words : Words) : String
        # "Genetic Engineering Principles & Methods Volume 9-Springer US"
        if Text.volume(book.title) && !Text.volume(record) && same_title?(book.title, record)
          return reading.try(&.title) || FileName.parse("#{book.title}.pdf").try(&.title) || book.title
        end
        own = own_title(book, reading) || return record
        # a name in one word is no form of a title: "buildabinaryclock…"
        own = book.title unless own.includes?(' ') || FileName.leftover_title?(book.title)
        return record unless same_title?(own, record)
        # "From Journeyman to Master" in the book, a later edition's subtitle in the catalog
        return own if own.includes?(':') && record.includes?(':') && Fit.title?(subtitle_of(own), words) && !Fit.title?(subtitle_of(record), words)
        return own if Text.key(Text.main_title(own)) == Text.key(Text.main_title(record)) && !record.includes?(':')
        return own if Text.key(own) == Text.key(record) || Text.volume(own) && !Text.volume(record)
        return own if sentence?(record)
        return own if Levenshtein.distance(Text.key(own), Text.key(record)) * 7 <= Text.key(own).size
        record
      end

      private def self.subtitle_of(title : String) : String
        title.partition(':')[2].strip
      end

      # a title in several words, capitals only at its start
      private def self.sentence?(title : String) : Bool
        words = title.split(' ', remove_empty: true)
        words.size >= 2 && words[1..].none?(&.[0].uppercase?)
      end

      # The same words in no better form: "Ethernet Definitive Guide" for
      # "Ethernet: The Definitive Guide". A title that is in order stays,
      # whoever has a plainer version.
      private def self.worse_form?(old : String, new : String) : Bool
        return false if FileName.leftover_title?(old)
        content = ->(t : String) { Text.tokens(t).reject { |w| w.size < 3 || Clean::SMALL.includes?(w) }.sort }
        return false unless content.call(old) == content.call(new)
        form = ->(t : String) { Text.tokens(t).size + (t.includes?(':') ? 1 : 0) - (sentence?(t) ? 1 : 0) }
        form.call(new) <= form.call(old)
      end

      # the same book under a title that is in order stays
      private def self.keep_title?(book : Book, title : String) : Bool
        return true if FileName.same_text?(book.title, title)
        return false if FileName.leftover_title?(book)
        FileName.same_book?(book.title, title)
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
        listed = (record.try(&.authors) || [] of String).flat_map { |a| a.matches?(/\s(?:and|und)\s/) ? FileName.split_authors(a) : [a] }
        authors = Clean.authors(listed.map { |a| FileName.clean_author(a) }).reject { |a| FileName.bad_author?(a) }
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
        unless authors.empty?
          # a file doesn't remove a co-author either
          own = FileName.same_book?(book.title, title) ? People.clean(book.authors) : [] of String
          merged, known = People.merge(own, authors, words)
          authors = merged if known
          changes.concat(author_changes(book, authors, source)) unless same_people?(book.authors, authors)
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
        changes = changes.reject { |c| c.field == "title" && c.new.as_s?.try { |t| worse_form?(book.title, t) } }
        t = hand.includes?("title") ? Confidence::HAND : d.title.clamp(0, 100)
        a = hand.includes?("authors") ? Confidence::HAND : d.authors.clamp(0, 100)
        d = d.copy_with(changes: changes, title: t, authors: a)
        unsure_tag = Meta.unsure_tag
        tags = Merge.value(book, "tags").as_a.map(&.as_s)
        if d.confidence < Confidence::REVIEW
          names = changes.select { |c| FileName::NAME_FIELDS.includes?(c.field) }
          changes -= names
          # an ISBN nobody confirms isn't this book's yet
          if changes.any? { |c| c.field == "isbn" }
            changes = changes.reject { |c| c.field == "isbn" }
            d = d.copy_with(isbn: nil, isbn_source: nil)
          end
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
