require "spec"
require "http/server"
require "../src/calibre_hub/meta_sources"

private alias Meta = CalibreHub::Meta
private alias FileName = CalibreHub::Meta::FileName

private def book(title : String, authors : Array(String), publisher : String? = nil, isbn : String? = nil, tags = [] of String) : CalibreHub::Book
  CalibreHub::Book.new(id: 1_i64, title: title, authors: authors, author_sort: Meta::AuthorSort.for(authors),
    tags: tags, series: nil, series_index: nil, formats: ["PDF"], last_modified: Time::UNIX_EPOCH,
    timestamp: nil, pubdate: nil, rating: nil, publisher: publisher,
    identifiers: isbn ? {"isbn" => isbn} : {} of String => String,
    languages: [] of String, comments: nil, custom: {} of String => JSON::Any)
end

private def now(b : CalibreHub::Book)
  ->(field : String) { Meta::Merge.value(b, field).as(JSON::Any?) }
end

# the book after a decision: title, authors, publisher, who decided, tagged
private def outcome(b : CalibreHub::Book, decided : {Array(Meta::Change), String}?)
  changes, how = decided || {[] of Meta::Change, "-"}
  h = changes.to_h { |c| {c.field, c.new} }
  {h["title"]?.try(&.as_s) || b.title, h["authors"]?.try(&.as_a.map(&.as_s)) || b.authors,
   h["publisher"]?.try(&.as_s?), how, h.has_key?("tags")}
end

private def candidate(source : String, title : String, authors : Array(String), subtitle : String? = nil, by_isbn : String? = nil, score = 0.8)
  r = Meta::Record.new(title: title, authors: authors, subtitle: subtitle)
  Meta::Candidate.new(source, r, "http://#{source}/#{authors.first?}", by_isbn: by_isbn).tap { |c| c.score = score }
end

