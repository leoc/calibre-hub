require "levenshtein"
require "./meta_rules"

module CalibreHub
  module Meta
    # The words of a text, to look up a title or a person in it: folded like
    # every comparison here, words broken at the end of a line put together
    class Words
      getter list : Array(String)

      def initialize(text : String)
        @list = Text.tokens(text.gsub(/(?:(?<=\p{Ll})[-‐]\s*\n\s*(?=\p{Ll})|(?<=\p{Lu})[-‐]\s*\n\s*(?=\p{Lu}))/, ""))
        @at = Hash(String, Array(Int32)).new
        @list.each_with_index { |w, i| (@at[w] ||= [] of Int32) << i }
      end

      def empty? : Bool
        @list.empty?
      end

      def size : Int32
        @list.size
      end

      def has?(word : String) : Bool
        @at.has_key?(word)
      end

      # the words one after another
      def phrase?(words : Array(String)) : Bool
        return false if words.empty?
        (@at[words.first]? || [] of Int32).any? do |p|
          words.each_with_index.all? { |w, i| @list[p + i]? == w }
        end
      end

      # the words of weight close together, one of five may miss: a line
      # break of a title page, an OCR error. "of" and "the" prove nothing
      # ("Secrets of software quality" isn't in every text on software quality).
      def near?(words : Array(String)) : Bool
        wanted = words.reject { |w| w.size < 3 || Clean::SMALL.includes?(w) }.to_set
        return false if wanted.size < 3
        need = (wanted.size * 4 + 4) // 5
        rarest = wanted.compact_map { |w| @at[w]? }.min_by?(&.size) || return false
        rarest.any? do |p|
          from = {p - 2 * wanted.size, 0}.max
          (@list[from, 4 * wanted.size + 1].to_set & wanted).size >= need
        end
      end

      # the first words only: a title page
      def first(count : Int32) : Words
        Words.new(@list.first(count).join(' '))
      end

      # first name or initial within a few words around the surname: "Donald
      # E. Knuth", "KNUTH, DONALD". A surname alone can be anybody.
      def person?(name : String) : Bool
        words = Text.tokens(Clean.invert(name))
        surname = words.pop? || return false
        # "Voltaire"
        return surname.size >= 5 && has?(surname) if words.empty?
        first = words.first
        (@at[surname]? || [] of Int32).any? do |p|
          from = {p - 4, 0}.max
          around = @list[from, p - from] + (@list[p + 1, 3]? || [] of String)
          around.any? { |w| w == first || (w.size == 1 && w[0] == first[0]) || (first.size == 1 && w[0] == first[0]) }
        end
      end
    end

    # Does a catalog record fit a book's first pages? Its title or one of its
    # authors appears there. An author is enough: a German book doesn't have
    # the English catalog title of its ISBN ("Der Wüstenplanet", "Dune"), but
    # the name of Frank Herbert. strict (an ISBN from the last pages or a
    # list of books): only the title counts, the same author wrote the other
    # books there, and one word is not enough.
    module Fit
      record Result, title : Bool, authors : Bool do
        def any? : Bool
          title || authors
        end

        def both? : Bool
          title && authors
        end
      end

      def self.check(r : Record, words : Words) : Result
        Result.new(r.title.try { |t| title?(t, words) } || false,
          CrossCheck.people(r).any? { |a| words.person?(a) })
      end

      def self.title?(title : String, words : Words, strict = false) : Bool
        list = Text.tokens(Text.main_title(title))
        return false if list.empty?
        return false if list.size == 1 && (strict || list.first.size < 4)
        words.phrase?(list) || (!strict && list.size >= 3 && words.near?(list))
      end

      # words of a book's beginning that a title page and its verso hold
      TITLE_PAGE = 300

      def self.title_page?(title : String, words : Words) : Bool
        title?(title, words.first(TITLE_PAGE))
      end
    end

    # The persons of a book against a catalog's. A record often names fewer
    # people than the book has, so it adds and spells, it doesn't remove:
    # only what is no person goes (a narrator, a publisher, "et al.").
    module People
      # what isn't part of a name when names are compared
      SUFFIXES = Set{"jr", "sr", "ii", "iii", "md", "phd", "dr", "prof", "sj"}
      NARRATOR = /\((?:narrator|translator|illustrator|reader)\)/i

      def self.tokens(name : String) : Array(String)
        Text.tokens(Clean.invert(name)).reject { |w| SUFFIXES.includes?(w) }
      end

      # The persons in an author field: "J. Silverman (Springer", "1986) WW",
      # "Mark. Stamp", "Barry, S. Davis", "et a." as an import left them
      def self.clean(list : Array(String)) : Array(String)
        list.reject(&.matches?(NARRATOR)).flat_map { |a| pieces(a) }.reject do |a|
          a.empty? || a.matches?(/\Aet\.?\s+al?\.?\z/i) || FileName.bad_author?(a)
        end
      end

      private def self.pieces(author : String) : Array(String)
        author.split(/\s+[-–]\s+/).flat_map do |p|
          s = FileName.clean_author(p.sub(/\s*\(.*\z/, ""))
          s = s.gsub(/(?<=\p{L}{2})\.(?=\s)/, "").sub(/,?\s+et\.?\s+al?\.?\z/i, "").strip
          parts = s.split(/\s*,\s*/).reject(&.empty?)
          parts.size >= 2 && parts.all?(&.includes?(' ')) ? parts : [s]
        end
      end

      # The same person, loosely: initials, a middle name, the order of the
      # names, a typing error in a long surname. "Arthur" isn't "Arnold".
      def self.same?(a : String, b : String) : Bool
        x, y = tokens(a), tokens(b)
        return false if x.empty? || y.empty?
        return true if x.to_set == y.to_set
        if x.size == 1 || y.size == 1
          one, other = x.size == 1 ? {x, y} : {y, x}
          return other.includes?(one.first) || other.join.ends_with?(one.first)
        end
        return false unless surname?(x.last, y.last)
        f, g = x.first, y.first
        f == g || ((f.size == 1 || g.size == 1) && f[0] == g[0])
      end

      private def self.surname?(a : String, b : String) : Bool
        a == b || (a.size >= 6 && a[0] == b[0] && Levenshtein.distance(a, b) <= 2)
      end

      # one entry of the book holds this person and more: "Marco Cesati
      # Daniel P. Bovet", "Attorneys Amy DelPo"
      private def self.inside?(entry : String, person : String) : Bool
        mine, theirs = tokens(entry), tokens(person)
        theirs.size >= 2 && mine.size > theirs.size && theirs.all? { |w| mine.includes?(w) }
      end

      # {the authors, did the record know any of the book's}. The book's
      # order and persons, the record's fuller spelling, then the persons
      # only the record has. A record that knows nobody of the book changes
      # nothing: it may name a contributor of an edited volume.
      def self.merge(own : Array(String), theirs : Array(String), words : Words? = nil) : {Array(String), Bool}
        own = unique(own).reject do |a|
          tokens(a).size < 2 && words.try { |w| !tokens(a).any? { |t| w.has?(t) } } && !theirs.any? { |t| same?(a, t) }
        end
        return {theirs, true} if own.empty?
        return {own.map { |a| spelled(a) }, true} if theirs.empty?
        known = own.any? { |a| theirs.any? { |t| same?(a, t) || inside?(a, t) } }
        return {own.map { |a| spelled(a) }, false} unless known
        merged = own.flat_map do |a|
          inner = theirs.select { |t| inside?(a, t) }
          next inner if inner.size >= 2
          # "Medieval Studies Lisa Maurizio", but "Richard D. Booker" stays
          next inner if inner.size == 1 && (tokens(a) - tokens(inner.first)).any? { |w| w.size > 1 }
          match = theirs.find { |t| same?(a, t) }
          [match ? better(a, match, words) : spelled(a)]
        end
        {unique(merged + theirs), true}
      end

      # "TERESA D. DERENIAK"
      private def self.spelled(name : String) : String
        return name unless name == name.upcase && name.count(&.letter?) > 3
        name.split(' ').map { |w| w.size <= 2 || w.includes?('.') ? w : w.capitalize }.join(' ')
      end

      private def self.unique(list : Array(String)) : Array(String)
        kept = [] of String
        list.each do |a|
          if at = kept.index { |k| same?(k, a) }
            kept[at] = a if tokens(a).size > tokens(kept[at]).size
          else
            kept << a
          end
        end
        kept
      end

      # the book's spelling unless the record's says more: a surname or an
      # initial, capitals, a name the text spells the record's way
      private def self.better(mine : String, theirs : String, words : Words?) : String
        a, b = tokens(mine), tokens(theirs)
        return theirs if a.size == 1 || Clean.broken_case?(mine)
        return theirs if a.first.size == 1 && (b.first.size > 1 || b.size > a.size)
        return theirs if a.last != b.last && words.try { |w| w.person?(theirs) && !w.person?(mine) }
        mine
      end
    end
  end
end
