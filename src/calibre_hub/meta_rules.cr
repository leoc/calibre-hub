require "json"
require "uri"
require "./book"

class Array(T)
  # nil when empty, like String#presence
  def presence : self?
    empty? ? nil : self
  end
end

module CalibreHub
  # Rules of the metadata cleanup (metadata.cr): cleaning names that came
  # from file names, ISBNs, matching candidates from online sources and
  # merging them per field. Pure, so every rule can be tested without
  # calibre-server, a model or the internet.
  module Meta
    TAG = "auto-metadaten"
    # fields the cleanup changes, as the change log names them
    FIELDS = %w(title authors authorSort isbn publisher pubdate languages comments series seriesIndex cover)
    # a candidate this good fills missing fields
    ACCEPT = 0.75
    # a text match this good may also fill the ISBN of that edition
    HIGH = 0.9

    # One source's view of a book; only the fields the source has
    class Record
      include JSON::Serializable

      property title : String?
      property authors : Array(String)?
      property isbn : String?
      property publisher : String?
      # YYYY-MM-DD, or YYYY when only the year is known
      property pubdate : String?
      # ISO 639-2 as calibre stores them (deu, eng)
      property languages : Array(String)?
      # HTML
      property comments : String?
      property series : String?
      @[JSON::Field(key: "seriesIndex")]
      property series_index : Float64?
      @[JSON::Field(key: "coverUrl")]
      property cover_url : String?

      def initialize(@title = nil, @authors = nil, @isbn = nil, @publisher = nil, @pubdate = nil,
                     @languages = nil, @comments = nil, @series = nil, @series_index = nil, @cover_url = nil)
      end

      def year : Int32?
        pubdate.try { |d| d[0, 4].to_i? }
      end
    end

    # A search result. sure: found by an ISBN the book (or its file) has
    # and agrees with the book
    class Candidate
      include JSON::Serializable

      getter source : String
      property score : Float64 = 0.0
      property sure : Bool = false
      @[JSON::Field(emit_null: true)]
      getter url : String?
      getter fields : Record
      # found by this ISBN lookup
      @[JSON::Field(ignore: true)]
      property by_isbn : String?
      # one edition (not a work with many): its ISBN and publisher are usable
      @[JSON::Field(ignore: true)]
      property edition : Bool = true
      # provider reference for details fetched later (Open Library work key)
      @[JSON::Field(ignore: true)]
      property ref : String?

      def initialize(@source, @fields, @url = nil, @by_isbn = nil, @edition = true, @ref = nil)
      end
    end

    # What the rules (or the model) make of title and authors
    record Guess, title : String, authors : Array(String), series : String? = nil,
      series_index : Float64? = nil, year : Int32? = nil, source : String = "rules"

    module Isbn
      # ISBN-13 digits, or nil when it isn't a valid ISBN-10/13
      def self.normalize(input : String) : String?
        s = input.upcase.gsub(/[^0-9X]/, "")
        if s.size == 13 && s.each_char.all?(&.ascii_number?) && valid13?(s) && s.starts_with?("97")
          s
        elsif s.size == 10 && s[0, 9].each_char.all?(&.ascii_number?) && valid10?(s)
          to13(s)
        end
      end

      def self.valid10?(s : String) : Bool
        sum = 0
        s.each_char_with_index do |c, i|
          v = c == 'X' ? (i == 9 ? 10 : return false) : c.to_i
          sum += v * (10 - i)
        end
        sum % 11 == 0
      end

      def self.valid13?(s : String) : Bool
        sum = 0
        s.each_char_with_index { |c, i| sum += c.to_i * (i.even? ? 1 : 3) }
        sum % 10 == 0
      end

      def self.to13(s10 : String) : String
        base = "978" + s10[0, 9]
        sum = 0
        base.each_char_with_index { |c, i| sum += c.to_i * (i.even? ? 1 : 3) }
        base + ((10 - sum % 10) % 10).to_s
      end

      PATTERN = /(?:ISBN(?:-1[03])?[:\s]*)?(?<![\d-])((?:97[89][\s‐-]?)?\d[\d\s‐-]{7,15}[\dXx])(?![\d])/i

      # Valid ISBNs in a text, labelled ones ("ISBN 978-...") first, each once
      def self.scan(text : String) : Array(String)
        labelled = [] of String
        other = [] of String
        text.scan(PATTERN) do |m|
          isbn = normalize(m[1]) || next
          (m[0].upcase.starts_with?("ISBN") ? labelled : other) << isbn
        end
        (labelled + other).uniq
      end
    end

    module Text
      # letters NFKD doesn't take apart
      LETTERS = {'ß' => "ss", 'ł' => "l", 'Ł' => "l", 'ø' => "o", 'Ø' => "o", 'đ' => "d", 'Đ' => "d",
                 'æ' => "ae", 'Æ' => "ae", 'œ' => "oe", 'Œ' => "oe", 'ı' => "i"}

      def self.fold(s : String) : String
        s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").gsub(/[ßłŁøØđĐæÆœŒı]/) { |c| LETTERS[c[0]] }.downcase
      end

      def self.tokens(s : String) : Array(String)
        fold(s).gsub(/[^\p{L}\p{N}]+/, " ").split(' ', remove_empty: true)
      end

      # compares ignoring case, accents, punctuation and spaces
      def self.key(s : String) : String
        tokens(s).join
      end

      # title without subtitle ("Dune: Der Wüstenplanet", "A : B")
      def self.main_title(s : String) : String
        s.split(/\s+:\s+|:\s+|\s+[-–]\s+(?=\p{Lu})/, 2).first.strip
      end

      # 0..1, how alike two titles are (main titles, token sets)
      def self.similarity(a : String, b : String) : Float64
        ka, kb = key(main_title(a)), key(main_title(b))
        return 0.0 if ka.empty? || kb.empty?
        return 1.0 if ka == kb || key(a) == key(b)
        ta, tb = tokens(main_title(a)).to_set, tokens(main_title(b)).to_set
        2.0 * (ta & tb).size / (ta.size + tb.size)
      end

      def self.diacritics(s : String) : Int32
        s.unicode_normalize(:nfkd).count { |c| c.mark? }
      end
    end

    # Cleaning rules for titles and authors that came from file names
    module Clean
      UNKNOWN = Set{"unbekannt", "unknown", "unknown author", "autor unbekannt", "n a", "na", "none", "admin",
                    "administrator", "user", "owner", "calibre", "microsoft office user", "author", "autor"}
      SOURCES = /z[\s-]?lib(?:rary)?(?:\.\w{2,3})?|1lib(?:\.\w{2,3})?|libgen(?:\.\w{2,3})?|b-ok(?:\.\w{2,3})?|anna['’]?s[\s_]archive|epub|pdf|mobi|azw3?|retail|e-?book|calibre|scan|ocr|dl|www\.[\w.-]+/i
      JUNK    = [
        /\s*[\(\[\{]\s*(?:#{SOURCES.source})(?:\s*[,;]\s*(?:#{SOURCES.source}))*\s*[\)\]\}]/i,
        /\s+[-–]\s+(?:z-lib\.\w+|libgen\.\w+|anna['’]?s archive)\s*\z/i,
        /\A\s*microsoft (?:word|powerpoint) - /i,
        /\b[0-9a-f]{32}\b/i,
        /\s*[\(\[](?:\d+|copy|kopie)[\)\]]\s*\z/i,
      ]
      EXTENSION = /\.(?:epub|pdf|mobi|azw3?|docx?|txt|rtf|fb2|djvu|cbz|cbr|kepub)\z/i
      SMALL     = Set{"der", "die", "das", "des", "dem", "den", "ein", "eine", "einer", "und", "oder", "von", "vom",
                      "zu", "zum", "zur", "im", "in", "am", "an", "auf", "aus", "mit", "für", "über", "unter", "bei",
                      "nach", "the", "a", "an", "of", "and", "or", "to", "in", "on", "at", "for", "with", "by", "from",
                      "as", "is", "le", "la", "les", "de", "du", "et", "el", "los", "y"}
      PARTICLES   = Set{"von", "van", "der", "den", "de", "du", "da", "di", "zu", "ten", "ter", "y"}
      ROMAN       = /\A(?:i{1,3}|iv|v|vi{1,3}|ix|x|xi{1,3})\z/i
      TITLE_WORDS = Set{"die", "das", "und", "the", "of", "and", "ein", "eine", "im", "mit", "für", "vom", "zum",
                        "zur", "band", "teil", "roman", "volume", "vol", "edition", "auflage", "a", "an", "how", "why",
                        "was", "wie", "über", "guide", "handbuch", "einführung", "introduction"}

      ARTICLES = Set{"der", "die", "das", "the", "a", "an", "ein", "eine", "le", "la", "les", "el", "il"}

      def self.unknown_author?(name : String) : Bool
        n = Text.fold(name).gsub(/[^\p{L}]+/, " ").strip
        n.empty? || UNKNOWN.includes?(n)
      end

      def self.unknown_authors?(authors : Array(String)) : Bool
        authors.empty? || authors.all? { |a| unknown_author?(a) }
      end

      # File junk out: download-site markers, extensions, hashes,
      # underscores, dots instead of spaces
      def self.strip_junk(s : String) : String
        t = s.unicode_normalize.strip
        t = URI.decode(t) if t.includes?("%20")
        t = t.sub(EXTENSION, "")
        t = t.gsub('_', ' ')
        t = t.gsub('.', ' ') if !t.includes?(' ') && t.count('.') >= 2 && !t.matches?(/\A(?:\p{L}\.)+\z/)
        JUNK.each { |j| t = t.gsub(j, "") }
        t.gsub(/\s+/, " ").strip.strip("-–_.,;: ").strip
      end

      def self.junk?(s : String) : Bool
        strip_junk(s) != s.strip || s.includes?('_')
      end

      # all caps or all lower case (at least a few letters)
      def self.broken_case?(s : String) : Bool
        letters = s.chars.select(&.letter?)
        return false if letters.size < 4
        letters.all?(&.uppercase?) || letters.all?(&.lowercase?)
      end

      def self.fix_title_case(s : String) : String
        return s unless broken_case?(s)
        words = s.downcase.split(' ')
        words.map_with_index do |w, i|
          if w.matches?(ROMAN) && i > 0
            w.upcase
          elsif i > 0 && SMALL.includes?(w)
            w
          else
            capitalize(w)
          end
        end.join(' ')
      end

      def self.fix_name_case(s : String) : String
        return s unless broken_case?(s)
        tokens = s.downcase.split(' ')
        tokens.map_with_index do |w, i|
          (i > 0 && i < tokens.size - 1 && PARTICLES.includes?(w)) ? w : capitalize(w)
        end.join(' ')
      end

      # first letter up, also after hyphens and apostrophes (Jean-Paul, O'Brien)
      def self.capitalize(w : String) : String
        w.gsub(/(\A|[-'’.])(\p{Ll})/) { "#{$1}#{$2.upcase}" }
      end

      # "Tolkien, J. R. R." -> "J. R. R. Tolkien"; "A & B" -> two authors
      def self.authors(list : Array(String)) : Array(String)
        list.flat_map { |a| split_authors(strip_junk(a)) }.map { |a| fix_name_case(invert(a)) }
          .reject { |a| a.empty? || unknown_author?(a) }.uniq { |a| Text.key(a) }
      end

      def self.split_authors(s : String) : Array(String)
        parts = s.split(/\s*;\s*|\s+&\s+|\s+(?:und|and)\s+/i).map(&.strip).reject(&.empty?)
        return [s] if parts.size > 1 && !parts.all? { |p| name_score(p) > 0 }
        # "A B, C D, E F": a list, not "Last, First"
        if parts.size == 1 && s.count(',') >= 2
          commas = s.split(',').map(&.strip)
          return commas if commas.all? { |p| p.split(' ').size >= 2 }
        end
        parts
      end

      # "Last, First" -> "First Last"
      def self.invert(name : String) : String
        m = name.match(/\A([^,]+),\s*([^,]+)\z/) || return name
        last, first = m[1].strip, m[2].strip
        return name if first.matches?(/\A(?:jr|sr|ii|iii|iv|phd|md)\.?\z/i)
        "#{first} #{last}"
      end

      # > 0 looks like a person, < 0 like a title
      def self.name_score(s : String) : Int32
        tokens = s.split(/\s+/).reject(&.empty?)
        return -3 if tokens.empty? || s.matches?(/\d/)
        score = 0
        score += 2 if s.matches?(/\A[^,]+,\s*[^,]+\z/)
        score += 2 if tokens.any? { |t| t.matches?(/\A\p{L}\.(?:\p{L}\.)*\z/) }
        score += 1 if 2 <= tokens.size <= 3
        score -= 2 if tokens.size > 4
        score -= 2 * tokens.count { |t| TITLE_WORDS.includes?(Text.fold(t).strip(",.")) }
        score -= 1 if tokens.size == 1
        score -= 2 if s.matches?(/[!?:]/)
        # titles start with an article, names don't
        score -= 3 if ARTICLES.includes?(Text.fold(tokens.first))
        score
      end

      # Readings of title and authors, the most likely first. ambiguous:
      # the rules can't tell which part is the author.
      def self.guesses(title : String, authors : Array(String), pubdate_year : Int32? = nil) : {Array(Guess), Bool}
        year = pubdate_year
        raw_title = title
        if m = raw_title.match(/\s*[\(\[]((?:1[5-9]|20)\d\d)[\)\]]\s*/)
          year ||= m[1].to_i
          raw_title = raw_title.sub(m[0], " ")
        end
        t = strip_junk(raw_title)
        known = authors(authors)
        unknown = known.empty?

        parts = t.split(/\s+[-–]\s+|\s*_-_\s*/).map(&.strip).reject(&.empty?)
        if parts.size >= 2
          # the author is in the title next to the known author field
          unless unknown
            keys = known.map { |a| Text.key(a) }
            surnames = known.map { |a| Text.tokens(a).last? }.compact
            matches = ->(p : String) { keys.includes?(Text.key(invert(p))) || (Text.tokens(p).size == 1 && surnames.includes?(Text.key(p))) }
            if matches.call(parts.first)
              return {[guess(parts[1..].join(" - "), known, year)], false}
            elsif matches.call(parts.last)
              return {[guess(parts[0..-2].join(" - "), known, year)], false}
            end
          end
          if unknown
            # "Author - Series 03 - Title", as the reading list names files
            if parts.size == 3 && (m = parts[1].match(/\A(.+?)\s+#?(\d+(?:\.\d+)?)\z/)) && name_score(parts[0]) >= -1
              return {[guess(parts[2], authors([parts[0]]), year, m[1], m[2].to_f)], false}
            end
            a, b = parts.first, parts[1..].join(" - ")
            sa, sb = name_score(a), name_score(parts.last)
            author_first = guess(b, authors([a]), year)
            author_last = guess(parts[0..-2].join(" - "), authors([parts.last]), year)
            if sa - sb >= 2
              return {[author_first], false}
            elsif sb - sa >= 2
              return {[author_last], false}
            else
              # "Autor - Titel" is the more common file name
              return {[author_first, author_last], true}
            end
          end
        end

        # calibre took "Title - Author" the wrong way round: title in the
        # author field, the name in the title
        if !unknown && known.size == 1 && authors.size == 1 && name_score(authors.first) <= -2 && name_score(t) >= 1
          swapped = guess(strip_junk(authors.first), authors([t]), year)
          return {[swapped, guess(t, known, year)], true}
        end
        {[guess(t, known, year)], false}
      end

      private def self.guess(title, authors, year, series = nil, index = nil) : Guess
        Guess.new(fix_title_case(title.strip), authors, series.try(&.strip), index, year)
      end

      # The title or authors need the rules (or the model)
      def self.messy?(book : Book) : Bool
        junk?(book.title) || broken_case?(book.title) || unknown_authors?(book.authors) ||
          book.authors.any? { |a| junk?(a) || broken_case?(a) || a.matches?(/\A[^,]+,\s*[^,]+\z/) } ||
          (book.title.matches?(/\s[-–]\s/) && guesses(book.title, book.authors)[0].first.title != book.title)
      end
    end

    # calibre's default author sort ("invert"): "Ursula K. Le Guin" ->
    # "Guin, Ursula K. Le", like calibre computes it for new authors
    module AuthorSort
      PREFIXES  = %w(mr mrs ms dr prof)
      SUFFIXES  = %w(jr sr inc ph.d phd md m.d i ii iii iv junior senior)
      COPYWORDS = %w(corporation company inc ltd llc university society association institute
        foundation gmbh ag verlag group team publishing)

      def self.for(name : String) : String
        tokens = name.gsub(/[\(\[][^\)\]]*[\)\]]/, "").split
        return name if tokens.size < 2
        return name if tokens.any? { |t| COPYWORDS.includes?(t.downcase.rstrip('.')) }
        tokens.shift if PREFIXES.includes?(tokens.first.downcase.rstrip('.'))
        suffix = SUFFIXES.includes?(tokens.last.downcase.rstrip('.')) && tokens.size > 2 ? tokens.pop : nil
        return name if tokens.size < 2
        sorted = ["#{tokens.last},"] + tokens[0..-2]
        sorted << suffix if suffix
        sorted.join(' ')
      end

      def self.for(authors : Array(String)) : String
        authors.map { |a| self.for(a) }.join(" & ")
      end

      # the sort shares no name with the authors (e.g. "Unbekannt" or the
      # file name); a hand-made sort like "Le Guin, Ursula K." stays
      def self.wrong?(book : Book) : Bool
        return false if Clean.unknown_authors?(book.authors)
        current = book.author_sort.presence || return true
        return false if Text.key(current) == Text.key(self.for(book.authors))
        names = book.authors.flat_map { |a| Text.tokens(a) }.select { |t| t.size > 1 }.to_set
        (Text.tokens(current).to_set & names).empty?
      end
    end

    module Lang
      # 2-letter and MARC bibliographic codes -> ISO 639-2/T as calibre uses them
      MAP = {
        "de" => "deu", "ger" => "deu", "en" => "eng", "fr" => "fra", "fre" => "fra", "es" => "spa",
        "it" => "ita", "nl" => "nld", "dut" => "nld", "pt" => "por", "ru" => "rus", "pl" => "pol",
        "sv" => "swe", "da" => "dan", "no" => "nor", "nb" => "nob", "fi" => "fin", "cs" => "ces",
        "cze" => "ces", "el" => "ell", "gre" => "ell", "la" => "lat", "ja" => "jpn", "zh" => "zho",
        "chi" => "zho", "tr" => "tur", "hu" => "hun", "rum" => "ron", "ro" => "ron", "slo" => "slk",
        "sk" => "slk", "per" => "fas", "wel" => "cym", "ice" => "isl", "he" => "heb", "ar" => "ara",
      }

      def self.normalize(code : String) : String?
        c = code.strip.downcase.split(/[-_]/).first? || return nil
        return nil unless c.matches?(/\A[a-z]{2,3}\z/)
        MAP[c]? || (c.size == 3 ? c : nil)
      end

      def self.list(codes : Enumerable(String)) : Array(String)
        codes.compact_map { |c| normalize(c) }.uniq
      end
    end

    module Dates
      MONTHS = %w(jan feb mar apr may jun jul aug sep oct nov dec)

      # "Aug 01, 2009", "2009-08-01", "[2023]", "c2005" -> YYYY-MM-DD or YYYY
      def self.normalize(s : String) : String?
        if m = s.match(/(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d)/)
          return "#{m[1]}-#{m[2]}-#{m[3]}" if valid?(m[1].to_i, m[2].to_i, m[3].to_i)
        end
        if m = s.match(/\b([a-z]{3})[a-z]*\.?\s+(\d{1,2}),?\s+(\d{4})\b/i)
          month = MONTHS.index(m[1].downcase)
          return "#{m[3]}-#{(month + 1).to_s.rjust(2, '0')}-#{m[2].rjust(2, '0')}" if month && valid?(m[3].to_i, month + 1, m[2].to_i)
        end
        s.match(/(?<!\d)(1[5-9]\d\d|20\d\d)(?!\d)/).try(&.[1])
      end

      private def self.valid?(y, m, d) : Bool
        1 <= m <= 12 && 1 <= d <= 31 && 1500 <= y <= 2100
      end

      # calibre needs a day; a year alone becomes January 1st
      def self.full(d : String) : String
        d.size == 4 ? "#{d}-01-01" : d
      end
    end

    module Score
      # 0..1: title 60 %, authors 30 %, language and year 10 %.
      # Unknown parts count half.
      def self.score(guess : Guess, languages : Array(String), c : Record) : Float64
        t = c.title.try { |ct| Text.similarity(guess.title, ct) } || 0.0
        a = authors(guess.authors, c.authors || [] of String)
        extras = (language(languages, c.languages) + year(guess.year, c.year)) / 2
        s = 0.6 * t + 0.3 * a + 0.1 * extras
        # a short title without an author proves nothing ("Gedichte")
        s = s.clamp(0.0, ACCEPT - 0.01) if guess.authors.empty? && Text.tokens(guess.title).size < 3
        s.round(3)
      end

      def self.authors(mine : Array(String), theirs : Array(String)) : Float64
        return 0.5 if mine.empty? || theirs.empty?
        best = 0.0
        mine.each do |m|
          theirs.each do |o|
            o = Clean.invert(o)
            v = if Text.key(m) == Text.key(o)
                  1.0
                elsif Text.tokens(m).last? == Text.tokens(o).last?
                  0.8
                else
                  ta, tb = Text.tokens(m).to_set, Text.tokens(o).to_set
                  (ta & tb).size.to_f / {ta.size, tb.size}.max
                end
            best = v if v > best
          end
        end
        best
      end

      def self.language(mine : Array(String), theirs : Array(String)?) : Float64
        return 0.5 if mine.empty? || theirs.nil? || theirs.empty?
        (mine & theirs).empty? ? 0.0 : 1.0
      end

      def self.year(mine : Int32?, theirs : Int32?) : Float64
        return 0.5 unless mine && theirs
        d = (mine - theirs).abs
        d <= 1 ? 1.0 : d <= 5 ? 0.5 : 0.0
      end

      # Scores the candidates against the best fitting guess and marks the
      # sure ones: found by an ISBN that is trusted (in calibre or the
      # book's OPF) or that agrees with the book (from the text)
      def self.rank(candidates : Array(Candidate), guesses : Array(Guess), languages : Array(String),
                    trusted_isbns : Array(String)) : Array(Candidate)
        candidates.each do |c|
          c.score = guesses.max_of { |g| score(g, languages, c.fields) }
          if isbn = c.by_isbn
            c.sure = trusted_isbns.includes?(isbn) || c.score >= 0.5
            c.score = 1.0 if c.sure
          end
        end
        candidates.each_with_index.to_a.sort_by { |c, i| {c.sure ? 0 : 1, -c.score, i} }.map(&.[0])
      end
    end

    # One field change: old and new as the API shows them
    record Change, field : String, old : JSON::Any, new : JSON::Any, source : String

    module Merge
      # The field's value as the change log and the API show it
      def self.value(book : Book, field : String) : JSON::Any
        case field
        when "title"       then JSON::Any.new(book.title)
        when "authors"     then JSON.parse(book.authors.to_json)
        when "authorSort"  then JSON::Any.new(book.author_sort)
        when "isbn"        then JSON::Any.new(book.identifiers["isbn"]?)
        when "publisher"   then JSON::Any.new(book.publisher)
        when "pubdate"     then JSON::Any.new(book.pubdate.try(&.to_utc.to_s("%F")))
        when "languages"   then JSON.parse(book.languages.to_json)
        when "comments"    then JSON::Any.new(book.comments)
        when "series"      then JSON::Any.new(book.series)
        when "seriesIndex" then JSON::Any.new(book.series_index)
        else                    JSON::Any.new(nil)
        end
      end

      # PATCH body for setting fields back or forth (cover separately)
      def self.patch(book : Book, values : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
        body = {} of String => JSON::Any
        values.each do |field, v|
          case field
          when "isbn"
            ids = book.identifiers.dup
            if s = v.as_s?
              ids["isbn"] = s
            else
              ids.delete("isbn")
            end
            body["identifiers"] = JSON.parse(ids.to_json)
          when "pubdate"
            body["pubdate"] = JSON::Any.new(v.as_s?.try { |d| Dates.full(d) })
          when "seriesIndex"
            body["seriesIndex"] = v.raw.nil? ? JSON::Any.new(1.0) : v
          when "cover"
          else
            body[field] = v
          end
        end
        body
      end

      # Per field what to change, with its source. Precedence: the rules'
      # (or model's) cleaned title and authors, then the book file, then the
      # online candidates, best first. Missing fields are filled from an
      # accepted candidate (score >= ACCEPT); an existing value is only
      # replaced when it is broken, or by a sure (ISBN) match, or by the same
      # value spelled better (case, accents, spacing). Descriptions are only
      # filled, never replaced. cover: the book has none.
      def self.plan(book : Book, guess : Guess?, file : Record?, candidates : Array(Candidate),
                    has_cover = true) : Array(Change)
        changes = [] of Change
        accepted = candidates.select { |c| c.sure || c.score >= ACCEPT }
        sure = accepted.find(&.sure)
        best = sure || accepted.first?
        # only candidates of the same book as the best (not an omnibus
        # "Earthsea & The Left Hand of Darkness" next to the novel)
        best_key = best.try(&.fields.title).try { |t| Text.key(Text.main_title(t)) }
        accepted = accepted.select { |c| c.sure || c == best || c.fields.title.try { |t| Text.key(Text.main_title(t)) } == best_key }
        set = ->(field : String, value : JSON::Any, source : String) do
          old = value(book, field)
          changes << Change.new(field, old, value, source) unless same?(field, old, value)
        end

        # title
        title, title_source = book.title, ""
        if guess && guess.title != book.title && !guess.title.empty?
          title, title_source = guess.title, guess.source
        end
        if file && (ft = file.title) && !Clean.junk?(ft) && !Clean.broken_case?(ft) && Clean.messy?(book) &&
           Text.similarity(title, ft) < 1.0 && guess.try(&.source) != "model" && title_messy?(title)
          title, title_source = ft, "file"
        end
        if best && (bt = best.fields.title)
          bt = Text.main_title(bt)
          if Text.key(bt) == Text.key(title) && better_form?(bt, title)
            title, title_source = bt, best.source
          elsif best.sure && (title_messy?(title) || Text.similarity(title, bt) < 0.5)
            title, title_source = bt, best.source
          end
        end
        set.call("title", JSON::Any.new(title), title_source) unless title_source.empty?

        # authors
        authors, authors_source = book.authors, ""
        if guess && !guess.authors.empty? && guess.authors != book.authors
          authors, authors_source = guess.authors, guess.source
        end
        if Clean.unknown_authors?(authors) && file && (fa = file.authors) && !(clean = Clean.authors(fa)).empty?
          authors, authors_source = clean, "file"
        end
        if best && (ba = best.fields.authors) && !(theirs = Clean.authors(ba)).empty?
          if Clean.unknown_authors?(authors)
            authors, authors_source = theirs, best.source
          elsif authors.size == theirs.size && authors.zip(theirs).all? { |m, o| Text.key(m) == Text.key(o) || fuller?(o, m) } &&
                authors.zip(theirs).any? { |m, o| better_form?(o, m) || fuller?(o, m) }
            authors, authors_source = theirs, best.source
          elsif best.sure && Score.authors(authors, theirs) < 0.5
            authors, authors_source = theirs, best.source
          end
        end
        set.call("authors", JSON.parse(authors.to_json), authors_source) unless authors_source.empty?
        # calibre sorts new authors itself; a broken sort of kept authors is fixed
        if authors_source.empty? && AuthorSort.wrong?(book)
          set.call("authorSort", JSON::Any.new(AuthorSort.for(book.authors)), "rules")
        end

        # series from the file name ("Author - Series 03 - Title")
        if guess && (s = guess.series) && book.series.nil?
          set.call("series", JSON::Any.new(s), guess.source)
          guess.series_index.try { |i| set.call("seriesIndex", JSON::Any.new(i), guess.source) }
        end

        # isbn: from the OPF, else the sure match, else an edition that
        # matches very well
        if book.identifiers["isbn"]?.try { |i| Isbn.normalize(i) }.nil?
          if file && (fi = file.isbn)
            set.call("isbn", JSON::Any.new(fi), "file")
          elsif sure && (si = sure.fields.isbn || sure.by_isbn)
            set.call("isbn", JSON::Any.new(si), sure.source)
          elsif (c = accepted.find { |x| x.edition && x.score >= HIGH && x.fields.isbn }) && (ci = c.fields.isbn)
            set.call("isbn", JSON::Any.new(ci), c.source)
          end
        end

        fill(book, file, accepted, sure, "publisher", set) { |r, c| c.nil? || c.edition ? r.publisher : nil }
        fill(book, file, accepted, sure, "pubdate", set) { |r, c| c.nil? || c.edition ? r.pubdate : nil }
        fill(book, file, accepted, sure, "languages", set) { |r, _| r.languages.try { |l| l.empty? ? nil : l } }
        fill(book, file, accepted, nil, "comments", set) { |r, _| r.comments.presence }
        if book.series.nil? && changes.none? { |c| c.field == "series" }
          src = file.try { |f| f.series ? {f, "file"} : nil } || accepted.find(&.fields.series).try { |c| {c.fields, c.source} }
          if src && (s = src[0].series)
            set.call("series", JSON::Any.new(s), src[1])
            src[0].series_index.try { |i| set.call("seriesIndex", JSON::Any.new(i), src[1]) }
          end
        end

        if !has_cover && (c = accepted.find(&.fields.cover_url)) && (url = c.fields.cover_url)
          changes << Change.new("cover", JSON::Any.new(nil), JSON::Any.new(url), c.source)
        end
        changes
      end

      # Fills a missing field from the file, else the best candidate having
      # it; replaces a different value only on a sure match
      private def self.fill(book, file, accepted, sure, field, set, &pick : Record, Candidate? -> String | Array(String) | Nil)
        current = value(book, field)
        empty = current.raw.nil? || current.as_a?.try(&.empty?)
        if empty
          if file && (v = pick.call(file, nil))
            return set.call(field, JSON.parse(v.to_json), "file")
          end
          accepted.each do |c|
            if v = pick.call(c.fields, c)
              return set.call(field, JSON.parse(v.to_json), c.source)
            end
          end
        elsif sure && (v = pick.call(sure.fields, sure)) && different?(field, current, v)
          set.call(field, JSON.parse(v.to_json), sure.source)
        end
      end

      # clearly different, not just spelled differently
      private def self.different?(field, current : JSON::Any, v) : Bool
        case field
        when "pubdate"
          current.as_s?.try { |c| (c[0, 4].to_i - v.as(String)[0, 4].to_i).abs > 1 } || false
        when "publisher"
          Text.similarity(current.as_s? || "", v.as(String)) < 0.3
        when "languages"
          (current.as_a.map(&.as_s) & v.as(Array(String))).empty?
        else
          false
        end
      end

      def self.same?(field : String, a : JSON::Any, b : JSON::Any) : Bool
        return true if a == b
        if field == "pubdate" && (x = a.as_s?) && (y = b.as_s?)
          # calibre may store the day before or after (time zones)
          dx, dy = Time.parse_utc(Dates.full(x), "%F"), Time.parse_utc(Dates.full(y), "%F") rescue return x == y
          return (dx - dy).abs <= 1.day
        end
        if field == "seriesIndex" && (x = a.raw.as?(Float64 | Int64)) && (y = b.raw.as?(Float64 | Int64))
          return x.to_f == y.to_f
        end
        false
      end

      def self.title_messy?(t : String) : Bool
        Clean.junk?(t) || Clean.broken_case?(t)
      end

      # "J. R. R. Tolkien" for "Tolkien": every word of mine, and more
      def self.fuller?(theirs : String, mine : String) : Bool
        t, m = Text.tokens(theirs), Text.tokens(mine)
        t.size > m.size && m.last? == t.last? && m.all? { |w| t.includes?(w) }
      end

      # proper case beats broken case, accents beat none, "Le Guin" beats "LeGuin"
      def self.better_form?(theirs : String, mine : String) : Bool
        return false if theirs == mine || Clean.broken_case?(theirs)
        return true if Clean.broken_case?(mine)
        return Text.diacritics(theirs) > Text.diacritics(mine) if Text.diacritics(theirs) != Text.diacritics(mine)
        theirs.count(' ') > mine.count(' ') && !theirs.includes?(',')
      end
    end

    # Groups author spellings that only differ in case, accents,
    # punctuation, spacing of initials or "Last, First"
    module Authors
      def self.key(name : String) : String
        Text.key(Clean.invert(name))
      end

      # {canonical, [variants to rename]} for every group with more than one
      # spelling. counts: books per name; sourced: names confirmed by an
      # online source, they win over the plain count.
      def self.groups(counts : Hash(String, Int32), sourced = Set(String).new) : Array({String, Array(String)})
        counts.keys.group_by { |n| key(n) }.compact_map do |k, names|
          next if names.size < 2 || k.empty?
          best = names.max_by do |n|
            {Clean.broken_case?(n) ? 0 : 1, n.includes?(',') ? 0 : 1, sourced.includes?(n) ? 1 : 0,
             counts[n], Text.diacritics(n), n.count(' '), n.count('.')}
          end
          {best, (names - [best]).sort}
        end.sort_by(&.[0])
      end
    end
  end
end