describe "the books of #8528" do
  # book as the import left it, file name => title, authors, publisher
  {
    {1617, "07 - Compilers", ["Principles, Techniques", "Tools (2nd Edition)"], "07 - Compilers - Principles, Techniques and Tools (2nd Edition).pdf",
     "Compilers: Principles, Techniques and Tools", ["Unknown"], nil},
    {1665, "09 - The Pragmatic Programmer", ["From Journeyman to Master"], "09 - The Pragmatic Programmer - From Journeyman to Master.pdf",
     "The Pragmatic Programmer: From Journeyman to Master", ["Unknown"], nil},
    {1662, "04 - Code Complete", ["A Practical Handbook of Software Construction (2nd Edition)"],
     "04 - Code Complete - A Practical Handbook of Software Construction (2nd Edition).pdf",
     "Code Complete: A Practical Handbook of Software Construction", ["Unknown"], nil},
    {1666, "11", ["The Art of UNIX Programming"], "11 - The Art of UNIX Programming.pdf", "The Art of UNIX Programming", ["Unknown"], nil},
    {1615, "12", ["The Little Schemer (4th Edition)"], "12 - The Little Schemer (4th Edition).pdf", "The Little Schemer", ["Unknown"], nil},
    # "Danny" is a file's owner, no author
    {1645, "book", ["Danny"], "13 - Peopleware - Productive Projects and Teams (2nd Edition).pdf",
     "Peopleware: Productive Projects and Teams", ["Unknown"], nil},
    {1276, "8508 Fm Frame", ["Jasmine Fradique"], "Vegetarian Nutrition - J. Sabate (CRC, 2001) WW.pdf", "Vegetarian Nutrition", ["J. Sabate"], "CRC Press"},
    {1605, "Pearson.-.Agile.Game.Development.with.Scrum.2010", ["Pearson"], "Pearson.-.Agile.Game.Development.with.Scrum.2010.pdf",
     "Agile Game Development with Scrum", ["Unknown"], "Pearson"},
    {1730, "Addison Wesley - Hacker's Delight - Ripped by Caudex 2003", ["Hacker's Delight [computer arithmetic] (AW, 2002)"],
     "Warren - Hacker's Delight [computer arithmetic] (AW, 2002).chm", "Hacker's Delight", ["Warren"], "Addison-Wesley"},
    {1212, "Alexander Shulgin - Drugs of Abuse in the Future", ["Future Drugs"], "Shulgin - Future Drugs.pdf",
     "Drugs of Abuse in the Future", ["Alexander Shulgin"], nil},
    {1386, "Stephen Hawking - a Brief History of Time", ["Berta Butz"], "5. Stephen Hawking - A Brief History Of Time (1988).pdf",
     "A Brief History Of Time", ["Stephen Hawking"], nil},
    {1471, "The Secret Language of Business", ["How to Read Anyone in 3 Seconds or Less"], "The Secret Language of Business - How to Read Anyone in 3 Seconds or Less.pdf",
     "The Secret Language of Business: How to Read Anyone in 3 Seconds or Less", ["Unknown"], nil},
    {1278, "Wharton - Life at the Limits", ["Organisms in Extreme Environments"], "Wharton - Life at the Limits - Organisms in Extreme Environments.pdf",
     "Life at the Limits: Organisms in Extreme Environments", ["Wharton"], nil},
    {1757, "Encyclopedia of Mathematics", ["Gale Group (Vol.1 Ab-Cy)"], "Encyclopedia of Mathematics - Gale Group (Vol.1 Ab-Cy).djvu",
     "Encyclopedia of Mathematics (Vol.1 Ab-Cy)", ["Unknown"], "Gale Group"},
    {1644, "Rev2", ["Understanding Bluetooth"], "Understanding Bluetooth.pdf", "Understanding Bluetooth", ["Unknown"], nil},
    # the name says nothing, the file's title stays; a publisher moves
    {1758, "Chapter 1: Reasoning in Geometry", ["Glencoe/McGraw-Hill"], "chap01.pdf", "Chapter 1: Reasoning in Geometry", ["Unknown"], "Glencoe/McGraw-Hill"},
  }.each do |id, title, authors, name, want_title, want_authors, publisher|
    it "##{id}: #{name[0, 50]}" do
      b = book(title, authors)
      got = outcome(b, FileName.decide(b, name, nil, now(b)))
      {got[0], got[1], got[2]}.should eq({want_title, want_authors, publisher})
    end
  end

  # no file name to read: an upload, the inbox, or the name is lost
  {
    {1235, "100 Great Artists~A Visual Journey from Fra Angelico to Andy Warhol", ["Unknown"],
     "100 Great Artists: A Visual Journey from Fra Angelico to Andy Warhol", ["Unknown"], nil},
    {1261, "AkteurGehirn", ["Unknown"], "Akteur Gehirn", ["Unknown"], nil},
    {1688, "(Delmar) Digital Signal Processing--Filtering Approach", ["Unknown"], "Digital Signal Processing: Filtering Approach", ["Unknown"], "Delmar"},
    {11, "100M Money Models", ["How To Make Money"], "100M Money Models", ["Unknown"], nil},
    {6, "Psychokybernetik nutzen Sie die Macht Ihres -- Maxwell Maltz -- 1 Auflage, München, 2022 -- FinanzBuch Verlag -- 9783959725910 -- Anna's Archive", ["Unknown"],
     "Psychokybernetik nutzen Sie die Macht Ihres", ["Maxwell Maltz"], "FinanzBuch Verlag"},
    {36, "Chet Holmes", ["The Ultimate Sales Machine Turbocharge Your Business"], "The Ultimate Sales Machine Turbocharge Your Business", ["Chet Holmes"], nil},
    {1214, "Genetic Engineering Principles & Methods Volume 9-Springer US", ["(Genetic Engineering) Barbara R. Hough-Evans", "Eric H. Davidson"],
     "Genetic Engineering Principles & Methods Volume 9", ["Barbara R. Hough-Evans", "Eric H. Davidson"], "Springer US"},
    {1252, "Streifzüge durch das MA", ["Beck (Hg.)"], "Streifzüge durch das MA", ["Beck"], nil},
    {89, "Guidance for the Content of Premarket Submissions", ["Author: David Buckles"], "Guidance for the Content of Premarket Submissions", ["David Buckles"], nil},
  }.each do |id, title, authors, want_title, want_authors, publisher|
    it "##{id}: #{title[0, 50]}" do
      b = book(title, authors)
      got = outcome(b, FileName.decide_own(b, now(b)))
      {got[0], got[1], got[2]}.should eq({want_title, want_authors, publisher})
    end
  end

  it "#68: a title and author nothing is known of go to the review" do
    b = book("57390", ["Unknown"])
    outcome(b, FileName.decide_own(b, now(b))).should eq({"57390", ["Unknown"], nil, "unsure", true})
  end

  it "#1669: a junk title goes with the name, the file's nick needs a review" do
    b = book("19 3.eps", ["K.Raptor"])
    FileName.bad_title?(b.title).should be_true
    outcome(b, FileName.decide(b, "Analog Filter Design.pdf", nil, now(b))).should eq({"Analog Filter Design", ["K.Raptor"], nil, "unsure", true})
  end
