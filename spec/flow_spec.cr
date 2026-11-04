require "spec"
require "http/server"
require "../src/calibre_hub/meta_flow"
require "../src/calibre_hub/meta_quality"

private alias Meta = CalibreHub::Meta
private alias Confidence = CalibreHub::Meta::Confidence
private alias Flow = CalibreHub::Meta::Flow

private def book(title : String, authors : Array(String), isbn : String? = nil, tags = [] of String) : CalibreHub::Book
  CalibreHub::Book.new(id: 1_i64, title: title, authors: authors, author_sort: Meta::AuthorSort.for(authors),
    tags: tags, series: nil, series_index: nil, formats: ["PDF"], last_modified: Time::UNIX_EPOCH,
    timestamp: nil, pubdate: nil, rating: nil, publisher: nil,
    identifiers: isbn ? {"isbn" => isbn} : {} of String => String,
    languages: [] of String, comments: nil, custom: {} of String => JSON::Any)
end

private def input(b : CalibreHub::Book, name : String? = nil, front = "", record = Meta::Record.new, format = "PDF", back = "", ocr = false) : Flow::Input
  i = Flow::Input.new(b, ->(field : String) { Meta::Merge.value(b, field).as(JSON::Any?) }, name)
  i.info = Meta::FileMeta::Info.new(record, [] of String, nil, front, back, format, ocr)
  i
end

# a catalog that knows these ISBNs
private def catalog(records : Hash(String, Meta::Record), source = "openlibrary") : Flow::Lookup
  ->(isbn : String) do
    r = records[isbn]?
    r ? [Meta::Candidate.new(source, r, by_isbn: isbn)] : [] of Meta::Candidate
  end
end

private def changed(d : Flow::Decision?) : Hash(String, JSON::Any)
  d.not_nil!.changes.to_h { |c| {c.field, c.new} }
end

private def verdict(confirmed : Bool, sources = ["openlibrary", "dnb"]) : Meta::FileName::Checker
  ->(_b : CalibreHub::Book, g : Meta::Guess) do
    Meta::Verdict.new(confirmed, g.title, ["Tom DeMarco"], sources.first, sources).as(Meta::Verdict?)
  end
end

DUNE     = "9783453317178"
WARREN   = "9780201914658"
PAGES_DE = "Frank Herbert\nDer Wüstenplanet\nRoman\nDeutsche Übersetzung\n© 1965 Frank Herbert\nAlle Rechte vorbehalten\nISBN 978-3-453-31717-8\n"

describe Meta::Isbn do
  it "takes a label with a hyphen and an OCR'd line" do
    Meta::Isbn.scan("REPORT NO ISBN-1-85000-667-9 PUB").should eq ["9781850006671"]
    Meta::Isbn.scan("ISBN 10: 0-387-98479-8").should eq ["9780387984797"]
    Meta::Isbn.to10("9780387984797").should eq "0387984798"
    Meta::Isbn.to10("9791034900000").should be_nil
  end

  it "prefers the copyright page, labelled, over everything else" do
    text = "Some bare number 9780387984797 here.\n" + "x " * 400 + "Copyright 2001 by Acme.\nISBN 978-0-201-91465-8\n"
    found = Meta::Isbn.found(text)
    found.map(&.isbn).should eq ["9780201914658", "9780387984797"]
    found.first.copyright.should be_true
  end

  it "doesn't let ads, lists and last pages win" do
    list = "Also by this author\nA: ISBN 978-0-387-98479-7\nB: ISBN 978-0-201-91465-8\n"
    found = Meta::Isbn.found(list)
    found.all?(&.strict).should be_true
    back = "Pragmatic titles: ISBN: 9781680507195\n"
    Meta::Isbn.found("nothing", back).first.strict.should be_true
    # hardback and paperback on the copyright page aren't a list
    print = "Copyright 2000\nISBN 0 521 63235 8 hardback\nISBN 0 521 63503 9 paperback\n"
    Meta::Isbn.found(print).none?(&.strict).should be_true
  end
