module CalibreHub
  module Meta
    # How sure a decision about a book is, 0..100: one value for its title,
    # one for its authors, the book gets the lower (book). The table is the
    # only place with these numbers, so it can be recalibrated with the
    # sample checks (ImportRepair#quality shows the measured hit rate per
    # band).
    module Confidence
      # the ISBN in the book, the catalog record fits the book's text: title
      # and author appear in it (ISBN_BOTH), a field that doesn't ISBN_ONE
      ISBN_BOTH = 98
      ISBN_ONE  = 90
      # EPUB, OPF, calibre (a PDF that fits its text or name) and the file
      # name: it fits, or says nothing
      META_NAME    = 90
      META_NOTHING = 75
      # two catalogs agree and the name fits
      CATALOGS = 85
      # a clear "Author - Title" name: the author in full, a surname only
      NAME_FULL    = 80
      NAME_SURNAME = 70
      # a catalog's sure or very good match with one reading of an unclear name
      CATALOG_NAME = 70
      # what the book had, kept: nothing speaks against it, nothing for it
      KEPT = 60
      # one catalog alone, the model on an unclear name, a name nobody could
      # decide or without an author, nothing confirmed with a title that
      # says nothing
      CATALOG = 50
      MODEL   = 40
      UNCLEAR = 30
      NOTHING = 10
      # a field edited by hand is what the book is called
      HAND = 100

      # contradictions subtract: the metadata and the name are another book,
      # an ISBN's record and the name, the text and what the name says
      META_AGAINST_NAME = 25
      ISBN_AGAINST_NAME = 10
      TEXT_AGAINST_NAME = 15

      # >= BULK can be accepted in bulk, >= REVIEW is reviewed one by one,
      # below nothing is written automatically
      BULK   = 90
      REVIEW = 60
      # the highest value of a book with an ISBN conflict: never in bulk
      CONFLICT = BULK - 1

      BANDS = %w(bulk review unsure)

      def self.book(title : Int32, authors : Int32) : Int32
        {title, authors}.min
      end

      def self.band(value : Int32) : String
        return "bulk" if value >= BULK
        value >= REVIEW ? "review" : "unsure"
      end
    end
  end
end