end

describe "the live dry run of 77533b7 (#8528)" do
  it "#1167: a collection's code is no part of the title" do
    name = "HIT04 - So Long, and Thanks for All the Fish - Douglas Adams.mobi"
    b = book("HIT04 - So Long, and Thanks for All the Fish", ["Douglas Adams"])
    got = outcome(b, FileName.decide(b, name, nil, now(b)))
    {got[0], got[1]}.should eq({"So Long, and Thanks for All the Fish", ["Douglas Adams"]})
    # a number in the name of a thing stays
    FileName.parse("AK47 - The Story of a Gun.pdf").not_nil!.title.should_not eq "The Story of a Gun"
  end

  it "#1648: \"et a.\" and \"et al.\" are nobody" do
    name = "Modern Compiler Design - D. Grune, et a., (Wiley, 2000) WW.djvu"
    FileName.parse(name).not_nil!.authors.should eq ["D. Grune"]
    b = book("Modern Compiler Design", ["D. Grune", "et a."])
    outcome(b, FileName.decide(b, name, nil, now(b)))[1].should eq ["D. Grune"]
    ["et a.", "et al.", "et al", "u.a."].each do |a|
      FileName.bad_author?(a).should be_true
      Meta::Clean.authors(["D. Grune", a]).should eq ["D. Grune"]
    end
  end

  it "#1416, #1417: a volume at the end of a run-together name" do
    FileName.parse("CompilerConstruction2.pdf").not_nil!.title.should eq "Compiler Construction 2"
    FileName.parse("AkteurGehirn.pdf").not_nil!.title.should eq "Akteur Gehirn"
  end

  it "#1243: a revision in parentheses is no author" do
    b = book("Op Amps for Everyone Design Guide (Rev. B)", ["Incorporated Texas Instruments"])
    outcome(b, FileName.decide_own(b, now(b)))[1].should eq ["Unknown"]
  end

  it "#76: \"Compliance\" is no person" do
    b = book("General Principles of Software Validation; Final Guidance for Industry", ["Author: Compliance"])
    outcome(b, FileName.decide_own(b, now(b)))[1].should eq ["Unknown"]
  end

  title = Meta::Guess.new("UNIX Power Tools", [] of String)

  it "#1689: an organisation goes from a catalog's authors, the persons stay" do
    list = [candidate("openlibrary", "UNIX Power Tools", ["Jerry Peek", "Shelley Powers", "Electronic Publishing"], by_isbn: "9780596003302").tap(&.sure = true)]
    Meta::CrossCheck.verdict(title, list).not_nil!.authors.should eq ["Jerry Peek", "Shelley Powers"]
  end

  it "a candidate without a person confirms nothing" do
    {"Symposium on Mathematical Modelling of Estuarine Physics (1978 Hamburg, Germany)", "Electronic Publishing",
     "McKinsey & Co", "O'Reilly Media", "Institute for Sex Research", "Springer-Verlag GmbH", "Compliance"}.each do |org|
      r = Meta::Record.new(title: "UNIX Power Tools", authors: [org])
      Meta::CrossCheck.people(r).should be_empty
      sure = candidate("openlibrary", "UNIX Power Tools", [org], by_isbn: "9780596003302").tap(&.sure = true)
      Meta::CrossCheck.verdict(title, [sure, candidate("hardcover", "UNIX Power Tools", [org])]).should be_nil
    end
    Meta::CrossCheck.people(Meta::Record.new(authors: ["Man Young Rhee", "Mike Chamberlain (Narrator)", "Hans Bethe (1906-2005)"])).should eq ["Man Young Rhee", "Hans Bethe"]
  end

  it "keeps organisations out of the authors of a metadata run" do
    sure = candidate("openlibrary", "UNIX Power Tools", ["Jerry Peek", "Electronic Publishing"], by_isbn: "9780596003302").tap(&.sure = true)
    Meta::Merge.plan(book("UNIX Power Tools", ["Jerry Peek"], isbn: "9780596003302"), nil, nil, [sure]).none? { |c| c.field == "authors" }.should be_true
  end

  it "#1719: the book's own ISBN filed under another book isn't sure" do
    wrong = candidate("openlibrary", "Mathematical modelling of estuarine physics", ["Hans Sündermann"], by_isbn: "9780387097503")
    g = Meta::Guess.new("Handbook Of Peer To Peer Networking", [] of String)
    Meta::Score.rank([wrong], [g], [] of String, ["9780387097503"]).first.sure.should be_false
    Meta::CrossCheck.verdict(g, [wrong]).should be_nil
    # with an author, too
    named = Meta::Guess.new("Handbook Of Peer To Peer Networking", ["Xuemin Shen"])
    Meta::Score.rank([wrong], [named], [] of String, ["9780387097503"]).first.sure.should be_false
    # the right record is, with or without its subtitle, and so is any for a title that says nothing
    right = candidate("openlibrary", "Handbook of Peer-to-Peer Networking", ["Xuemin Shen"], by_isbn: "9780387097503")
    Meta::Score.rank([right], [g], [] of String, ["9780387097503"]).first.sure.should be_true
    junk = candidate("openlibrary", "Mathematical modelling", ["Hans Sündermann"], by_isbn: "9780387097503")
    Meta::Score.rank([junk], [Meta::Guess.new("8508 Fm Frame", [] of String)], [] of String, ["9780387097503"]).first.sure.should be_true
  end

  it "#1766: no suggestion by the name \"Chapter 9\"" do
    g = Meta::Guess.new("Chapter 9: Proportions and Similarity", [] of String)
    Meta::CrossCheck.verdict(g, [candidate("openlibrary", "CHAPTER 9", ["Robert Bothwell"])]).should be_nil
  end
