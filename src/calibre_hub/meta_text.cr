require "./meta_rules"

module CalibreHub
  module Meta
    # The words of a text, to look up a title or a person in it: folded like
    # every comparison here, words broken at the end of a line put together
    class Words
      getter list : Array(String)

      def initialize(text : String)
        @list = Text.tokens(text.gsub(/(?<=\p{L})[-‐]\s*\n\s*(?=\p{Ll})/, ""))
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

      # at least three quarters of the words close together: a line break
      # of a title page, an "and" more or less, an OCR error
      def near?(words : Array(String)) : Bool
        wanted = words.to_set
        need = (wanted.size * 3 + 3) // 4
        rarest = wanted.compact_map { |w| @at[w]? }.min_by?(&.size) || return false
        rarest.any? do |p|
          from = {p - 2 * wanted.size, 0}.max
          (@list[from, 4 * wanted.size + 1].to_set & wanted).size >= need
        end
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
        words.phrase?(list) || (list.size >= 3 && words.near?(list))
      end
    end
  end
end