end

describe Meta::Fit do
  words = Meta::Words.new("THE ART OF\nCOMPUTER PROGRAM-\nMING\nVolume 1\nDONALD E. KNUTH\nReading, Massachusetts\nThanks to Peter Smith")

  it "finds a title and a person in the text" do
    Meta::Fit.title?("The Art of Computer Programming", words).should be_true
    Meta::Fit.title?("The Art of Computer Programming: Fundamental Algorithms", words).should be_true
    Meta::Fit.title?("Compilers", words).should be_false
    words.person?("Donald Knuth").should be_true
    words.person?("D. E. Knuth").should be_true
    words.person?("Knuth, Donald").should be_true
    words.person?("Peter Smith").should be_true
    # a surname isn't enough
    words.person?("Adam Smith").should be_false
    Meta::Words.new("Candide par Voltaire").person?("Voltaire").should be_true
  end

  it "keeps a word from counting in a list of books" do
    Meta::Fit.title?("Dune", Meta::Words.new("Dune Messiah"), strict: true).should be_false
    Meta::Fit.title?("Dune", Meta::Words.new("Dune Messiah")).should be_true
  end
end

describe Meta::Score do
  record = Meta::Record.new(title: "Dune", authors: ["Frank Herbert"], isbn: DUNE)
  other = Meta::Record.new(title: "Mathematical modelling of estuarine physics", authors: ["J. Sündermann"], isbn: DUNE)
  guess = [Meta::Guess.new("Der Wüstenplanet", ["Frank Herbert"])]

  it "takes a translation by its author in the text, not its catalog title" do
    c = Meta::Candidate.new("openlibrary", record, by_isbn: DUNE)
    Meta::Score.rank([c], guess, [] of String, [DUNE], Meta::Words.new(PAGES_DE))
    c.sure.should be_true
    c.own_title.should be_false
  end

  it "finds an ISBN filed under another book by the text" do
    c = Meta::Candidate.new("openlibrary", other, by_isbn: DUNE)
    Meta::Score.rank([c], guess, [] of String, [DUNE], Meta::Words.new(PAGES_DE))
    c.sure.should be_false
  end

  it "falls back to the titles without a text" do
    Meta::Score.other_book?(guess, record).should be_true
    c = Meta::Candidate.new("openlibrary", record, by_isbn: DUNE)
    Meta::Score.rank([c], guess, [] of String, [DUNE])
    c.sure.should be_false
  end
end

describe Meta::Confidence do
  it "has one band per value" do
    {98 => "bulk", 90 => "bulk", 89 => "review", 60 => "review", 59 => "unsure", 10 => "unsure"}.each do |v, band|
      Confidence.band(v).should eq band
    end
    Confidence.book(98, 70).should eq 70
  end
end