end

describe "title and authors together" do
  it "keeps what a person edited, whatever the other field gets" do
    name = "Vegetarian Nutrition - J. Sabate (CRC, 2001) WW.pdf"
    b = book("8508 Fm Frame", ["Jasmine Fradique"])
    title_edited = ->(f : String) { f == "title" ? nil.as(JSON::Any?) : Meta::Merge.value(b, f).as(JSON::Any?) }
    outcome(b, FileName.decide(b, name, nil, title_edited))[0].should eq "8508 Fm Frame"
    authors_edited = ->(f : String) { f == "authors" ? nil.as(JSON::Any?) : Meta::Merge.value(b, f).as(JSON::Any?) }
    got = outcome(b, FileName.decide(b, name, nil, authors_edited))
    {got[0], got[1]}.should eq({"Vegetarian Nutrition", ["Jasmine Fradique"]})
  end

  it "takes the name's book when the file's title is another one and the authors are calibre's" do
    b = book("Sssshhhh!! Don't blow our Cover!!", ["The Essential Psychedelic Guide"])
    got = outcome(b, FileName.decide(b, "D.M. Turner - The Essential Psychedelic Guide.pdf", nil, now(b)))
    {got[0], got[1]}.should eq({"The Essential Psychedelic Guide", ["D.M. Turner"]})
  end

  it "doesn't touch good authors for a title that stays" do
    b = book("Advanced Mathematics for Engineering and Science", ["Wenfang Chen", "D. De Kee"])
    name = "Advanced Mathematics for Engineering and Science - C. Fong, D. Kee, P. Kaloni (World, 2003) WW.pdf"
    imported = ->(f : String) { f == "title" ? JSON::Any.new(FileName.calibre(name)[0]).as(JSON::Any?) : Meta::Merge.value(b, f).as(JSON::Any?) }
    outcome(b, FileName.decide(b, name, nil, imported))[1].should eq b.authors
  end

  it "takes the person of a file's title with the name's longer title" do
    b = book("Alan Weiss - Value-Based Fees How to Charge - and Get", ["What You're Worth (Ultimate Consultant (Pfeiffer))-Pfeiffer (2008)"])
    got = outcome(b, FileName.decide(b, "Alan Weiss - Value-Based Fees_ How to Charge - and Get - What You're Worth (Ultimate Consultant (Pfeiffer))-Pfeiffer (2008).pdf", nil, now(b)))
    {got[0], got[1], got[2]}.should eq({"Value-Based Fees: How to Charge - and Get - What You're Worth", ["Alan Weiss"], "Pfeiffer"})
  end

  it "keeps the file's fuller title of the same book" do
    b = book("A Passion for Mathematics: Numbers, Puzzles, Madness", ["A Passion for Mathematics"])
    got = outcome(b, FileName.decide(b, "Clifford A. Pickover - A Passion for Mathematics.pdf", nil, now(b)))
    {got[0], got[1]}.should eq({"A Passion for Mathematics: Numbers, Puzzles, Madness", ["Clifford A. Pickover"]})
  end

  it "leaves a title of the file alone that isn't a leftover (accents, a chapter)" do
    b = book("Balança o corpo sinha", ["Andreas"])
    FileName.decide(b, "Balanca o corpo sinha.pdf", nil, now(b)).not_nil![0].should be_empty
    b = book("Chapter 1: Reasoning in Geometry", ["Sally Author"])
    FileName.decide(b, "chap01.pdf", nil, now(b)).not_nil![0].should be_empty
  end

  it "doesn't trust a name over a book with an ISBN" do
    b = book("Glitch", ["Jeff Papows"], isbn: "9780132160636")
    FileName.decide(b, "Glitch - The Hidden Impact of Faulty Software.pdf", nil, now(b)).not_nil![0].should be_empty
    # its author from a catalog stays, a book without one is decided
    b = book("Aphrodisiacs, Sex Toys, and Games", ["Adams Media"], isbn: "9781440500000")
    FileName.weak_authors?(b).should be_false
    FileName.weak_authors?(book("Aphrodisiacs, Sex Toys, and Games", ["Adams Media"])).should be_true
  end

  it "tags a file whose title and author are another book than its name" do
    b = book("Peer To Peer Computing: The Evolution Of A Disruptive Technology", ["Brian D. Goodman"])
    outcome(b, FileName.decide(b, "Cole - Network Security Bible (Wiley, 2005).pdf", nil, now(b)))
      .should eq({b.title, b.authors, nil, "unsure", true})
  end

  it "puts a subtitle out of the authors even when nobody decides the name" do
    b = book("Wine Tasting", ["A Professional Handbook"])
    outcome(b, FileName.decide(b, "Wine Tasting - A Professional Handbook.pdf", nil, now(b)))
      .should eq({"Wine Tasting: A Professional Handbook", ["Unknown"], nil, "unsure", true})
  end
