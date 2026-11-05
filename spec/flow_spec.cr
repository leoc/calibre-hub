require "spec"
require "http/server"
require "../src/calibre_hub/meta_flow"
require "../src/calibre_hub/meta_quality"

private alias Meta = CalibreHub::Meta
private alias Confidence = CalibreHub::Meta::Confidence
private alias Flow = CalibreHub::Meta::Flow
private alias M = CalibreHub::Meta::People

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
PAGES_DE = "Frank Herbert\nDer Wüstenplanet\nRoman\nDie Geschichte von dem Planeten und der Familie, die sich auf den Wüsten mit einer Macht nicht ein für alle Mal von dem Haus der anderen löst und die ist.\n© 1965 Frank Herbert\nAlle Rechte vorbehalten\nISBN 978-3-453-31717-8\n"

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
      {d.title, d.authors, d.confidence}.should eq({85, 98, 85})
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

    it "says when the text came from OCR" do
      b = book("Unknown", ["Unknown"])
      i = input(b, nil, text, ocr: true)
      i.by_isbn = catalog({WARREN => hackers})
      Flow.decide(i).not_nil!.isbn_source.should eq "ocr"
    end

    describe "a record against what the book says it is" do
      # #1734: the PDF's title is a standard's, the file a short name, the title page the record's
      it "wants the title page's word for it" do
        pages = "Signal Processing for Communications, by P.Prandoni and M. Vetterli, © 2008, EPFL Press\nSIGNAL PROCESSING FOR COMMUNICATIONS\nISBN 978-0-201-91465-8 (EPFL Press)\n"
        r = Meta::Record.new(title: "Signal Processing for Communications", authors: ["Paolo Prandoni", "Martin Vetterli"])
        i = input(book("ISO 15930 - Electronic document file format for prepress digital data exchange", ["Unknown"]), "sp4comm_corrected.pdf", pages)
        i.by_isbn = catalog({WARREN => r})
        d = Flow.decide(i).not_nil!
        {d.level, d.confidence, d.band}.should eq({1, 75, "review"})
        changed(d)["title"].should eq "Signal Processing for Communications"
      end

      # #76: FDA guidance, its reference list quotes a book on software quality
      it "doesn't turn a text into a source it quotes" do
        pages = "General Principles of Software Validation; Final Guidance for Industry and FDA Staff\n" + "the quality of software is the issue of software quality here. " * 40 +
                "\nReferences\nCraig Kaplan, Ralph Clark, Victor Tang, Secrets of Software Quality, McGraw-Hill, 1995. ISBN 0-201-91465-4.\n"
        r = Meta::Record.new(title: "Secrets of software quality", authors: ["Craig Kaplan", "Ralph Clark", "Victor Tang"])
        i = input(book("General Principles of Software Validation; Final Guidance for Industry and FDA Staff", ["Author: Compliance"]), nil, pages)
        i.by_isbn = catalog({WARREN => r})
        d = Flow.decide(i).not_nil!
        d.level.should_not eq 1
        changed(d).has_key?("title").should be_false
        changed(d).has_key?("isbn").should be_false
      end

      it "doesn't count small words as a title in the text" do
        Meta::Fit.title?("Secrets of software quality", Meta::Words.new("the quality of software is of the essence")).should be_false
      end

      # #1622: "Fuzzy-Systeme" quotes its English edition's ISBN in the foreword
      it "doesn't take a foreword's ISBN of another edition" do
        pages = "Geleitwort\nAs a treatise on fuzzy logic, Foundations of Fuzzy Systems by R. Kruse, J. Gebhardt and F. Klawonn has few equals.\n" +
                "Die englische Ausgabe ist erschienen bei Wiley, ISBN 0-201-91465-4. Das darin enthaltene Vorwort von Zadeh haben wir hier und der Text ist nicht von mit auf ein eine den\n"
        r = Meta::Record.new(title: "Foundations of fuzzy systems", authors: ["Rudolf Kruse", "Jörg Gebhardt", "Frank Klawonn"])
        i = input(book("Fuzzy Logic", ["Unknown"]), "Fuzzy Logic.pdf", pages)
        i.by_isbn = catalog({WARREN => r})
        d = Flow.decide(i).not_nil!
        d.confidence.should be < 90
        changed(d).has_key?("isbn").should be_false if d.level != 1
        (changed(d)["title"]? == "Foundations of fuzzy systems" && d.confidence >= 90).should be_false
      end

      it "writes nothing when nothing settles it" do
        pages = "Words about something\nHenry S. Warren\n" + "text " * 500 + "ISBN 0-201-91465-4\n"
        i = input(book("Mein Buch über Dinge", ["Unknown"]), nil, pages)
        i.by_isbn = catalog({WARREN => hackers})
        d = Flow.decide(i).not_nil!
        {d.level, d.confidence}.should eq({1, 50})
        changed(d).keys.sort.should eq ["candidate", "tags"]
        d.isbn.should be_nil
      end

      # #1467: the whole handbook, the file is named after its subtitle
      it "takes a title that is the record's subtitle" do
        pages = "Handbook of Research on Urban Informatics:\nThe Practice and Promise of the Real-Time City\nMarcus Foth\nCopyright 2009\nISBN 978-0-201-91465-8 (hardcover)\n"
        r = Meta::Record.new(title: "Handbook of research on urban informatics", authors: ["Marcus Foth"])
        i = input(book("The Practice and Promise of the Real-Time City", ["Unknown"]), "The Practice and Promise of the Real-Time City.pdf", pages)
        i.by_isbn = catalog({WARREN => r})
        d = Flow.decide(i).not_nil!
        {d.level, d.confidence}.should eq({1, 85})
        changed(d)["title"].should eq "Handbook of research on urban informatics: The Practice and Promise of the Real-Time City"
      end

      # #1657, #1432, #1724: junk or another book's metadata, the name agrees with the record
      it "doesn't take junk for a contradiction" do
        security = "Network Security Bible\nEric Cole\nRonald Krutz\nJames W. Conley\nCopyright 2005\nISBN 0-201-91465-4\n"
        r = Meta::Record.new(title: "Network Security Bible", authors: ["Eric Cole", "Ronald L. Krutz", "James W. Conley"])
        i = input(book("Peer To Peer Computing: The Evolution Of A Disruptive Technology", ["Brian D. Goodman Ramesh Subramanian"]), "Cole - Network Security Bible (Wiley, 2005).pdf", security)
        i.by_isbn = catalog({WARREN => r})
        d = Flow.decide(i).not_nil!
        d.confidence.should eq 98
        changed(d)["authors"].should eq JSON.parse(%(["Eric Cole", "Ronald L. Krutz", "James W. Conley"]))
        {"test", "New Page 12", "Unknown", "Warren"}.each do |junk|
          i = input(book(junk, ["Test"]), nil, text)
          i.by_isbn = catalog({WARREN => hackers})
          Flow.decide(i).not_nil!.confidence.should eq 98
        end
      end

      # #1161, #1163: the German text names the original title
      it "keeps a translation's title even when the text names the original" do
        pages = "ÜBER DAS BUCH: Dirk Gently's Holistische Detektei von Douglas Adams\nTitel der Originalausgabe: Dirk Gently's Holistic Detective Agency\nCopyright 1987\nISBN 0-201-91465-4\n"
        r = Meta::Record.new(title: "Dirk Gently's Holistic Detective Agency", authors: ["Douglas Adams"], subtitle: "Dirk Gently 1")
        i = input(book("Dirk Gently's Holistische Detektei", ["Douglas Adams"]), "Adams, Douglas - Dirk Gentlys holistische Detektei.pdf", pages)
        i.by_isbn = catalog({WARREN => r})
        d = Flow.decide(i).not_nil!
        changed(d).has_key?("title").should be_false
        {d.level, d.confidence}.should eq({1, 85})
      end
    end

    describe "the authors of a record" do
      it "doesn't lose a co-author a record leaves out (#77, #1608)" do
        pages = "Testing Business Ideas\nDavid J. Bland\nAlexander Osterwalder\nCopyright 2019\nISBN 0-201-91465-4\n"
        r = Meta::Record.new(title: "Testing Business Ideas", authors: ["David J. Bland"])
        i = input(book("Testing Business Ideas", ["David J. Bland", "Alexander Osterwalder"]), nil, pages)
        i.by_isbn = catalog({WARREN => r})
        changed(Flow.decide(i)).has_key?("authors").should be_false
        r = Meta::Record.new(title: "Programming Clojure", authors: ["Aaron Bedra", "Stuart Halloway"])
        i = input(book("Programming Clojure", ["Alex Miller", "Aaron Bedra", "Stuart Halloway"]), "Programming Clojure, 2nd edition.pdf", "Programming Clojure\nAlex Miller\nStuart Halloway\nAaron Bedra\nISBN 0-201-91465-4\n")
        i.by_isbn = catalog({WARREN => r})
        changed(Flow.decide(i)).has_key?("authors").should be_false
      end

      it "takes out what is no person and matches names loosely (#1, #67, #1804)" do
        M.merge(M.clean(["Joshua Foer", "Mike Chamberlain (Narrator) Joshua Foer"]), ["Joshua Foer"]).should eq({["Joshua Foer"], true})
        M.merge(["Richard D. Booker", "Earl Boysen"], ["Richard Booker"]).should eq({["Richard D. Booker", "Earl Boysen"], true})
        M.merge(["P Adams", "K Smith", "R Vyborny"], ["P. Adams"]).should eq({["P Adams", "K Smith", "R Vyborny"], true})
        M.merge(["EUSTACE L. DERENIAK", "TERESA D. DERENIAK"], ["Eustace L. Dereniak"]).should eq({["Eustace L. Dereniak", "Teresa D. Dereniak"], true})
        M.merge(["Richard Brodie"], ["Brodie Richard"]).should eq({["Richard Brodie"], true})
        M.merge(["Anthony Meredith"], ["Anthony Meredith Sj"]).should eq({["Anthony Meredith"], true})
        M.merge(["Marco Cesati Daniel P. Bovet"], ["Daniel P. Bovet", "Marco Cesati"]).should eq({["Daniel P. Bovet", "Marco Cesati"], true})
        M.merge(M.clean(["Darling", "David"]), ["David Darling"]).should eq({["David Darling"], true})
        M.merge(M.clean(["D. Grune", "et a."]), ["Dick Grune", "Henri E. Bal"]).should eq({["Dick Grune", "Henri E. Bal"], true})
        M.clean(["H. Delfs", "H. Knebl (Springer", "2007) WW"]).should eq ["H. Delfs", "H. Knebl"]
        M.clean(["E. Kohn, D. Herzog (2001) WW"]).should eq ["E. Kohn", "D. Herzog"]
        M.clean(["Mark. Stamp", "CrossReach Publications"]).should eq ["Mark Stamp"]
      end

      # #1697: the name's "author" is its title
      it "doesn't take a word of the title for a person" do
        r = Meta::Record.new(title: "Glitch", subtitle: "The Hidden Impact of Faulty Software", authors: ["Jeff Papows"])
        i = input(book("Glitch", ["Jeff Papows", "Ph D. Jeff Papows"]), "Glitch - The Hidden Impact of Faulty Software.pdf", "Glitch\nThe Hidden Impact of Faulty Software\nJeff Papows, Ph.D.\nISBN 0-201-91465-4\n")
        i.by_isbn = catalog({WARREN => r})
        changed(Flow.decide(i))["authors"].should eq JSON.parse(%(["Jeff Papows"]))
      end

      it "takes a joined name and an inverted one apart (#1806, #1597)" do
        M.merge(["S. Orszag C. Bender"], ["Carl M. Bender", "Steven A. Orszag"]).should eq({["Carl M. Bender", "Steven A. Orszag"], true})
        M.same?("B. Valmir", "Valmir C. Barbosa").should be_true
        M.same?("Arthur Robbins", "Arnold Robbins").should be_false
        M.merge(["V.C. Barbosa", "B. Valmir"], ["Valmir C. Barbosa"]).should eq({["Valmir C. Barbosa"], true})
      end

      it "keeps a person behind a series (#1214)" do
        M.clean(["(Genetic Engineering) Barbara R. Hough-Evans", "Eric H. Davidson (auth.)"]).should eq ["Barbara R. Hough-Evans", "Eric H. Davidson"]
        M.merge(M.clean(["(Genetic Engineering) Barbara R. Hough-Evans", "Eric H. Davidson (auth.)", "Jane K. Setlow (auth.)"]), ["Eric H. Davidson", "Jane K. Setlow"])
          .should eq({["Barbara R. Hough-Evans", "Eric H. Davidson", "Jane K. Setlow"], true})
      end

      # #1825: Clark edits the series, Previato this volume
      it "adds nobody of the name when the book and the record agree" do
        r = Meta::Record.new(title: "Dictionary of Applied Math for Engineers and Scientists", authors: ["Emma Previato"])
        i = input(book("Dictionary of Applied Math for Engineers and Scientists", ["Emma Previato"]),
          "CRC Press - Dictionary of Applied Math for Engineers and Scientists - D. Clark.pdf",
          "Dictionary of Applied Math for Engineers and Scientists\nDouglas N. Clark Editor-in-Chief\nEmma Previato\nCopyright 2003\nISBN 0-201-91465-4\n")
        i.by_isbn = catalog({WARREN => r})
        changed(Flow.decide(i)).has_key?("authors").should be_false
      end

      # #1580: the surname in front, a word of the title as author
      it "takes the author out of a title and a title's word out of the authors" do
        r = Meta::Record.new(title: "3D Computer Graphics", subtitle: "A Mathematical Introduction with OpenGL", authors: ["Samuel R. Buss"])
        i = input(book("Buss - 3D Computer Graphics", ["A Mathematical Introduction", "OpenGL"]), "Buss - 3D Computer Graphics - A Mathematical Introduction with OpenGL.pdf",
          "3D Computer Graphics\nA Mathematical Introduction with OpenGL\nSamuel R. Buss\nISBN 0-201-91465-4\n")
        i.by_isbn = catalog({WARREN => r})
        d = Flow.decide(i).not_nil!
        changed(d)["title"].as_s.should start_with "3D Computer Graphics"
        changed(d)["authors"].should eq JSON.parse(%(["Samuel R. Buss"]))
      end

      # #1776: Artin is a contributor, the editors are in the name
      it "doesn't replace editors with a contributor" do
        pages = "Arithmetic Geometry\nEdited by G. Cornell and J. H. Silverman\nContents\nMichael Artin: Neron Models\nISBN 0-201-91465-4\nCopyright 1986\n"
        r = Meta::Record.new(title: "Arithmetic Geometry", authors: ["Michael Artin"])
        i = input(book("Arithmetic Geometry", ["G. Cornell", "J. Silverman (Springer", "1986) WW"]), "Arithmetic Geometry - G. Cornell, J. Silverman (Springer, 1986) WW.djvu", pages)
        i.by_isbn = catalog({WARREN => r})
        d = Flow.decide(i).not_nil!
        changed(d)["authors"].should eq JSON.parse(%(["G. Cornell", "J. Silverman"]))
        d.confidence.should eq 70
      end

      it "makes no change of the same authors (#84)" do
        r = Meta::Record.new(title: "GAMP Good Practice Guide", authors: ["ISPE"])
        i = input(book("GAMP Good Practice Guide", ["ISPE"]), nil, "GAMP Good Practice Guide\nISPE\nISBN 0-201-91465-4\n")
        i.by_isbn = catalog({WARREN => r})
        changed(Flow.decide(i)).has_key?("authors").should be_false
      end

      it "takes a person a catalog has twice once (#1684, #1818)" do
        r = Meta::Record.new(authors: ["Linda Lamb", "Arnold Robbins", "Arthur Robbins"])
        Meta::CrossCheck.people(r).should eq ["Linda Lamb", "Arnold Robbins"]
        Meta::CrossCheck.people(Meta::Record.new(authors: ["J. O. Bird", "John Bird"])).should eq ["J. O. Bird"]
      end
    end

    it "takes the book's form of a title (#1828, #1696, #1214)" do
      {
        {"Chihara - Structural Account of Mathematics (Oxford, 2004).pdf", "A structural account of mathematics", "Structural Account of Mathematics"},
        {"Digitale Hardware- und Softwaresysteme.pdf", "Digitale Hardware, Software-Systeme", "Digitale Hardware- und Softwaresysteme"},
        {"Genetic Engineering Principles & Methods Volume 9.pdf", "Genetic Engineering", "Genetic Engineering Principles & Methods Volume 9"},
      }.each do |name, record, want|
        i = input(book("Unknown", ["Unknown"]), name, "#{record}\nHenry S. Warren\nISBN 0-201-91465-4\n")
        i.by_isbn = catalog({WARREN => Meta::Record.new(title: record, authors: ["Henry S. Warren"])})
        changed(Flow.decide(i))["title"].should eq want
      end
    end

    # #1708
    it "doesn't replace a title by the same words in a worse form" do
      t = "Ethernet: The Definitive Guide"
      i = input(book(t, ["Charles E. Spurgeon"]), "O'Reilly - Ethernet Definitive Guide.pdf", "#{t}\nCharles E. Spurgeon\nISBN 0-201-91465-4\n")
      i.by_isbn = catalog({WARREN => Meta::Record.new(title: "Ethernet", subtitle: "The Definitive Guide", authors: ["Charles E. Spurgeon"])})
      changed(Flow.decide(i)).has_key?("title").should be_false
      # the name's reading on the last level as well
      changed(Flow.decide(input(book(t, ["Charles E. Spurgeon"]), "O'Reilly - Ethernet Definitive Guide.pdf"))).has_key?("title").should be_false
      # a better form goes through
      d = Flow.decide(input(book("Bioinformatics - A Practical Approach", ["S. Ye (CRC, 2008) WW"]), "Bioinformatics  - A Practical Approach - S. Ye (CRC, 2008) WW.pdf"))
      changed(d)["title"].should eq "Bioinformatics: A Practical Approach"
    end

    it "drops a shop's note and keeps the subtitle of the book (#1572, #1665)" do
      i = input(book("Jones - Artificial Intelligence", ["A Systems Approach (Infinity, 2008)"]), "Jones - Artificial Intelligence - A Systems Approach (Infinity, 2008).pdf",
        "Artificial Intelligence\nA Systems Approach\nM. Tim Jones\nISBN 0-201-91465-4\n")
      i.by_isbn = catalog({WARREN => Meta::Record.new(title: "Artificial Intelligence", subtitle: "A Systems Approach, with CDROM", authors: ["M. Tim Jones"])})
      changed(Flow.decide(i))["title"].should eq "Artificial Intelligence: A Systems Approach"
      i = input(book("09 - The Pragmatic Programmer", ["From Journeyman to Master"]), "09 - The Pragmatic Programmer - From Journeyman to Master.pdf",
        "The Pragmatic Programmer\nFrom Journeyman to Master\nAndrew Hunt\nISBN 0-201-91465-4\n")
      i.by_isbn = catalog({WARREN => Meta::Record.new(title: "The Pragmatic Programmer", subtitle: "Your Journey to Mastery", authors: ["Andrew Hunt"])})
      changed(Flow.decide(i))["title"].should eq "The Pragmatic Programmer: From Journeyman to Master"
    end

    # #1281
    it "survives a catalog title with double spaces, and one without any" do
      pages = "Sex, Sin, and Zen\nBrad Warner\nISBN 0-201-91465-4\n"
      i = input(book("Sex, Sin, and Zen: Buddhist Exploration of Sex", ["Brad Warner"]), nil, pages)
      i.by_isbn = catalog({WARREN => Meta::Record.new(title: "Sex, Sin,  and Zen:  A Buddhist Exploration", authors: ["Brad Warner"])})
      Flow.decide(i).not_nil!.level.should eq 1
      i.by_isbn = catalog({WARREN => Meta::Record.new(title: "", authors: ["Brad Warner"])})
      Flow.decide(i).not_nil!.level.should_not eq 1
    end

    it "doesn't take a file name in one word for a form of the title (#1184)" do
      t = "Build a Binary Clock with Elixir and Nerves"
      i = input(book(t, ["Bruce A. Tate Frank Hunleth"]), "buildabinaryclockwithelixirandnerves.epub", "#{t}\nFrank Hunleth\nBruce A. Tate\nISBN 0-201-91465-4\n")
      i.by_isbn = catalog({WARREN => Meta::Record.new(title: t, authors: ["Frank Hunleth", "Bruce A. Tate"])})
      changed(Flow.decide(i)).has_key?("title").should be_false
    end

    it "takes the book's own record before another edition's ISBN in its pages (#15)" do
      other = "9780387984797"
      i = input(book("Hacker's Delight", ["Henry S. Warren"], isbn: other), nil, text)
      i.by_isbn = catalog({WARREN => hackers, other => hackers})
      d = Flow.decide(i).not_nil!
      d.notes.should be_empty
      d.confidence.should eq 98
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

    it "never goes below 0 (#68)" do
      b = book("57390", ["Unknown"])
      Flow.decide(input(b, nil, "word " * 200)).not_nil!.confidence.should eq 0
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

