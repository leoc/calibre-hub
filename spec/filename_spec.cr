require "spec"
require "../src/calibre_hub/meta_filename"

private alias FileName = CalibreHub::Meta::FileName

private def book(title : String, authors : Array(String), publisher : String? = nil) : CalibreHub::Book
  CalibreHub::Book.new(id: 1_i64, title: title, authors: authors, author_sort: CalibreHub::Meta::AuthorSort.for(authors),
    tags: [] of String, series: nil, series_index: nil, formats: ["PDF"], last_modified: Time::UNIX_EPOCH,
    timestamp: nil, pubdate: nil, rating: nil, publisher: publisher, identifiers: {} of String => String,
    languages: [] of String, comments: nil, custom: {} of String => JSON::Any)
end

private def now(b : CalibreHub::Book)
  ->(field : String) { CalibreHub::Meta::Merge.value(b, field).as(JSON::Any?) }
end

describe CalibreHub::Meta::FileName do
  # real names from the backlog (dmt, 03.11.): name => title, authors,
  # publisher, year, series and number; hint: the folder's orientation
  {
    {"Carr - Formulas and Theorems in Pure Mathematics 2e (Chelsea, 1970).djvu", nil,
     "Formulas and Theorems in Pure Mathematics", ["Carr"], "Chelsea", 1970, nil},
    {"Duffy - Advanced Engineering Mathematics (1998).pdf", nil, "Advanced Engineering Mathematics", ["Duffy"], nil, 1998, nil},
    {"Jungnickel - Graphs, Networks and Algorithms 3e (Springer, 2008).pdf", nil, "Graphs, Networks and Algorithms", ["Jungnickel"], "Springer", 2008, nil},
    {"Eisenberg - SVG Essentials (O'Reilly, 2002).pdf", nil, "SVG Essentials", ["Eisenberg"], "O'Reilly", 2002, nil},
    {"Munshi - OpenGL ES 2.0 Programming Guide (AW, 2008).pdf", nil, "OpenGL ES 2.0 Programming Guide", ["Munshi"], "Addison-Wesley", 2008, nil},
    {"Shreiner - OpenGL Programming Guide 6e [The Redbook] (AW, 2008).pdf", nil, "OpenGL Programming Guide [The Redbook]", ["Shreiner"], "Addison-Wesley", 2008, nil},
    {"Foundations of 3D Graphics Programming - J. Chen, E. Wegman (Springer, 2006) WW.pdf", nil,
     "Foundations of 3D Graphics Programming", ["J. Chen", "E. Wegman"], "Springer", 2006, nil},
    {"Comprehensive Mathematics for Computer Scientists 2nd ed [Vol 1] - G. Mazzola, et al., (Springer, 2006) WW.pdf", nil,
     "Comprehensive Mathematics for Computer Scientists [Vol 1]", ["G. Mazzola"], "Springer", 2006, nil},
    {"Non-Euclidean Geometry 6th ed. - H.S.M. Coxeter (1998) WW.djvu", nil, "Non-Euclidean Geometry", ["H.S.M. Coxeter"], nil, 1998, nil},
    {"Algebraic geometry I-V - Shafarevich I.R.djvu", nil, "Algebraic geometry I-V", ["I. R. Shafarevich"], nil, nil, nil},
    {"Fundamentals of Risk Analysis and Risk Management - V. Molak (ed) (CRC, 1997) WW.pdf", nil,
     "Fundamentals of Risk Analysis and Risk Management", ["V. Molak"], "CRC Press", 1997, nil},
    {"Sam Carpenter - Work the System_ The Simple Mechanics of Making More and Working Less (2009).pdf", nil,
     "Work the System: The Simple Mechanics of Making More and Working Less", ["Sam Carpenter"], nil, 2009, nil},
    {"James Altucher, Dick Costolo - Choose Yourself!-CreateSpace Independent Publishing Platform (2013).epub", nil,
     "Choose Yourself!", ["James Altucher", "Dick Costolo"], "CreateSpace Independent Publishing Platform", 2013, nil},
    {"Tom DeMarco, Tim Lister - Peopleware_ Productive Projects and Teams-Addison-Wesley Professional (2013).pdf", nil,
     "Peopleware: Productive Projects and Teams", ["Tom DeMarco", "Tim Lister"], "Addison-Wesley Professional", 2013, nil},
    {"Morgan Housel - The Psychology of Money_ Timeless Lessons on Wealth, Greed, and Happiness-Harriman House (2020).epub", nil,
     "The Psychology of Money: Timeless Lessons on Wealth, Greed, and Happiness", ["Morgan Housel"], "Harriman House", 2020, nil},
    {"Dave Ulrich_ Norm Smallwood_ Kate Sweetman - The Leadership Code-Harvard Business Review Press.epub", nil,
     "The Leadership Code", ["Dave Ulrich", "Norm Smallwood", "Kate Sweetman"], "Harvard Business Review Press", nil, nil},
    {"Hans Rosling, Ola Rosling, Anna Rosling Rönnlund - Factfulness_ Ten Reasons We’re Wrong About the World—and Why Things Are Better Than You Think (2018, Flatiron Books) - libgen.lc.epub", nil,
     "Factfulness: Ten Reasons We’re Wrong About the World—and Why Things Are Better Than You Think",
     ["Hans Rosling", "Ola Rosling", "Anna Rosling Rönnlund"], "Flatiron Books", 2018, nil},
    {"Stroh, David Peter - Systems thinking for social change _ a practical guide to solving complex problems _ avoiding unintended consequences, and achieving lasting results (2015, Chelsea Green Publishing) - libgen.lc.epub", nil,
     "Systems thinking for social change: a practical guide to solving complex problems: avoiding unintended consequences, and achieving lasting results",
     ["David Peter Stroh"], "Chelsea Green Publishing", 2015, nil},
    {"Vivian Zayas, Cindy Hazan (eds.) - Bases of Adult Attachment_ Linking Brain, Mind and Behavior-Springer-Verlag New York (2015).pdf", nil,
     "Bases of Adult Attachment: Linking Brain, Mind and Behavior", ["Vivian Zayas", "Cindy Hazan"], "Springer-Verlag New York", 2015, nil},
    {"Einfuhrung in die Technische Informatik - Schildsek, J. & Pangratz, H. & Redlein, A. & Schmid, U. & Stockler, S_.pdf", nil,
     "Einfuhrung in die Technische Informatik", ["J. Schildsek", "H. Pangratz", "A. Redlein", "U. Schmid", "S. Stockler"], nil, nil, nil},
    {"Grundlagen der Technischen Informatik - Hoffmann, Dirk W_.pdf", nil, "Grundlagen der Technischen Informatik", ["Dirk W. Hoffmann"], nil, nil, nil},
    {"King, Stephen - The Stand (Uncut).mobi", nil, "The Stand (Uncut)", ["Stephen King"], nil, nil, nil},
    {"Turow, Scott - the Burden Of Proof (1990).mobi", nil, "The Burden Of Proof", ["Scott Turow"], nil, 1990, nil},
    {"Cussler, Clive - Dirk Pitt 12 - Inca Gold (1994).mobi", nil, "Inca Gold", ["Clive Cussler"], nil, 1994, {"Dirk Pitt", 12.0}},
    {"Evanovich, Janet - Stephanie Plum 05 - High Five.mobi", nil, "High Five", ["Janet Evanovich"], nil, nil, {"Stephanie Plum", 5.0}},
    # kindle folders: "Title - Author", series in front
    {"The Grand Design - Stephen Hawking.pdf", nil, "The Grand Design", ["Stephen Hawking"], nil, nil, nil},
    {"Mr. Murder - Dean R. Koontz.mobi", nil, "Mr. Murder", ["Dean R. Koontz"], nil, nil, nil},
    {"Sten 03 - The Court of a Thousand Suns - Chris Bunch.mobi", nil, "The Court of a Thousand Suns", ["Chris Bunch"], nil, nil, {"Sten", 3.0}},
    {"Wheel of Time 06 - Lord of Chaos - Robert Jordan.mobi", nil, "Lord of Chaos", ["Robert Jordan"], nil, nil, {"Wheel of Time", 6.0}},
    {"Witch World - Estcarp Cycle 03 - Three A - Andre Norton.mobi", nil, "Three A", ["Andre Norton"], nil, nil, {"Witch World - Estcarp Cycle", 3.0}},
    {"Chrysalids, The - John Wyndham.mobi", nil, "The Chrysalids", ["John Wyndham"], nil, nil, nil},
    {"Prolog Programming - A First Course - Paul Brna.pdf", nil, "Prolog Programming - A First Course", ["Paul Brna"], nil, nil, nil},
    {"An Introduction to Genetic Algorithms - Melanie Mitchell.pdf", nil, "An Introduction to Genetic Algorithms", ["Melanie Mitchell"], nil, nil, nil},
    # a tie decided by the folder
    {"Get Shorty - Elmore Leonard.mobi", :last, "Get Shorty", ["Elmore Leonard"], nil, nil, nil},
    {"Dune - Herbert.mobi", :last, "Dune", ["Herbert"], nil, nil, nil},
    {"Dune - Herbert.mobi", :first, "Herbert", ["Dune"], nil, nil, nil},
    # no person on either side: one title, no author
    {"Wine Tasting - A Professional Handbook.pdf", nil, "Wine Tasting - A Professional Handbook", [] of String, nil, nil, nil},
    {"The Road to Reality - A Complete Guide to the Laws of the Universe.pdf", nil,
     "The Road to Reality - A Complete Guide to the Laws of the Universe", [] of String, nil, nil, nil},
    {"Distributed Systems - Principles and Paradigms (2002).pdf", nil, "Distributed Systems - Principles and Paradigms", [] of String, nil, 2002, nil},
    {"07 - Compilers - Principles, Techniques and Tools (2nd Edition).pdf", nil, "Compilers - Principles, Techniques and Tools", [] of String, nil, nil, nil},
    {"12 - The Little Schemer (4th Edition).pdf", nil, "The Little Schemer", [] of String, nil, nil, nil},
    {"O'Reilly - Server Load Balancing.pdf", nil, "Server Load Balancing", [] of String, "O'Reilly", nil, nil},
    {"AI Techniques For Game Programming (Premier Press, 2002).pdf", nil, "AI Techniques For Game Programming", [] of String, "Premier Press", 2002, nil},
    # file junk
    {"Pragmatic_Thinking_and_Learning_-_Refactor_Your_Wetware.pdf", nil, "Pragmatic Thinking and Learning - Refactor Your Wetware", [] of String, nil, nil, nil},
    {"Paradigms.of.Artificial.Intelligence.Programming.pdf", nil, "Paradigms of Artificial Intelligence Programming", [] of String, nil, nil, nil},
    {"Wiley.Knowledge.Based.Bioinformatics.Sep.2010.eBook-ELOHiM.pdf", nil, "Knowledge Based Bioinformatics", [] of String, "Wiley", 2010, nil},
    {"Programming.Principles.and.Practice.Using.C++.(2008).eBook.iNT-TD.pdf", nil, "Programming Principles and Practice Using C++", [] of String, nil, 2008, nil},
    {"Methoden der Computeranimation (eXamen.press) (German Edition) PDF.pdf", nil, "Methoden der Computeranimation (eXamen.press)", [] of String, nil, nil, nil},
    {"Basic Engineering Mathematics [by John Bird].pdf", nil, "Basic Engineering Mathematics", ["John Bird"], nil, nil, nil},
    {"John Caples, Fred E. Hahn - Tested Advertising Methods (Business Classics Series)-Prentice Hall (1997).pdf", nil,
     "Tested Advertising Methods", ["John Caples", "Fred E. Hahn"], "Prentice Hall", 1997, {"Business Classics Series", nil}},
    {"Medtner (1880 - 1951) - Piano Quintet in C major, Op. posth. (violin II).pdf", nil, "Piano Quintet in C major, Op. posth. (violin II)", ["Medtner"], nil, nil, nil},
    {"MongoDB Cookbook, Second Edition.pdf", nil, "MongoDB Cookbook, Second Edition", [] of String, nil, nil, nil},
  }.each do |name, hint, title, authors, publisher, year, series|
    it "reads #{name[0, 70].inspect}#{hint ? " (folder: #{hint})" : ""}" do
      g = FileName.parse(name, hint).not_nil!
      {g.title, g.authors, g.publisher, g.year}.should eq({title, authors, publisher, year})
      {g.series, g.series_index}.should eq(series || {nil, nil})
      g.pubdate.should eq(year.try(&.to_s))
    end
  end

  it "says how a name was decided, and gives every reading of an unclear one" do
    FileName.readings("Carr - Formulas (Chelsea, 1970).djvu").not_nil![1].should eq "name"
    FileName.readings("Dune - Herbert.mobi", :last).not_nil![1].should eq "folder"
    gs, how = FileName.readings("Herbert - Dune.mobi").not_nil!
    how.should eq "unclear"
    gs.map { |g| {g.title, g.authors} }.should eq [{"Dune", ["Herbert"]}, {"Herbert", ["Dune"]}, {"Herbert - Dune", [] of String}]
    gs, how = FileName.readings("Wine Tasting - A Professional Handbook.pdf").not_nil!
    how.should eq "unclear"
    gs.first.authors.should be_empty
  end

  it "decides an unclear name by the file, the decider, else tags it for a review" do
    name = "Herbert - Dune.pdf"
    calibre_read = book("Herbert", ["Dune"])
    imported = now(calibre_read)
    # the decider (sources, model) picks a reading
    decider = ->(_b : CalibreHub::Book, _n : String, gs : Array(CalibreHub::Meta::Guess)) do
      gs.find { |g| g.authors == ["Dune"] }.try { |g| {g, "model"} }
    end
    changes, how = FileName.decide(calibre_read, name, nil, imported, decider).not_nil!
    how.should eq "model"
    changes.should be_empty
    # nobody decides: names stay, the tag
    changes, how = FileName.decide(calibre_read, name, nil, imported).not_nil!
    how.should eq "unsure"
    changes.map { |c| {c.field, c.new} }.should eq [{"tags", JSON.parse(%(["auto-unsicher"]))}]
    # the file's own author decides (an EPUB's OPF); title from the name
    own = book("Herbert", ["Frank Herbert"])
    changes, how = FileName.decide(own, name, nil, now(own)).not_nil!
    how.should eq "file"
    changes.map { |c| {c.field, c.new} }.should eq [{"title", JSON::Any.new("Dune")}]
    # a clear name needs nobody
    FileName.decide(book("Carr", ["Formulas"]), "Carr - Formulas (Chelsea, 1970).pdf", nil, now(book("Carr", ["Formulas"])), decider).not_nil![1].should eq "name"
  end

  it "leaves standards to Norms (calibre's split of the bracket form)" do
    FileName.parse("[DIN EN ISO 14971 2009-10] -- Medizinprodukte - Anwendung des Risikomanagements.pdf").should be_nil
  end

  # what calibre 9 makes of the names (calibre-debug, metadata_from_filename)
  {
    {"Carr - Formulas and Theorems in Pure Mathematics 2e (Chelsea, 1970).djvu", "Carr", ["Formulas", "Theorems in Pure Mathematics 2e (Chelsea, 1970)"]},
    {"Duffy - Advanced Engineering Mathematics (1998).pdf", "Duffy", ["Advanced Engineering Mathematics (1998)"]},
    {"Foundations of 3D Graphics Programming - J. Chen, E. Wegman (Springer, 2006) WW.pdf", "Foundations of 3D Graphics Programming", ["J. Chen, E. Wegman (Springer, 2006) WW"]},
    {"07 - Compilers - Principles, Techniques and Tools (2nd Edition).pdf", "07 - Compilers", ["Principles, Techniques", "Tools (2nd Edition)"]},
    {"Sam Carpenter - Work the System_ The Simple Mechanics of Making More and Working Less (2009).pdf", "Sam Carpenter",
     ["Work the System  The Simple Mechanics of Making More", "Working Less (2009)"]},
    {"Grundlagen der Technischen Informatik - Hoffmann, Dirk W_.pdf", "Grundlagen der Technischen Informatik", ["Hoffmann, Dirk W"]},
    {"Paradigms.of.Artificial.Intelligence.Programming.pdf", "Paradigms.of.Artificial.Intelligence.Programming", ["Unknown"]},
    {"Game Theory.pdf", "Game Theory", ["Unknown"]},
    {"Weinberg - Dreams of a Final Theory: The Search.pdf", "Weinberg", ["Dreams of a Final Theory  The Search"]},
  }.each do |name, title, authors|
    it "knows calibre's reading of #{name[0, 50].inspect}" do
      FileName.calibre(name).should eq({title, authors})
    end
  end

  it "tells which side of the folder's files names the author" do
    FileName.orientation(["Get Shorty - Elmore Leonard.mobi", "The Grand Design - Stephen Hawking.mobi", "Mr. Murder - Dean R. Koontz.mobi"]).should eq(:last)
    FileName.orientation(["Carr - Formulas (Chelsea, 1970).pdf", "Stephen King - The Stand.mobi", "J. Chen - Graphics.pdf"]).should eq(:first)
    FileName.orientation(["Stephen King - The Stand.mobi", "Mr. Murder - Dean R. Koontz.mobi"]).should be_nil
    FileName.orientation(["a.pdf", "b.pdf"]).should be_nil
  end

  it "spots titles a file brought along that say nothing" do
    ["chap01 7..24", "100767", "Less 0375505784 4p Fm R1.Qxd", "logik-stud.dvi", "file:///F|/Mis documentos/index.html",
     "test", "()", "\u0001", "Microsoft Word - Dokument1.doc"].each { |t| FileName.bad_title?(t).should be_true }
    ["The Grand Design", "SQL", "Dune", "1984"].each { |t| FileName.bad_title?(t).should be_false }
  end

  it "takes the file name only where the book has calibre's reading of it" do
    name = "Carr - Formulas and Theorems in Pure Mathematics 2e (Chelsea, 1970).djvu"
    g = FileName.parse(name).not_nil!
    b = book("Carr", ["Formulas", "Theorems in Pure Mathematics 2e (Chelsea, 1970)"])
    changes = FileName.changes(b, name, g, now(b))
    changes.to_h { |c| {c.field, c.new} }.should eq({
      "title" => JSON::Any.new("Formulas and Theorems in Pure Mathematics"), "authors" => JSON.parse(%(["Carr"])),
      "authorSort" => JSON::Any.new("Carr"), "publisher" => JSON::Any.new("Chelsea"), "pubdate" => JSON::Any.new("1970"),
    })
    changes.map(&.source).uniq.should eq(["rules"])
    # the file's own title and authors (a PDF's info dict) stay, the publisher is filled
    b = book("Formulas and Theorems in Pure Mathematics, Second Edition", ["Leonard James Carr"])
    FileName.changes(b, name, g, now(b)).map(&.field).should eq(["publisher", "pubdate"])
    # a file title that says nothing goes, the authors with it
    b = book("chap01 7..24", ["Karen Bresswein"])
    FileName.changes(b, name, g, now(b)).map(&.field).should eq(["title", "authors", "authorSort", "publisher", "pubdate"])
    # nothing from the name: no author, calibre's "Unknown"
    name = "Wine Tasting - A Professional Handbook.pdf"
    b = book("Wine Tasting", ["A Professional Handbook"])
    FileName.changes(b, name, FileName.parse(name).not_nil!, now(b)).to_h { |c| {c.field, c.new} }.should eq({
      "title" => JSON::Any.new("Wine Tasting - A Professional Handbook"), "authors" => JSON.parse(%(["Unknown"])),
      "authorSort" => JSON::Any.new("Unknown"),
    })
    # a field changed since the import (imported: nil) stays
    FileName.changes(b, name, FileName.parse(name).not_nil!, ->(_f : String) { nil.as(JSON::Any?) }).should be_empty
  end
end