end

describe "what never is an author or in a title" do
  it "knows what isn't a person" do
    ["Pearson", "Glencoe/McGraw-Hill", "Gale Group", "A Comprehensive Foundation 2e (Pearson, 1999)", "3rd Edition",
     "HyperGEAR TIFF/PDF Convert Library", "Click here to log on", "How To Make Money", "ScanKromsator", "Default",
     "TEAM LinG", "Self Teaching Guide", "Blake Masters // formatting by Max Olson", "The Essential Psychedelic Guide"].each do |a|
      FileName.bad_author?(a).should be_true
    end
    ["Jeff Papows", "Donald E. Knuth", "Tanenbaum", "J. Sabate", "Stuart Hall", "Peter Power", "Ursula K. Le Guin"].each do |a|
      FileName.bad_author?(a).should be_false
    end
  end

  it "doesn't take a title for 'Last, First'" do
    Meta::Clean.invert("Principles, Techniques").should eq "Principles, Techniques"
    Meta::Clean.invert("Tolkien, J. R. R.").should eq "J. R. R. Tolkien"
  end

  {
    {"Unix Shell Programming, Third Edition @Team LiB.pdf", "Unix Shell Programming"},
    {"Classic Shell Scripting @Team DDU.pdf", "Classic Shell Scripting"},
    {"The Nature of Design eBook-EEn.pdf", "The Nature of Design"},
    {"Hacker's Delight - Ripped by Caudex 2003.pdf", "Hacker's Delight"},
    {"The C Programming Language (Second Edition).pdf", "The C Programming Language"},
    {"The Mythical Man Month (Anniversary Edition).pdf", "The Mythical Man Month"},
    {"Algebra Abstract edn 2.5.pdf", "Algebra Abstract"},
    {"Introduction to Geometry 2ed.djvu", "Introduction to Geometry"},
    {"The History of Mathematics, 6th Edition.pdf", "The History of Mathematics"},
    {"Cameron Introduction to Algebra [modern,theory].pdf", "Cameron Introduction to Algebra"},
    {"Networking for Dummies--For Dummies; 7th Ed.pdf", "Networking for Dummies"},
  }.each do |name, title|
    it "cleans #{name}" do
      FileName.parse(name).not_nil!.title.should eq title
    end
  end