describe Meta::Flow do
  hackers = Meta::Record.new(title: "Hacker's Delight", authors: ["Henry S. Warren"], isbn: WARREN)
  text = "Hacker's Delight\nHenry S. Warren, Jr.\nCopyright 2003 by Pearson\nISBN 0-201-91465-4\n"

  describe "level 1, an ISBN in the book" do
    it "wins over everything, also the file name" do
      b = book("Addison Wesley - Hacker's Delight - Ripped by Caudex 2003", ["Unknown"])
      i = input(b, "Warren - Something Else Entirely (AW, 2003).pdf", text)
      i.by_isbn = catalog({WARREN => hackers})
      d = Flow.decide(i).not_nil!
      d.level.should eq 1
      d.source.should eq "openlibrary"
      d.isbn.should eq WARREN
      d.isbn_source.should eq "text"
      {d.title, d.authors}.should eq({98, 98})
      changed(d)["title"].should eq "Hacker's Delight"
      changed(d)["authors"].should eq JSON.parse(%(["Henry S. Warren"]))
      changed(d)["isbn"].should eq WARREN
      changed(d)["publisher"].should eq "Addison-Wesley"
    end

    it "keeps a translation's title and takes the author and the ISBN (#8528)" do
      b = book("Der Wüstenplanet", ["Unknown"])
      i = input(b, "Der Wüstenplanet.pdf", PAGES_DE)
      i.by_isbn = catalog({DUNE => Meta::Record.new(title: "Dune", authors: ["Frank Herbert"], isbn: DUNE)})
      d = Flow.decide(i).not_nil!
      d.level.should eq 1
      changed(d).has_key?("title").should be_false
      changed(d)["authors"].should eq JSON.parse(%(["Frank Herbert"]))
      {d.title, d.authors, d.confidence}.should eq({90, 98, 90})
    end

    it "takes the record's title when the book's says nothing" do
      b = book("8508 Fm Frame", ["Jasmine Fradique"])
      i = input(b, nil, "Vegetarian Nutrition\nJoan Sabate\n© 2001 CRC\nISBN 0-387-98479-8\n")
      i.by_isbn = catalog({"9780387984797" => Meta::Record.new(title: "Vegetarian Nutrition", authors: ["Joan Sabaté"])})
      changed(Flow.decide(i))["title"].should eq "Vegetarian Nutrition"
    end

    it "doesn't take a record that doesn't fit the text" do
      b = book("Hacker's Delight", ["Henry S. Warren"])
      i = input(b, nil, "Hacker's Delight\nHenry S. Warren\nISBN 0-201-91465-4\n")
      i.by_isbn = catalog({WARREN => Meta::Record.new(title: "Mathematical modelling of estuarine physics", authors: ["J. Sündermann"])})
      Flow.decide(i).not_nil!.level.should_not eq 1
    end

    it "doesn't let the author's other book in the last pages win" do
      other = "9781680507195"
      b = book("Programming Phoenix", ["Unknown"])
      i = input(b, "Programming Phoenix - Chris McCord.pdf", "Programming Phoenix\nChris McCord\nBruce Tate\n",
        back: "Also by Chris McCord: Metaprogramming Elixir\nISBN: 9781680507195\n")
      i.by_isbn = catalog({other => Meta::Record.new(title: "Metaprogramming Elixir", authors: ["Chris McCord"])})
      Flow.decide(i).not_nil!.level.should_not eq 1
    end

    it "keeps the book's form of a title and only persons of the text, the name's first" do
      b = book("Classic Shell Scripting @Team DDU", ["Unknown"])
      i = input(b, "Beebe - Classic Shell Scripting @Team DDU.pdf", "Classic Shell Scripting\nArnold Robbins and Nelson H. F. Beebe\nISBN 0-201-91465-4\n")
      i.by_isbn = catalog({WARREN => Meta::Record.new(title: "Classic shell scripting", authors: ["Arnold Robbins", "Nelson H. F. Beebe", "Cambridge India"])})
      d = Flow.decide(i).not_nil!
      changed(d)["title"].should eq "Classic Shell Scripting"
      changed(d)["authors"].should eq JSON.parse(%(["Nelson H. F. Beebe", "Arnold Robbins"]))
    end

    it "says when the text came from OCR, and subtracts a name that says another book" do
      b = book("Something", ["Unknown"])
      i = input(b, "Knuth - The Art of Computer Programming.pdf", text, ocr: true)
      i.by_isbn = catalog({WARREN => hackers})
      d = Flow.decide(i).not_nil!
      d.isbn_source.should eq "ocr"
      d.confidence.should eq 88
    end

    it "never overwrites an ISBN, the contradiction goes to the review" do
      b = book("Hacker's Delight", ["Henry S. Warren"], isbn: "9780387984797")
      i = input(b, nil, text)
      i.by_isbn = catalog({WARREN => hackers})
      d = Flow.decide(i).not_nil!
      changed(d).has_key?("isbn").should be_false
      d.notes.should eq [Flow::Note.new("isbnConflict", WARREN)]
      d.isbn.should eq "9780387984797"
      d.confidence.should eq Confidence::CONFLICT
      d.band.should eq "review"
    end

    it "sends the same ISBN on two books to the review" do
      b = book("Hacker's Delight", ["Henry S. Warren"])
      i = input(b, nil, text)
      i.by_isbn = catalog({WARREN => hackers})
      i.owners = ->(_isbn : String) { [1_i64, 7_i64] }
      d = Flow.decide(i).not_nil!
      changed(d).has_key?("isbn").should be_false
      d.notes.should eq [Flow::Note.new("duplicateIsbn", WARREN, [7_i64])]
      d.band.should eq "review"
    end

    it "takes the ISBN of the file's metadata and of the book when the pages have none" do
      b = book("Hacker's Delight", ["Unknown"], isbn: WARREN)
      i = input(b, nil, "Hacker's Delight\nHenry S. Warren\n")
      i.by_isbn = catalog({WARREN => hackers})
      d = Flow.decide(i).not_nil!
      {d.level, d.isbn_source}.should eq({1, "calibre"})
      b = book("Hacker's Delight", ["Unknown"])
      i = input(b, nil, "Hacker's Delight\nHenry S. Warren\n", Meta::Record.new(isbn: WARREN))
      i.by_isbn = catalog({WARREN => hackers})
      Flow.decide(i).not_nil!.isbn_source.should eq "opf"
    end
  end

  describe "level 2, the file's metadata" do
    epub = Meta::Record.new(title: "Zwischen Ich und Du", authors: ["Angelika Krebs"])

    it "trusts an EPUB that fits the name" do
      b = book("Zwischen Ich und Du", ["Angelika Krebs"])
      d = Flow.decide(input(b, "Krebs - Zwischen Ich und Du.epub", record: epub, format: "EPUB")).not_nil!
      {d.level, d.how, d.confidence}.should eq({2, "file", 90})
      d.changes.should be_empty
    end

    it "is less sure with a name that says nothing, and with one that says another book" do
      b = book("Zwischen Ich und Du", ["Angelika Krebs"])
      Flow.decide(input(b, "chap01.epub", record: epub, format: "EPUB")).not_nil!.confidence.should eq 75
      Flow.decide(input(b, "Kant - Kritik der reinen Vernunft.epub", record: epub, format: "EPUB")).not_nil!.confidence.should eq 65
    end

    it "takes a PDF's metadata only where they fit the text or the name" do
      pdf = Meta::Record.new(title: "Vegetarian Nutrition", authors: ["Joan Sabate"])
      b = book("8508 Fm Frame", ["Unknown"])
      d = Flow.decide(input(b, "Vegetarian Nutrition - J. Sabate.pdf", record: pdf)).not_nil!
      {d.level, d.confidence}.should eq({2, 90})
      changed(d)["title"].should eq "Vegetarian Nutrition"
      # no fit: the name reads
      d = Flow.decide(input(b, "Sabate - Data Mining Handbook.pdf", record: pdf)).not_nil!
      d.level.should eq 3
      changed(d)["title"].should eq "Data Mining Handbook"
      # fits the text, an author that doesn't goes
      own = Meta::Record.new(title: "Vegetarian Nutrition", authors: ["Jane Doe"])
      d = Flow.decide(input(b, "scan0001.pdf", "Vegetarian Nutrition\nJoan Sabate\n" + "word " * 200, own)).not_nil!
      d.level.should eq 2
      changed(d).has_key?("authors").should be_false
    end

    it "doesn't take junk from a PDF's info dict" do
      {"Click here to log on", "Untitled Document", "8508 Fm Frame", "test"}.each do |t|
        Meta::FileMeta.pdf_info("Title: #{t}\n").title.should be_nil
      end
      {"Administrator", "Besitzer", "Danny", "Jasmine Fradique"}.each do |a|
        Meta::FileMeta.pdf_info("Author: #{a}\n").authors.should be_nil
      end
    end

    it "cleans an edition from the title" do
      pdf = Meta::Record.new(title: "Guidebook to Mechanism in Organic Chemistry (6th Edition)", authors: ["Peter Sykes (1986), scanned by Nicodem"])
      b = book("Sykes", ["Guidebook to Mechanism"])
      d = Flow.decide(input(b, "Sykes - Guidebook to Mechanism in Organic Chemistry 6e (Longman, 1985).pdf", record: pdf)).not_nil!
      changed(d)["title"].should eq "Guidebook to Mechanism in Organic Chemistry"
    end

    it "strips a list code from the title" do
      mobi = Meta::Record.new(title: "HIT04 - So Long, and Thanks for All the Fish", authors: ["Douglas Adams"])
      b = book("HIT04 - So Long, and Thanks for All the Fish", ["Douglas Adams"])
      d = Flow.decide(input(b, "HIT04 - So Long, and Thanks for All the Fish - Douglas Adams.mobi", record: mobi, format: "MOBI")).not_nil!
      changed(d)["title"].should eq "So Long, and Thanks for All the Fish"
    end

    it "fills a missing author from two catalogs that agree, else goes to the review" do
      pdf = Meta::Record.new(title: "Peopleware")
      b = book("Peopleware", ["Unknown"])
      i = input(b, "Peopleware.pdf", record: pdf)
      i.checker = verdict(true)
      d = Flow.decide(i).not_nil!
      {d.level, d.source, d.authors}.should eq({2, "openlibrary", 85})
      changed(d)["authors"].should eq JSON.parse(%(["Tom DeMarco"]))
      i.checker = verdict(false, ["openlibrary"])
      d = Flow.decide(i).not_nil!
      d.confidence.should eq 50
      changed(d).has_key?("authors").should be_false
      changed(d)["tags"].should eq JSON.parse(%(["auto-unsicher"]))
      changed(d)["candidate"]["authors"].should eq JSON.parse(%(["Tom DeMarco"]))
    end

    it "stands by what calibre has for a book without a file name" do
      b = book("The Art of UNIX Programming", ["Eric S. Raymond"])
      d = Flow.decide(input(b)).not_nil!
      {d.level, d.how, d.confidence}.should eq({2, "calibre", 75})
      d.changes.should be_empty
    end
  end

  describe "level 3, the file name" do
    it "gives a clear name its value" do
      b = book("Carr", ["Formulas", "Theorems in Pure Mathematics 2e (Chelsea, 1970)"])
      d = Flow.decide(input(b, "Carr - Formulas and Theorems in Pure Mathematics 2e (Chelsea, 1970).djvu")).not_nil!
      {d.level, d.how, d.confidence}.should eq({3, "name", 70})
      b = book("Dune", ["Unknown"])
      Flow.decide(input(b, "Frank Herbert - Dune.pdf")).not_nil!.confidence.should eq 80
    end

    it "subtracts a text that knows neither title nor author" do
      b = book("Dune", ["Unknown"])
      d = Flow.decide(input(b, "Frank Herbert - Dune.pdf", "word " * 200)).not_nil!
      d.confidence.should eq 65
    end

    it "writes nothing below the threshold, but says what it knows" do
      b = book("Der Name", ["Unknown"])
      i = input(b, "Peopleware.pdf")
      i.checker = verdict(false, ["openlibrary"])
      d = Flow.decide(i).not_nil!
      d.confidence.should eq 50
      changed(d).keys.sort.should eq ["candidate", "tags"]
    end

    it "takes two catalogs that agree on a reading without an author" do
      b = book("Peopleware", ["Unknown"])
      i = input(b, "13 - Peopleware - Productive Projects and Teams.pdf")
      i.checker = verdict(true)
      d = Flow.decide(i).not_nil!
      {d.level, d.confidence}.should eq({3, 85})
      changed(d)["authors"].should eq JSON.parse(%(["Tom DeMarco"]))
    end

    it "is at 40 with the model, at 10 with a title that says nothing" do
      b = book("Herbert", ["Dune"])
      i = input(b, "Herbert - Dune.pdf")
      i.decider = ->(_b : CalibreHub::Book, _n : String, r : Array(Meta::Guess)) { {r.first, "model"}.as({Meta::Guess, String}?) }
      Flow.decide(i).not_nil!.confidence.should eq 40
      b = book("100767", ["Unknown"])
      Flow.decide(input(b, "100767.pdf")).not_nil!.confidence.should eq 10
    end
  end

  it "never changes what was edited by hand" do
    b = book("Mein Titel", ["Unknown"])
    i = input(b, "Other.pdf", text)
    i.by_isbn = catalog({WARREN => hackers})
    i.hand = Set{"title"}
    d = Flow.decide(i).not_nil!
    changed(d).has_key?("title").should be_false
    changed(d).has_key?("authors").should be_true
    d.title.should eq 100
    i.hand = Set{"authors"}
    changed(Flow.decide(i)).has_key?("authorSort").should be_false
    i.hand = Set{"title", "authors", "authorSort", "isbn"}
    Flow.decide(i).not_nil!.changes.should be_empty
  end

  it "takes the tag away from a book it is sure of" do
    b = book("Hacker's Delight", ["Henry S. Warren"], tags: ["auto-unsicher"])
    i = input(b, nil, text)
    i.by_isbn = catalog({WARREN => hackers})
    changed(Flow.decide(i))["tags"].should eq JSON.parse("[]")
  end

  it "leaves a standard to its own rules" do
    b = book("DIN EN ISO 14971:2013-04", ["DIN"], tags: ["Norm"])
    Flow.decide(input(b, "DIN EN ISO 14971.pdf")).should be_nil
  end
