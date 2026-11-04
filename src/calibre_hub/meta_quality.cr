require "./book"
require "./meta_filename"

module CalibreHub
  module Meta
    # How much of a portion needs another look: per book why its title or
    # authors look wrong, the same rules the import and the repair decide
    # by (FileName), so a portion can be measured before and after. Books
    # with an ISBN come from a catalog: their authors count as checked unless
    # they are nobody at all (FileName.no_person?), a publisher named as author
    # there is a catalog's choice. Standards have their issuing body as author.
    module Quality
      REASONS = %w(unknownAuthor notAPerson publisherAuthor swappedPair pathTitle titleSaysNothing leftoverTitle fileNameTitle unsure)

      def self.reasons(book : Book) : Array(String)
        return [] of String if book.tags.includes?(Norms::TAG)
        list = [] of String
        checked = !book.identifiers["isbn"]?.nil?
        if FileName.swapped?(book.title, book.authors)
          list << "swappedPair"
        elsif Clean.unknown_authors?(book.authors)
          list << "unknownAuthor"
        elsif checked
          # no catalog has "Cumulative Index" for an author
          list << "notAPerson" if book.authors.any? { |a| FileName.no_person?(a) }
        else
          bad = book.authors.select { |a| FileName.bad_author?(a) && !Clean.unknown_author?(a) }
          list << "publisherAuthor" if bad.any? { |a| FileName.publisher_name?(a) }
          list << "notAPerson" if bad.any? { |a| !FileName.publisher_name?(a) } || book.authors.any? { |a| Clean.unknown_author?(a) }
        end
        if FileName.path_title?(book.title)
          list << "pathTitle"
        elsif list.includes?("swappedPair")
          # the title is the author's name, nothing else is wrong with it
        elsif FileName.bad_title?(book.title)
          list << "titleSaysNothing"
        elsif FileName.leftover_title?(book)
          list << "leftoverTitle"
        elsif file_name?(book.title)
          list << "fileNameTitle"
        end
        list << "unsure" if book.tags.includes?(Meta.unsure_tag)
        list
      end

      # one word out of a file name: "haskell-beats-C", "grammatik01einschub",
      # "CompilerConstruction1", "8760-hours-v2"
      def self.file_name?(title : String) : Bool
        return false if title.includes?(' ')
        title.matches?(/\A\p{Ll}/) || title.matches?(/[-_.]\p{L}.*[-_.]/) || title.matches?(/\p{Ll}\p{Lu}.*\d\z|\p{Ll}\d+\z/)
      end
    end
  end
end