end

describe Meta::CrossCheck do
  title_only = Meta::Guess.new("The Pragmatic Programmer: From Journeyman to Master", [] of String)

  it "confirms an author two catalogs agree on" do
    v = Meta::CrossCheck.verdict(title_only, [
      candidate("openlibrary", "The Pragmatic Programmer", ["Andrew Hunt", "David Thomas"]),
      candidate("hardcover", "The Pragmatic Programmer", ["Andrew Hunt", "David Thomas"], "From Journeyman to Master"),
    ]).not_nil!
    v.confirmed.should be_true
    v.authors.should eq ["Andrew Hunt", "David Thomas"]
    v.sources.sort.should eq ["hardcover", "openlibrary"]
    v.source.should eq "hardcover"
  end

  it "doesn't take one catalog's word for a title without an author" do
    v = Meta::CrossCheck.verdict(title_only, [candidate("openlibrary", "The Pragmatic Programmer", ["Andrew Hunt"])]).not_nil!
    v.confirmed.should be_false
    v.authors.should eq ["Andrew Hunt"]
  end

  it "stays unsure when the catalogs disagree" do
    v = Meta::CrossCheck.verdict(title_only, [
      candidate("openlibrary", "The Pragmatic Programmer", ["Andrew Hunt"]),
      candidate("hardcover", "The Pragmatic Programmer", ["Somebody Else"]),
    ]).not_nil!
    v.confirmed.should be_false
    # and when two agree against two
    v = Meta::CrossCheck.verdict(title_only, [
      candidate("openlibrary", "The Pragmatic Programmer", ["Andrew Hunt"]),
      candidate("hardcover", "The Pragmatic Programmer", ["Andrew Hunt"]),
      candidate("openlibrary", "The Pragmatic Programmer", ["Somebody Else"]),
      candidate("dnb", "The Pragmatic Programmer", ["Somebody Else"]),
    ]).not_nil!
    v.confirmed.should be_false
  end

  it "takes a short title for nothing, even from two catalogs" do
    short = Meta::Guess.new("Game Theory", [] of String)
    Meta::CrossCheck.verdict(short, [candidate("openlibrary", "Game Theory", ["Roger Myerson"]), candidate("hardcover", "Game Theory", ["Roger Myerson"])]).should be_nil
    # a subtitle makes it a title
    long = Meta::Guess.new("Compilers: Principles, Techniques and Tools", [] of String)
    v = Meta::CrossCheck.verdict(long, [
      candidate("openlibrary", "Compilers", ["Alfred V. Aho"], "principles, techniques, and tools"),
      candidate("hardcover", "Compilers", ["Alfred V. Aho"], "Principles, Techniques, and Tools"),
      candidate("openlibrary", "Compilers", ["Niklaus Wirth"]),
    ]).not_nil!
    v.confirmed.should be_true
    v.authors.should eq ["Alfred V. Aho"]
  end

  it "only suggests a book a catalog has without the subtitle, by a short name" do
    g = Meta::Guess.new("Code Complete: A Practical Handbook of Software Construction", [] of String)
    v = Meta::CrossCheck.verdict(g, [candidate("openlibrary", "Code Complete", ["Steve McConnell"]), candidate("hardcover", "Code Complete", ["Steve McConnell"])]).not_nil!
    v.confirmed.should be_false
    v.authors.should eq ["Steve McConnell"]
  end

  it "leaves books about the book out" do
    Meta::CrossCheck.verdict(title_only, [candidate("openlibrary", "The Pragmatic Programmer: Summary", ["Quick Reads"])]).should be_nil
  end

  it "takes a catalog that names the book and the reading's author" do
    g = Meta::Guess.new("Hacker's Delight", ["Warren"])
    v = Meta::CrossCheck.verdict(g, [candidate("openlibrary", "Hacker's Delight", ["Henry S. Warren"])]).not_nil!
    v.confirmed.should be_true
    v.authors.should eq ["Henry S. Warren"]
    Meta::CrossCheck.verdict(g, [candidate("openlibrary", "Hacker's Delight", ["Somebody Else"])]).not_nil!.confirmed.should be_false
  end

  it "trusts an ISBN" do
    sure = candidate("openlibrary", "Something Else", ["Isbn Author"], by_isbn: "9780000000000").tap(&.sure = true)
    Meta::CrossCheck.verdict(title_only, [sure]).not_nil!.confirmed.should be_true
  end