end

describe Meta::FileMeta do
  fixtures = File.join(__DIR__, "fixtures", "metadata")

  it "reads a DjVu's annotations" do
    r = Meta::FileMeta.djvu_meta(%(Title\t"Geometry and Symmetry"\nAuthor\t"Paul B. Yale"\n))
    {r.title, r.authors}.should eq({"Geometry and Symmetry", ["Paul B. Yale"]})
  end

  it "says which pages OCR reads" do
    Meta::Ocr.selection(300).should eq({[1, 2, 3, 4, 5, 6], [299, 300]})
    Meta::Ocr.selection(7).should eq({[1, 2, 3, 4, 5, 6], [7]})
    Meta::Ocr.selection(3).should eq({[1, 2, 3], [] of Int32})
  end

  it "reads a scan by OCR, once" do
    {"scan.pdf" => "PDF", "scan.djvu" => "DJVU"}.each do |file, format|
      path = File.join(fixtures, file)
      info = Meta::FileMeta.read(path, format).not_nil!
      info.scan?.should be_true
      stored = [] of String
      cache = Meta::Ocr::Cache.new(->(_k : String) { nil.as({String, String}?) },
        ->(k : String, _f : String, _b : String) { stored << k; nil })
      read = Meta::FileMeta.with_ocr(info, path, cache)
      read.ocr.should be_true
      read.front.should contain "Herbert"
      read.isbns.should eq ["9780387984797"]
      stored.size.should eq 1
      again = Meta::Ocr::Cache.new(->(_k : String) { {"from the cache", ""}.as({String, String}?) },
        ->(_k : String, _f : String, _b : String) { raise "not again" })
      Meta::FileMeta.with_ocr(info, path, again).front.should eq "from the cache"
    end
  end

  it "doesn't OCR with no slots" do
    jobs = Meta::Ocr.jobs
    Meta::Ocr.jobs = 0
    Meta::Ocr.read(File.join(fixtures, "scan.pdf"), "PDF").should be_nil
    Meta::Ocr.jobs = jobs
  end
end