describe "the first portion of the rule flow (#8528)" do
  filler = "der Text eines Buches ohne einen Namen darin " * 15
  people = ["R. Tunç Mısırlıoğlu", "Kosaku Yosida"]
  yosida_name = "Functional Analysis 6th ed - K. Yoshida (Springer, 1980) WW.pdf"
  yosida_isbn = "9783540102106"
  yosida = Meta::Record.new(title: "Functional Analysis (Grundlehren der mathematischen Wissenschaften)", authors: ["Kosaku Yosida"])
  path = %q(C:\Program Files\eMule\Incoming\Yoshida K. -  Functional analysis (Springer, 1980)(256s).djvu)

  it "#1848: a path is no title, nor is who the file names beside the book" do
    i = input(book(path, people, isbn: yosida_isbn), yosida_name, "Functional Analysis\nKosaku Yosida\nSpringer\n#{filler}")
    i.by_isbn = catalog({yosida_isbn => yosida})
    d = Flow.decide(i).not_nil!
    changed(d)["title"].should eq "Functional Analysis"
    changed(d)["authors"].as_a.map(&.as_s).should eq ["Kosaku Yosida"]
    d.band.should_not eq "unsure"
  end

  it "#1848: a path is read like a name where the book has none" do
    d = Flow.decide(input(book(path, people), nil, ""))
    changed(d)["title"].should eq "Functional analysis"
    changed(d)["authors"].as_a.map(&.as_s).should eq ["K. Yoshida"]
  end

  it "#1400, #1608: a record with fewer people removes nobody, whatever the text shows" do
    b = book("Programming Clojure", ["Alex Miller", "Aaron Bedra", "Stuart Halloway"], isbn: yosida_isbn)
    i = input(b, "Programming Clojure, 2nd edition.pdf", "Programming Clojure\nAaron Bedra\nStuart Halloway\n#{filler}")
    i.by_isbn = catalog({yosida_isbn => Meta::Record.new(title: "Programming Clojure", authors: ["Stuart Halloway", "Aaron Bedra"])})
    Flow.decide(i).not_nil!.changes.none? { |c| c.field == "authors" }.should be_true
  end

  it "#1939, #2578: a file's title with the name's author in front loses him, nobody else goes" do
    pdf = Meta::Record.new(title: "Klug - Concepts of Genetics 8e", authors: ["Klug"])
    b = book("Concepts of Genetics 8e", ["Klug", "Cummings", "Spencer"])
    d = Flow.decide(input(b, "Klug - Concepts of Genetics 8e [OCR] (Pearson, 2006).pdf", "Concepts of Genetics\nKlug\n#{filler}", record: pdf)).not_nil!
    changed(d)["title"]?.try(&.as_s.includes?("Klug")).should_not be_true
    d.changes.none? { |c| c.field == "authors" }.should be_true
  end

  it "#1921: a print dialog's rests and capitals go, the name and the record agree" do
    isbn = "9789810234799"
    b = book("Print PROBLEMS AND SOLUTIONS IN MATHEMATICS (547 pages)", ["Ta-Tsien"], isbn: isbn)
    i = input(b, "Ta-Tsien - Problems and Solutions In Mathematics (World Scientific, 1999).pdf", "PROBLEMS AND SOLUTIONS IN MATHEMATICS\n#{filler}")
    i.by_isbn = catalog({isbn => Meta::Record.new(title: "Problems and solutions in mathematics", authors: ["Ji-Xiu Chen", "Daqian Li"])})
    d = Flow.decide(i).not_nil!
    changed(d)["title"].should eq "Problems and Solutions In Mathematics"
    # the record knows nobody of the book: its person stays
    changed(d).has_key?("authors").should be_false
  end

  it "takes a shouted title in the record's or the name's form" do
    d = Flow.decide(input(book("MOLECULAR BASIS OF HUMAN NUTRITION", ["Tom Sanders"]), "Molecular Basis of Human Nutrition - T. Sanders, P. Emery (2003) WW.pdf"))
    changed(d)["title"].should eq "Molecular Basis of Human Nutrition"
    i = input(book("MOLECULAR BASIS OF HUMAN NUTRITION", ["Tom Sanders"], isbn: DUNE), nil, "Molecular Basis of Human Nutrition\nTom Sanders\n#{filler}")
    i.by_isbn = catalog({DUNE => Meta::Record.new(title: "Molecular basis of human nutrition", authors: ["Tom Sanders"])})
    changed(Flow.decide(i))["title"].should eq "Molecular basis of human nutrition"
    # a title in order stays
    i = input(book("UNIX", ["Eric S. Raymond"], isbn: DUNE), nil, "UNIX\nEric S. Raymond\n#{filler}")
    i.by_isbn = catalog({DUNE => Meta::Record.new(title: "UNIX", authors: ["Eric S. Raymond"])})
    changed(Flow.decide(i)).has_key?("title").should be_false
  end

  it "#2065: \"Cumulative Index\" is nobody, whatever a record says of the title" do
    i = input(book("Grzimek's animal life encyclopedia.: Vol 17", ["Cumulative Index"]), "Vol 17 - Cumulative Index.pdf",
      "Grzimek's animal life encyclopedia\nISBN 978-3-453-31717-8\n#{filler}")
    i.by_isbn = catalog({DUNE => Meta::Record.new(title: "Grzimek's animal life encyclopedia.", authors: [] of String)})
    d = Flow.decide(i).not_nil!
    d.band.should eq "unsure"
    changed(d).has_key?("authors").should be_false
    changed(d)["tags"].should eq JSON.parse(%(["auto-unsicher"]))
    changed(d)["candidate"]["authors"].should eq JSON.parse(%(["Unknown"]))
  end

  it "#2057: \"Vol 09\" by \"Birds 2\" says nothing, the suggestion has both as a title" do
    d = Flow.decide(input(book("Vol 09", ["Birds 2"]), "Vol 09 - Birds 2.djvu")).not_nil!
    d.band.should eq "unsure"
    changed(d)["candidate"]["title"].should eq "Vol 09: Birds 2"
    changed(d)["candidate"]["authors"].should eq JSON.parse(%(["Unknown"]))
    changed(d)["tags"].should eq JSON.parse(%(["auto-unsicher"]))
    changed(d).has_key?("title").should be_false
  end

  {
    {2227, "McEvoy", ["Molecular Basis of Medical Cell Biology (Lange, 1998)"], "McEvoy - Molecular Basis of Medical Cell Biology (Lange, 1998).djvu",
     "Molecular Basis of Medical Cell Biology", ["McEvoy"]},
    {2146, "Anderson", ["Microorganisms", "Bioterrorism (Springer, 2006)"], "Anderson - Microorganisms and Bioterrorism (Springer, 2006).pdf",
     "Microorganisms and Bioterrorism", ["Anderson"]},
    {1946, "Becker", ["Computational Biochemistry", "Biophysics"], "Becker - Computational Biochemistry and Biophysics.pdf",
     "Computational Biochemistry and Biophysics", ["Becker"]},
  }.each do |id, title, authors, name, new_title, new_authors|
    it "##{id}: turns a swapped pair round, also against a text OCR can't read" do
      {"", filler}.each do |text|
        d = Flow.decide(input(book(title, authors), name, text)).not_nil!
        changed(d)["title"].should eq new_title
        changed(d)["authors"].as_a.map(&.as_s).should eq new_authors
        d.band.should eq "review"
      end
      # a book without a name: the pair alone shows it
      d = Flow.decide(input(book(title, authors), nil, "")).not_nil!
      changed(d)["title"].should eq new_title
      changed(d)["authors"].as_a.map(&.as_s).should eq new_authors
    end
  end

  it "keeps hands off a swapped pair someone edited" do
    i = input(book("McEvoy", ["Molecular Basis of Medical Cell Biology (Lange, 1998)"]), "McEvoy - Molecular Basis of Medical Cell Biology (Lange, 1998).djvu")
    i.hand = Set{"title"}
    d = Flow.decide(i).not_nil!
    changed(d).has_key?("title").should be_false
  end

  it "#1966, #2254: a CHM's surname is no title, its title no author" do
    swapped = Meta::Record.new(title: "Hamill", authors: ["Biomechanical Basis of Human Movement"])
    d = Flow.decide(input(book("Hamill", ["Biomechanical Basis of Human Movement"]), "Hamill - Biomechanical Basis of Human Movement 3e (Lippincott, 2008).chm", "", swapped, "CHM"))
    changed(d)["title"].should eq "Biomechanical Basis of Human Movement"
    changed(d)["authors"].as_a.map(&.as_s).should eq ["Hamill"]
    twice = Meta::Record.new(title: "Fundamental Immunology", authors: ["Fundamental Immunology"])
    d = Flow.decide(input(book("Fundamental Immunology", ["Fundamental Immunology"]), "Paul - Fundamental Immunology 6e (Lippincott, 2008).chm", "", twice, "CHM"))
    changed(d)["authors"].as_a.map(&.as_s).should eq ["Paul"]
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