end

describe "the catalogs in a decision" do
  name = "09 - The Pragmatic Programmer - From Journeyman to Master.pdf"
  leftover = book("09 - The Pragmatic Programmer", ["From Journeyman to Master"])

  it "takes confirmed authors with the title" do
    checker = ->(_b : CalibreHub::Book, g : Meta::Guess) do
      g.authors.should be_empty
      Meta::Verdict.new(true, "The Pragmatic Programmer", ["Andrew Hunt", "David Thomas"], "hardcover", ["hardcover", "openlibrary"]).as(Meta::Verdict?)
    end
    outcome(leftover, FileName.decide(leftover, name, nil, now(leftover), nil, checker))
      .should eq({"The Pragmatic Programmer: From Journeyman to Master", ["Andrew Hunt", "David Thomas"], nil, "hardcover", false})
  end

  it "only suggests what they can't confirm, with the unsure tag" do
    checker = ->(_b : CalibreHub::Book, _g : Meta::Guess) { Meta::Verdict.new(false, "The Pragmatic Programmer", ["Andrew Hunt"], "openlibrary", ["openlibrary"]).as(Meta::Verdict?) }
    changes, how = FileName.decide(leftover, name, nil, now(leftover), nil, checker).not_nil!
    how.should eq "unsure"
    h = changes.to_h { |c| {c.field, c.new} }
    h["authors"].should eq JSON.parse(%(["Unknown"]))
    h["tags"].should eq JSON.parse(%(["auto-unsicher"]))
    h[FileName::CANDIDATE]["authors"].should eq JSON.parse(%(["Andrew Hunt"]))
  end

  it "stays with the rules when no catalog knows the book" do
    checker = ->(_b : CalibreHub::Book, _g : Meta::Guess) { nil.as(Meta::Verdict?) }
    outcome(leftover, FileName.decide(leftover, name, nil, now(leftover), nil, checker))[3].should eq "name"
  end

  it "doesn't ask about a book with a clear author" do
    checker = ->(_b : CalibreHub::Book, _g : Meta::Guess) { raise "asked"; nil.as(Meta::Verdict?) }
    b = book("Carr", ["Formulas"])
    FileName.decide(b, "Carr - Formulas (Chelsea, 1970).pdf", nil, now(b), nil, checker).not_nil![1].should eq "name"
  end

  it "fills an unknown author in a metadata run only from what the catalogs confirm" do
    b = book("The Pragmatic Programmer", ["Unknown"])
    g = Meta::Guess.new("The Pragmatic Programmer", [] of String)
    one = candidate("openlibrary", "The Pragmatic Programmer", ["Andrew Hunt"])
    h = Meta::Merge.plan(b, g, nil, [one]).to_h { |c| {c.field, c.new} }
    h.has_key?("authors").should be_false
    h["tags"].should eq JSON.parse(%(["auto-unsicher"]))
    two = candidate("hardcover", "The Pragmatic Programmer", ["Andrew Hunt"])
    h = Meta::Merge.plan(book("The Pragmatic Programmer", ["Unknown"], tags: ["auto-unsicher"]), g, nil, [one, two]).to_h { |c| {c.field, c.new} }
    h["authors"].should eq JSON.parse(%(["Andrew Hunt"]))
    h["tags"].should eq JSON.parse("[]")
  end

  it "replaces an author that is no person the same way, but not a book's with an ISBN" do
    g = Meta::Guess.new("The Pragmatic Programmer", ["How To Make Money"])
    list = [candidate("openlibrary", "The Pragmatic Programmer", ["Andrew Hunt"]), candidate("hardcover", "The Pragmatic Programmer", ["Andrew Hunt"])]
    Meta::Merge.plan(book("The Pragmatic Programmer", ["How To Make Money"]), Meta::Guess.new("The Pragmatic Programmer", [] of String), nil, list)
      .find! { |c| c.field == "authors" }.new.should eq JSON.parse(%(["Andrew Hunt"]))
    Meta::Merge.plan(book("The Pragmatic Programmer", ["How To Make Money"], isbn: "9780000000000"), g, nil, list).any? { |c| c.field == "authors" }.should be_false
  end
end

describe "titles and names" do
  it "writes a shouted title normally, its acronyms in capitals" do
    FileName.clean_title("UNIX NETWORK PROGRAMMING").should eq "UNIX Network Programming"
    FileName.clean_title("UNDERSTANDING DNA").should eq "Understanding DNA"
    FileName.clean_title("UNIX").should eq "UNIX"
    FileName.clean_title("C++").should eq "C++"
  end

  it "reads a name with what a list left on it" do
    g = FileName.parse("Yoshida K. -  Functional analysis (Springer, 1980)(256s).djvu").not_nil!
    {g.title, g.authors, g.publisher, g.year}.should eq({"Functional analysis", ["K. Yoshida"], "Springer", 1980})
    FileName.parse("The GALE Encyclopedia of Science, Vol1(857s).pdf").not_nil!.title.should eq "The GALE Encyclopedia of Science, Vol1"
    FileName.parse("History of Rock (1960s).pdf").not_nil!.title.should eq "History of Rock (1960s)"
  end

  it "takes a volume's subject for no author, a person after a volume stays" do
    g = FileName.parse("Vol 17 - Cumulative Index.pdf").not_nil!
    {g.title, g.authors}.should eq({"Vol 17: Cumulative Index", [] of String})
    g = FileName.parse("Vol 03 - Insects.djvu").not_nil!
    {g.title, g.authors}.should eq({"Vol 03: Insects", [] of String})
    FileName.parse("Vol 3 - Donald E. Knuth.pdf").not_nil!.authors.should eq ["Donald E. Knuth"]
    FileName.parse("Grzimek's SALR - Amphibians.pdf").not_nil!.authors.should be_empty
    FileName.parse("Le - Introductory Biostatistics (Wiley, 2003).pdf").not_nil!.authors.should eq ["Le"]
  end
end

describe Meta::Http do
  it "waits out a host that says too many requests" do
    calls = 0
    server = HTTP::Server.new do |ctx|
      calls += 1
      ctx.response.status_code = 429
      ctx.response.headers["Retry-After"] = "30"
    end
    address = server.bind_unused_port
    spawn { server.listen }
    http = Meta::Http.new(Time::Span.zero, 2.seconds)
    url = "http://127.0.0.1:#{address.port}/"
    expect_raises(Meta::SourceError, /429/) { http.get(url) }
    expect_raises(Meta::SourceError, /rate limited/) { http.get(url) }
    calls.should eq 1
    server.close
  end
end
