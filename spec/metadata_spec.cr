require "spec"
require "kemal"
require "compress/zip"
require "../src/calibre_hub/api"

private FIXTURES = "#{__DIR__}/fixtures/metadata"
private JPEG     = Bytes[0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 0x4A, 0x46, 0x49, 0x46]

private def fixture(name) : String
  File.read(File.join(FIXTURES, name))
end

# calibre-server: list (with cover), search by id/author, categories,
# set-fields; like calibre, new authors get calibre's sort and every write
# bumps last_modified
private class FakeLibrary
  getter books = {} of Int64 => Hash(String, JSON::Any)
  getter covers = Set(Int64).new
  getter writes = [] of {Int64, JSON::Any}
  getter url : String
  # changes the book behind the hub's back on the next set-fields
  property interfere : Proc(Nil)?

  def initialize
    @server = HTTP::Server.new do |ctx|
      path = ctx.request.path
      body = JSON.parse(ctx.request.body.try(&.gets_to_end).presence || "null")
      ctx.response.content_type = "application/json"
      case path
      when "/cdb/cmd/list/0"
        search = body[3].as_s
        ids = search.empty? ? @books.keys : search.scan(/id:(\d+)/).map(&.[1].to_i64).select { |id| @books.has_key?(id) }
        fields = body[0].as_a.map(&.as_s.sub('*', '#'))
        data = fields.to_h do |f|
          {f, ids.to_h { |id| {id.to_s, f == "cover" ? JSON::Any.new(@covers.includes?(id) ? "/lib/#{id}/cover.jpg" : nil) : (@books[id][f]? || JSON::Any.new(nil))} }}
        end
        ctx.response.print({result: {book_ids: ids, data: data}}.to_json)
      when "/cdb/cmd/list_categories/0"
        counts = Hash(String, Int32).new(0)
        @books.each_value { |b| b["authors"].as_a.each { |a| counts[a.as_s] += 1 } }
        cats = {"authors" => counts.map { |k, n| {name: k, count: n} }}
        ctx.response.print({result: [cats, {} of String => String]}.to_json)
      when "/ajax/search"
        query = ctx.request.query_params["query"]
        ids = if m = query.match(/authors:"=(.*)"/)
                @books.select { |_, b| b["authors"].as_a.any? { |a| a.as_s.downcase == m[1].downcase } }.keys
              else
                @books.keys
              end
        ctx.response.print({total_num: ids.size, book_ids: ids}.to_json)
      when .starts_with?("/cdb/set-fields/")
        @interfere.try { |i| @interfere = nil; i.call }
        id = path.split('/')[3].to_i64
        changes = body["changes"]
        @writes << {id, changes}
        changes.as_h.each do |k, v|
          case k
          when "cover"         then v.raw.nil? ? @covers.delete(id) : @covers << id
          when "last_modified" then nil
          when "authors"
            @books[id][k] = v
            @books[id]["author_sort"] = JSON::Any.new(CalibreHub::Meta::AuthorSort.for(v.as_a.map(&.as_s)))
          else @books[id][k] = v
          end
        end
        touch(id)
        ctx.response.print "{}"
      else
        ctx.response.status_code = 404
      end
    end
    address = @server.bind_tcp("127.0.0.1", 0)
    @url = "http://127.0.0.1:#{address.port}"
    spawn { @server.listen }
  end

  def touch(id)
    @books[id]["last_modified"] = JSON::Any.new(Time.utc.to_rfc3339(fraction_digits: 6))
    sleep 1.millisecond
  end

  def add(id : Int64, title : String, authors : Array(String), **fields)
    b = {
      "title"         => JSON::Any.new(title),
      "authors"       => JSON.parse(authors.to_json),
      "author_sort"   => JSON::Any.new(CalibreHub::Meta::AuthorSort.for(authors)),
      "tags"          => JSON.parse("[]"),
      "identifiers"   => JSON.parse("{}"),
      "languages"     => JSON.parse("[]"),
      "formats"       => JSON.parse(%(["EPUB"])),
      "last_modified" => JSON::Any.new("2026-11-02T10:00:00+00:00"),
    }
    fields.each { |k, v| b[k.to_s] = JSON.parse(v.to_json) }
    @books[id] = b
  end

  def calibre : CalibreHub::Calibre
    CalibreHub::Calibre.new(url, "hub", "pw", nil, [] of String)
  end
end

# Open Library, DNB and the covers from the recorded fixtures
private class FakeSources
  getter url : String
  getter requests = [] of String
  property down = false

  def initialize
    @server = HTTP::Server.new do |ctx|
      r = ctx.request
      @requests << r.resource
      if @down
        ctx.response.status_code = 503
        next
      end
      q = r.query_params
      case r.path
      when "/ol/api/books"
        ctx.response.print(q["bibkeys"] == "ISBN:9783608938289" ? fixture("openlibrary_isbn.json") : "{}")
      when "/ol/search.json"
        ctx.response.print(q["title"].downcase.includes?("left hand") ? fixture("openlibrary_search.json") : %({"docs": []}))
      when "/ol/works/OL59800W.json"
        ctx.response.print fixture("openlibrary_work.json")
      when "/ol/books/OL37766386M.json"
        ctx.response.print %({"languages": [{"key": "/languages/ger"}], "works": [{"key": "/works/OL27479W"}]})
      when "/dnb"
        query = q["query"]
        ctx.response.content_type = "application/xml"
        ctx.response.print case query
        when "num=9783608938289"  then fixture("dnb_isbn.xml")
        when "num=9783596164530"  then fixture("dnb_isbn_schwarm.xml")
        when /tit="Der Schwarm"/i then fixture("dnb_search.xml")
        else                           %(<searchRetrieveResponse xmlns="http://www.loc.gov/zing/srw/"><numberOfRecords>0</numberOfRecords></searchRetrieveResponse>)
        end
      when %r{\A/covers/b/id/\d+-L.jpg\z}
        ctx.response.content_type = "image/jpeg"
        ctx.response.write JPEG
      else
        ctx.response.status_code = 404
      end
    end
    address = @server.bind_tcp("127.0.0.1", 0)
    @url = "http://127.0.0.1:#{address.port}"
    spawn { @server.listen }
  end
end

private def record(**args)
  CalibreHub::Meta::Record.new(**args)
end

private def book(title = "Dune", authors = ["Frank Herbert"], author_sort : String? = nil, publisher : String? = nil,
                 isbn : String? = nil, languages = [] of String, comments : String? = nil, pubdate : Time? = nil,
                 series : String? = nil) : CalibreHub::Book
  CalibreHub::Book.new(id: 1_i64, title: title, authors: authors, author_sort: author_sort || CalibreHub::Meta::AuthorSort.for(authors),
    tags: [] of String, series: series, series_index: series ? 1.0 : nil, formats: [] of String, last_modified: Time::UNIX_EPOCH,
    timestamp: nil, pubdate: pubdate, rating: nil, publisher: publisher,
    identifiers: isbn ? {"isbn" => isbn} : {} of String => String,
    languages: languages, comments: comments, custom: {} of String => JSON::Any)
end

private def setup(read_file : CalibreHub::Metadata::FileReader? = nil, sources = %w(file openlibrary dnb))
  library = FakeLibrary.new
  web = FakeSources.new
  http = CalibreHub::Meta::Http.new(Time::Span.zero, 5.seconds)
  writer = CalibreHub::Writer.new(library.calibre, nil, nil, nil)
  db = DB.open("sqlite3://#{File.tempname("hub-metadata", ".sqlite")}?max_pool_size=1")
  db.exec "create table if not exists meta (key text primary key, value text)"
  db.exec "create table if not exists events (id integer primary key autoincrement, type text not null, book_id integer not null, payload text not null, created_at integer not null, done_at integer)"
  m = CalibreHub::Metadata.new(library.calibre, writer, CalibreHub::MetaLog.new(db), sources,
    CalibreHub::Meta::OpenLibrary.new(http, "#{web.url}/ol", "#{web.url}/covers"),
    CalibreHub::Meta::Dnb.new(http, "#{web.url}/dnb"), http, nil,
    read_file || ->(_b : CalibreHub::Book) { nil.as(CalibreHub::Meta::FileMeta::Info?) })
  jobs = CalibreHub::MetadataJobs.new(db, library.calibre, writer, m)
  {library, web, m, jobs, db}
end

private def wait_job(jobs, id) : CalibreHub::Jobs::Job
  300.times do
    job = jobs[id]?.not_nil!
    return job if job.status != "running"
    sleep 10.milliseconds
  end
  raise "job #{id} still running"
end

private def call(method, path, body = nil)
  io = IO::Memory.new
  request = HTTP::Request.new(method, path, HTTP::Headers{"X-Calibre-Hub" => "1"}, body)
  ctx = HTTP::Server::Context.new(request, HTTP::Server::Response.new(io))
  Kemal::RouteHandler::INSTANCE.call(ctx)
  ctx.response.close
  response = HTTP::Client::Response.from_io(IO::Memory.new(io.to_s))
  {response.status_code, JSON.parse(response.body)}
end

private def epub(opf : String, pages = {} of String => String) : String
  path = File.tempname("meta", ".epub")
  File.open(path, "w") do |f|
    Compress::Zip::Writer.open(f) do |zip|
      zip.add("mimetype", "application/epub+zip")
      zip.add("META-INF/container.xml", %(<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>))
      zip.add("OEBPS/content.opf", opf)
      pages.each { |name, html| zip.add("OEBPS/#{name}", html) }
    end
  end
  path
end

private SCHWARM_OPF = <<-XML
  <?xml version="1.0" encoding="utf-8"?>
  <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
    <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
      <dc:title>Der Schwarm</dc:title>
      <dc:creator opf:role="aut" opf:file-as="Schätzing, Frank">Frank Schätzing</dc:creator>
      <dc:creator opf:role="edt">Jemand Anders</dc:creator>
      <dc:identifier id="id">urn:uuid:1234</dc:identifier>
      <dc:identifier opf:scheme="ISBN">978-3-596-16453-0</dc:identifier>
      <dc:publisher>Fischer</dc:publisher>
      <dc:date>2005-03-01T00:00:00+00:00</dc:date>
      <dc:language>de</dc:language>
      <dc:description>Ein Roman über das Meer.</dc:description>
      <meta name="calibre:series" content="Meer"/>
      <meta name="calibre:series_index" content="2.0"/>
    </metadata>
    <manifest>
      <item id="c1" href="text/c1.xhtml" media-type="application/xhtml+xml"/>
      <item id="c2" href="text/c2.xhtml" media-type="application/xhtml+xml"/>
    </manifest>
    <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
  </package>
  XML

describe CalibreHub::Meta::Isbn do
  it "validates and normalizes ISBN-10 and -13" do
    CalibreHub::Meta::Isbn.normalize("978-3-608-93828-9").should eq("9783608938289")
    CalibreHub::Meta::Isbn.normalize("3608938281").should eq("9783608938289")
    CalibreHub::Meta::Isbn.normalize("0-8044-2957-X").should eq("9780804429573")
    CalibreHub::Meta::Isbn.normalize("978-3-608-93828-8").should be_nil
    CalibreHub::Meta::Isbn.normalize("1234567890123").should be_nil
  end

  it "finds ISBNs in text, labelled ones first" do
    text = "Mehr von uns: 978-3-596-16453-0. © 2009 Klett-Cotta, ISBN 978-3-608-93828-9, Tel. 0711 6672 1234"
    CalibreHub::Meta::Isbn.scan(text).should eq(["9783608938289", "9783596164530"])
    CalibreHub::Meta::Isbn.scan("ISBN-10: 3608938281").should eq(["9783608938289"])
    CalibreHub::Meta::Isbn.scan("Seite 1234567890").should be_empty
  end
end

describe CalibreHub::Meta::Clean do
  # {title, authors} -> {title, authors, series, index, ambiguous}
  {
    {"Tolkien - Der Herr der Ringe (z-lib.org)", ["Unbekannt"]}            => {"Der Herr der Ringe", ["Tolkien"], nil, nil, false},
    {"tolkien - der herr der ringe (z-lib.org)", ["Unknown"]}              => {"Der Herr der Ringe", ["Tolkien"], nil, nil, false},
    {"Der_Schwarm_-_Frank_Schätzing", ["Unknown"]}                         => {"Der Schwarm", ["Frank Schätzing"], nil, nil, false},
    {"Herbert, Frank - Dune", [] of String}                                => {"Dune", ["Frank Herbert"], nil, nil, false},
    {"Rowling - Harry Potter 03 - Der Gefangene von Askaban", ["Unknown"]} => {"Der Gefangene von Askaban", ["Rowling"], "Harry Potter", 3.0, false},
    {"Frank Herbert - Dune", ["Frank Herbert"]}                            => {"Dune", ["Frank Herbert"], nil, nil, false},
    {"Dune - Herbert", ["Frank Herbert"]}                                  => {"Dune", ["Frank Herbert"], nil, nil, false},
    {"DER PROZESS", ["FRANZ KAFKA"]}                                       => {"Der Prozess", ["Franz Kafka"], nil, nil, false},
    {"Dune", ["Herbert, Frank"]}                                           => {"Dune", ["Frank Herbert"], nil, nil, false},
    {"Die Verwandlung [libgen.li].epub", ["Franz Kafka"]}                  => {"Die Verwandlung", ["Franz Kafka"], nil, nil, false},
    {"the_hobbit", ["J.R.R. Tolkien"]}                                     => {"The Hobbit", ["J.R.R. Tolkien"], nil, nil, false},
    {"Der Talisman (2009)", ["Stephen King & Peter Straub"]}               => {"Der Talisman", ["Stephen King", "Peter Straub"], nil, nil, false},
    {"Star Wars - Episode I", ["Terry Brooks"]}                            => {"Star Wars - Episode I", ["Terry Brooks"], nil, nil, false},
    {"Microsoft Word - Bericht final", ["Admin"]}                          => {"Bericht final", [] of String, nil, nil, false},
    {"Frank Schätzing", ["Der Schwarm Roman"]}                             => {"Der Schwarm Roman", ["Frank Schätzing"], nil, nil, true},
    {"Wolken - Atlas", ["Unknown"]}                                        => {"Atlas", ["Wolken"], nil, nil, true},
    # found on the live library (02.11.): two authors in one field, acronyms
    {"Positioning", ["Al Ries, Jack Trout"]}                               => {"Positioning", ["Al Ries", "Jack Trout"], nil, nil, false},
    {"GAMP 5", ["ISPE"]}                                                   => {"GAMP 5", ["ISPE"], nil, nil, false},
    {"Guidance", ["CDRH CBER"]}                                            => {"Guidance", ["CDRH CBER"], nil, nil, false},
    {"Erdsee", ["Le Guin, Ursula K."]}                                     => {"Erdsee", ["Ursula K. Le Guin"], nil, nil, false},
    {"Hundert Jahre Einsamkeit", ["Garcia Marquez, Gabriel"]}              => {"Hundert Jahre Einsamkeit", ["Gabriel Garcia Marquez"], nil, nil, false},
  }.each do |(title, authors), (want_title, want_authors, series, index, ambiguous)|
    it "cleans #{title.inspect} by #{authors.inspect}" do
      guesses, amb = CalibreHub::Meta::Clean.guesses(title, authors)
      g = guesses.first
      {g.title, g.authors, g.series, g.series_index, amb}.should eq({want_title, want_authors, series, index, ambiguous})
    end
  end

  it "takes a year in brackets as a hint" do
    CalibreHub::Meta::Clean.guesses("Der Talisman (2009)", ["Stephen King"])[0].first.year.should eq(2009)
  end

  it "recognizes unknown authors and messy books" do
    CalibreHub::Meta::Clean.unknown_authors?(["Unbekannt"]).should be_true
    CalibreHub::Meta::Clean.unknown_authors?(["Anonymus", "Unknown"]).should be_false
    CalibreHub::Meta::Clean.messy?(book("Dune", ["Frank Herbert"])).should be_false
    CalibreHub::Meta::Clean.messy?(book("Dune_Messiah", ["Frank Herbert"])).should be_true
    CalibreHub::Meta::Clean.messy?(book("Dune", ["Herbert, Frank"])).should be_true
    CalibreHub::Meta::Clean.messy?(book("Star Wars - Episode I", ["Terry Brooks"])).should be_false
  end

  it "computes calibre's author sort and spots broken ones" do
    CalibreHub::Meta::AuthorSort.for("Ursula K. Le Guin").should eq("Guin, Ursula K. Le")
    CalibreHub::Meta::AuthorSort.for("Martin Luther King Jr.").should eq("King, Martin Luther Jr.")
    CalibreHub::Meta::AuthorSort.for(["Terry Pratchett", "Neil Gaiman"]).should eq("Pratchett, Terry & Gaiman, Neil")
    CalibreHub::Meta::AuthorSort.wrong?(book(author_sort: "Unbekannt")).should be_true
    CalibreHub::Meta::AuthorSort.wrong?(book(author_sort: "Dune")).should be_true
    CalibreHub::Meta::AuthorSort.wrong?(book(authors: ["Ursula K. Le Guin"], author_sort: "Le Guin, Ursula K.")).should be_false
    CalibreHub::Meta::AuthorSort.wrong?(book(author_sort: "Herbert, Frank")).should be_false
  end
end

describe CalibreHub::Meta::Score do
  ol = CalibreHub::Meta::OpenLibrary.parse_search(fixture("openlibrary_search.json"), "https://openlibrary.org", "https://covers.openlibrary.org")
  dnb = CalibreHub::Meta::Dnb.parse(fixture("dnb_search.xml"))

  it "scores title, authors, language and year" do
    guess = CalibreHub::Meta::Guess.new("The Left Hand of Darkness", ["Ursula K. LeGuin"])
    ranked = CalibreHub::Meta::Score.rank(ol.dup, [guess], ["eng"], [] of String)
    ranked.first.fields.title.should eq("The Left Hand of Darkness")
    ranked.first.score.should be >= CalibreHub::Meta::ACCEPT
    ranked.first.sure.should be_false
    # an omnibus with the title somewhere in it is no match
    ranked.last.score.should be < CalibreHub::Meta::ACCEPT
  end

  it "doesn't take translations for the original" do
    guess = CalibreHub::Meta::Guess.new("Der Schwarm", ["Frank Schätzing"])
    CalibreHub::Meta::Score.rank(dnb.dup, [guess], ["deu"], [] of String).all? { |c| c.score < CalibreHub::Meta::ACCEPT }.should be_true
  end

  it "is sure about an ISBN match that agrees with the book" do
    c = CalibreHub::Meta::Dnb.parse(fixture("dnb_isbn.xml")).first
    c.by_isbn = "9783608938289"
    guess = CalibreHub::Meta::Guess.new("Der Herr der Ringe", ["Tolkien"])
    CalibreHub::Meta::Score.rank([c], [guess], [] of String, [] of String).first.sure.should be_true
    # an ISBN from the text of another book (an ad page) isn't
    other = CalibreHub::Meta::Guess.new("Kochen für Anfänger", ["Tim Mälzer"])
    CalibreHub::Meta::Score.rank([c], [other], [] of String, [] of String).first.sure.should be_false
    # unless calibre or the OPF has it
    CalibreHub::Meta::Score.rank([c], [other], [] of String, ["9783608938289"]).first.sure.should be_true
  end

  it "proves nothing with a short title and no author" do
    guess = CalibreHub::Meta::Guess.new("Gedichte", [] of String)
    CalibreHub::Meta::Score.score(guess, [] of String, record(title: "Gedichte", authors: ["Goethe"])).should be < CalibreHub::Meta::ACCEPT
  end
end

describe "metadata sources" do
  it "parses an Open Library edition by ISBN" do
    c = CalibreHub::Meta::OpenLibrary.parse_books(fixture("openlibrary_isbn.json"), "9783608938289", "https://openlibrary.org", "https://covers.openlibrary.org").first
    f = c.fields
    f.title.should eq("Der Herr der Ringe")
    f.authors.should eq(["J.R.R. Tolkien"])
    f.isbn.should eq("9783608938289")
    f.publisher.should eq("Klett-Cotta Verlag")
    f.pubdate.should eq("2009-08-01")
    f.cover_url.should eq("https://covers.openlibrary.org/b/id/13147175-L.jpg?default=false")
    c.url.should eq("https://openlibrary.org/books/OL37766386M")
    c.by_isbn.should eq("9783608938289")
  end

  it "parses Open Library search results as works" do
    c = CalibreHub::Meta::OpenLibrary.parse_search(fixture("openlibrary_search.json"), "https://openlibrary.org", "https://covers.openlibrary.org").first
    c.fields.authors.should eq(["Ursula K. Le Guin"])
    c.fields.pubdate.should eq("1969")
    # many editions: no ISBN or publisher of one of them
    c.fields.isbn.should be_nil
    c.fields.publisher.should be_nil
    c.edition.should be_false
    c.ref.should eq("/works/OL59800W")
  end

  it "takes the work's description as paragraphs" do
    d = CalibreHub::Meta::OpenLibrary.description(fixture("openlibrary_work.json")).not_nil!
    d.should start_with("<p>")
    d.should contain("The Left Hand of Darkness")
    d.should_not contain("](http")
  end

  it "parses DNB MARC21 records" do
    c = CalibreHub::Meta::Dnb.parse(fixture("dnb_isbn.xml")).first
    f = c.fields
    f.title.should eq("Der Herr der Ringe")
    f.authors.should eq(["J. R. R. Tolkien"])
    f.isbn.should eq("9783608938289")
    f.publisher.should eq("Klett-Cotta")
    f.pubdate.should eq("2009")
    f.languages.should eq(["deu"])
    c.url.should eq("https://d-nb.info/99386712X")
    s = CalibreHub::Meta::Dnb.parse(fixture("dnb_isbn_schwarm.xml")).first.fields
    s.title.should eq("Der Schwarm")
    s.authors.should eq(["Frank Schätzing"])
    # "Fischer 16453" is the publisher's numbering, not a series
    s.series.should be_nil
    CalibreHub::Meta::Dnb.parse(fixture("dnb_search.xml")).size.should eq(3)
  end

  it "reads the OPF and the ISBN in the first pages of an EPUB" do
    path = epub(SCHWARM_OPF, {"text/c1.xhtml" => "<html><body><p>Copyright &#169; 2009, ISBN 978-3-608-93828-9</p></body></html>"})
    info = CalibreHub::Meta::FileMeta.read(path, "EPUB").not_nil!
    r = info.record
    r.title.should eq("Der Schwarm")
    r.authors.should eq(["Frank Schätzing"])
    r.isbn.should eq("9783596164530")
    r.publisher.should eq("Fischer")
    r.pubdate.should eq("2005-03-01")
    r.languages.should eq(["deu"])
    r.series.should eq("Meer")
    r.series_index.should eq(2.0)
    info.isbns.should eq(["9783608938289"])
  ensure
    path.try { |p| File.delete?(p) }
  end

  it "reads a PDF's info dict, without tool names" do
    r = CalibreHub::Meta::FileMeta.pdf_info("Title:          Microsoft Word - Kafka_Der_Process.doc\nAuthor:         Administrator\nPages:          3\n")
    r.title.should eq("Kafka Der Process")
    r.authors.should be_nil
    CalibreHub::Meta::FileMeta.pdf_info("Title: untitled\nAuthor: Franz Kafka").authors.should eq(["Franz Kafka"])
  end

  it "normalizes dates and languages" do
    CalibreHub::Meta::Dates.normalize("Aug 01, 2009").should eq("2009-08-01")
    CalibreHub::Meta::Dates.normalize("[2023]").should eq("2023")
    CalibreHub::Meta::Dates.normalize("c2005").should eq("2005")
    CalibreHub::Meta::Dates.normalize("juin 2024").should eq("2024")
    CalibreHub::Meta::Lang.list(["ger", "de-DE", "eng", "xx-1"]).should eq(["deu", "eng"])
  end
end

describe CalibreHub::Meta::Merge do
  sure = CalibreHub::Meta::Candidate.new("dnb", record(title: "Der Herr der Ringe", authors: ["J. R. R. Tolkien"],
    isbn: "9783608938289", publisher: "Klett-Cotta", pubdate: "2009", languages: ["deu"]), by_isbn: "9783608938289")
  sure.sure = true
  sure.score = 1.0
  text_match = CalibreHub::Meta::Candidate.new("openlibrary", record(title: "Der Herr der Ringe", authors: ["J.R.R. Tolkien"],
    publisher: "Hobbit Presse", pubdate: "1969", comments: "<p>Ringe</p>", cover_url: "http://c/1.jpg"))
  text_match.score = 0.8

  it "fills missing fields: file first, then the best candidate" do
    b = book("Der Herr der Ringe", ["J. R. R. Tolkien"])
    file = record(publisher: "Klett-Cotta Verlag", languages: ["deu"])
    changes = CalibreHub::Meta::Merge.plan(b, nil, file, [text_match], has_cover: false).to_h { |c| {c.field, {c.new.raw, c.source}} }
    changes["publisher"].should eq({"Klett-Cotta Verlag", "file"})
    changes["languages"][1].should eq("file")
    changes["pubdate"].should eq({"1969", "openlibrary"})
    changes["comments"].should eq({"<p>Ringe</p>", "openlibrary"})
    changes["cover"].should eq({"http://c/1.jpg", "openlibrary"})
    changes.has_key?("title").should be_false
    changes.has_key?("isbn").should be_false
  end

  it "never replaces a good value with a less sure one" do
    b = book("Der Herr der Ringe", ["J. R. R. Tolkien"], publisher: "Klett", comments: "<p>Eigene</p>",
      pubdate: Time.utc(1972, 1, 1, 12, 0, 0), languages: ["deu"])
    CalibreHub::Meta::Merge.plan(b, nil, nil, [text_match]).should be_empty
    # unsure: below ACCEPT nothing is used
    weak = CalibreHub::Meta::Candidate.new("openlibrary", record(title: "Der Herr der Ringe", publisher: "X"))
    weak.score = 0.6
    CalibreHub::Meta::Merge.plan(book("Der Herr der Ringe", ["J. R. R. Tolkien"]), nil, nil, [weak]).should be_empty
  end

  it "corrects existing fields only on a sure match, and never the description" do
    b = book("Der Herr der Ringe", ["J. R. R. Tolkien"], publisher: "Rowohlt", comments: "<p>Eigene</p>",
      pubdate: Time.utc(1972, 1, 1, 12, 0, 0), languages: ["eng"])
    changes = CalibreHub::Meta::Merge.plan(b, nil, nil, [sure, text_match]).to_h { |c| {c.field, c.new.raw} }
    changes["publisher"].should eq("Klett-Cotta")
    changes["pubdate"].should eq("2009")
    changes["languages"].should eq([JSON::Any.new("deu")])
    changes["isbn"].should eq("9783608938289")
    changes.has_key?("comments").should be_false
    # a publisher spelled differently stays
    b2 = book("Der Herr der Ringe", ["J. R. R. Tolkien"], publisher: "Klett-Cotta Verlag", isbn: "9783608938289")
    CalibreHub::Meta::Merge.plan(b2, nil, nil, [sure]).map(&.field).should_not contain("publisher")
  end

  it "takes the rules' title and authors, and the fuller or better spelled name of a match" do
    b = book("tolkien - der herr der ringe (z-lib.org)", ["Unbekannt"], author_sort: "Unbekannt")
    guess = CalibreHub::Meta::Clean.guesses(b.title, b.authors)[0].first
    changes = CalibreHub::Meta::Merge.plan(b, guess, nil, [sure])
    by = changes.to_h { |c| {c.field, c} }
    by["title"].new.should eq("Der Herr der Ringe")
    by["title"].source.should eq("rules")
    by["authors"].new.should eq(JSON.parse(%(["J. R. R. Tolkien"])))
    by["authors"].source.should eq("dnb")
    by["title"].old.should eq("tolkien - der herr der ringe (z-lib.org)")
    # calibre sorts the new authors itself
    by.has_key?("authorSort").should be_false

    le = CalibreHub::Meta::Candidate.new("openlibrary", record(title: "The Left Hand of Darkness", authors: ["Ursula K. Le Guin"]))
    le.score = 0.9
    c = CalibreHub::Meta::Merge.plan(book("The Left Hand of Darkness", ["Ursula K. LeGuin"]), nil, nil, [le])
    c.map { |x| {x.field, x.new} }.should eq([{"authors", JSON.parse(%(["Ursula K. Le Guin"]))}])
  end

  it "takes a date a day off as the same (calibre and time zones)" do
    same = ->(a : String, b : String) { CalibreHub::Meta::Merge.same?("pubdate", JSON::Any.new(a), JSON::Any.new(b)) }
    same.call("2009-08-02", "2009-08-01").should be_true
    same.call("2009", "2009-01-01").should be_true
    same.call("2009-08-03", "2009-08-01").should be_false
  end

  it "fixes a broken author sort of kept authors" do
    c = CalibreHub::Meta::Merge.plan(book(author_sort: "Unbekannt"), nil, nil, [] of CalibreHub::Meta::Candidate)
    c.map { |x| {x.field, x.new.as_s} }.should eq([{"authorSort", "Herbert, Frank"}])
  end
end

describe CalibreHub::Meta::Authors do
  it "groups spelling variants and picks the best-sourced, then most common form" do
    counts = {"Ursula K. LeGuin" => 3, "Ursula K. Le Guin" => 1, "ursula k. le guin" => 1, "J.R.R. Tolkien" => 2,
              "J. R. R. Tolkien" => 1, "Tolkien, J. R. R." => 1, "Frank Herbert" => 4, "Franz Kafka" => 1}
    CalibreHub::Meta::Authors.groups(counts).should eq([
      {"J.R.R. Tolkien", ["J. R. R. Tolkien", "Tolkien, J. R. R."]},
      {"Ursula K. LeGuin", ["Ursula K. Le Guin", "ursula k. le guin"]},
    ])
    CalibreHub::Meta::Authors.groups(counts, Set{"Ursula K. Le Guin"})[1].should eq({"Ursula K. Le Guin", ["Ursula K. LeGuin", "ursula k. le guin"]})
    CalibreHub::Meta::Authors.groups({"Stanisław Lem" => 1, "Stanislaw Lem" => 1}).first[0].should eq("Stanisław Lem")
  end
end

describe CalibreHub::Metadata do
  it "cleans a messy book from its file and the sources, logs and tags it" do
    file = CalibreHub::Meta::FileMeta::Info.new(record, ["9783608938289"])
    library, web, m, _, _ = setup(->(_b : CalibreHub::Book) { file.as(CalibreHub::Meta::FileMeta::Info?) })
    library.add(1, "tolkien - der herr der ringe (z-lib.org)", ["Unbekannt"])
    entries = m.run(1)
    b = library.books[1]
    b["title"].should eq("Der Herr der Ringe")
    b["authors"].should eq(JSON.parse(%(["J.R.R. Tolkien"])))
    b["author_sort"].should eq("Tolkien, J.R.R.")
    b["identifiers"].should eq(JSON.parse(%({"isbn": "9783608938289"})))
    b["publisher"].should eq("Klett-Cotta Verlag")
    b["pubdate"].as_s.should start_with("2009-08-01")
    b["languages"].should eq(JSON.parse(%(["deu"])))
    b["tags"].should eq(JSON.parse(%(["auto-metadaten"])))
    library.covers.should contain(1)
    entries.map(&.field).sort.should eq(%w(authors cover isbn languages pubdate publisher title))
    entries.find! { |e| e.field == "title" }.old.should eq("tolkien - der herr der ringe (z-lib.org)")
    entries.find! { |e| e.field == "isbn" }.source.should eq("openlibrary")
    m.log.status(1).should eq("done")
    # sure by ISBN: no text search needed
    web.requests.none?(&.includes?("search.json")).should be_true
    # nothing left to do: a second run changes nothing
    m.run(1).should be_empty
  end

  it "reverts single changes and whole books, the last one takes the tag" do
    library, _, m, _, _ = setup
    library.add(2, "The Left Hand of Darkness", ["Ursula K. LeGuin"], languages: ["eng"])
    entries = m.run(2)
    entries.map(&.field).sort.should eq(%w(authors comments cover))
    library.books[2]["authors"].should eq(JSON.parse(%(["Ursula K. Le Guin"])))
    library.books[2]["comments"].as_s.should contain("<p>")
    authors = entries.find! { |e| e.field == "authors" }
    change, b = m.revert(authors.id)
    change.reverted_at.should_not be_nil
    b.authors.should eq(["Ursula K. LeGuin"])
    b.tags.should eq(["auto-metadaten"])
    # already reverted
    expect_raises(CalibreHub::Writer::Conflict) { m.revert(authors.id) }
    # changed by someone since: not overwritten
    library.books[2]["comments"] = JSON::Any.new("<p>Eigene</p>")
    expect_raises(CalibreHub::Writer::Conflict) { m.revert(entries.find! { |e| e.field == "comments" }.id) }
    library.books[2]["comments"] = JSON::Any.new(entries.find! { |e| e.field == "comments" }.new.as_s)
    m.revert_books([2_i64]).each { |id| m.revert(id) }
    library.books[2]["comments"].raw.should be_nil
    library.covers.should_not contain(2)
    library.books[2]["tags"].should eq(JSON.parse("[]"))
    m.log.changed_books.should eq(0)
  end

  it "unifies author spellings library-wide, logged and revertible" do
    library, _, m, _, _ = setup
    library.add(3, "Planet der Habenichtse", ["Ursula K. LeGuin"])
    library.add(4, "Erdsee", ["Ursula K. LeGuin"])
    library.add(5, "Die linke Hand der Dunkelheit", ["Ursula K. Le Guin"])
    library.add(6, "Der Hobbit", ["Tolkien, J. R. R.", "Christopher Tolkien"])
    library.add(7, "Silmarillion", ["J. R. R. Tolkien"])
    m.unify_authors("job").should eq(2)
    library.books[5]["authors"].should eq(JSON.parse(%(["Ursula K. LeGuin"])))
    library.books[6]["authors"].should eq(JSON.parse(%(["J. R. R. Tolkien", "Christopher Tolkien"])))
    e = m.log.list(5_i64).first
    {e.field, e.source, e.job_id}.should eq({"authors", "authors", "job"})
    m.revert(e.id)
    library.books[5]["authors"].should eq(JSON.parse(%(["Ursula K. Le Guin"])))
  end

  it "retries a book that changed meanwhile, and counts failed sources as retry" do
    library, web, m, jobs, _ = setup
    library.add(8, "The Left Hand of Darkness", ["Ursula K. LeGuin"])
    library.interfere = -> { library.touch(8_i64); nil }
    job = wait_job(jobs, jobs.submit_target(JSON.parse(%({"ids": [8]}))).id)
    job.errors.should be_empty
    library.books[8]["authors"].should eq(JSON.parse(%(["Ursula K. Le Guin"])))
    m.log.status(8).should eq("done")

    web.down = true
    library.add(9, "Dune", ["Frank Herbert"])
    job = wait_job(jobs, jobs.submit_target(JSON.parse(%({"ids": [9]}))).id)
    job.status.should eq("done")
    m.log.status(9).should eq("retry")
    m.incomplete.should contain(9)
  end

  it "runs over incomplete books with the author pass at the end" do
    library, _, m, jobs, _ = setup
    library.add(10, "The Left Hand of Darkness", ["Ursula K. LeGuin"], languages: ["eng"])
    library.add(11, "Erdsee", ["Ursula K. LeGuin"], publisher: "Heyne", pubdate: "1979-01-01T12:00:00+00:00",
      languages: ["deu"], comments: "<p>x</p>", identifiers: {"isbn" => "9783453164154"})
    m.incomplete.should eq([10_i64])
    job = wait_job(jobs, jobs.submit_target(nil).id)
    job.total.should eq(2)
    job.status.should eq("done")
    # Le Guin confirmed by Open Library wins over the more common LeGuin
    library.books[11]["authors"].should eq(JSON.parse(%(["Ursula K. Le Guin"])))
    jobs.target(job).should eq("incomplete")
    m.incomplete.should be_empty
  end

  it "queues added books and holds their classification until done" do
    _, _, m, jobs, db = setup
    db.exec "insert into events (type, book_id, payload, created_at) values ('added', 1, '{}', ?)", Time.utc.to_unix
    jobs.watch_events(1.hour)
    sleep 10.milliseconds
    db.exec "insert into events (type, book_id, payload, created_at) values ('added', 12, '{}', ?)", Time.utc.to_unix
    event = db.scalar("select max(id) from events").as(Int64)
    jobs.ready_for_classify?(event, 12, Time.utc).should be_false
    jobs.follow_events
    jobs.ready_for_classify?(event, 12, Time.utc).should be_false
    m.log.status(12).should eq("queued")
    job = wait_job(jobs, jobs.last.not_nil![0].id)
    job.errors.map(&.[:error]).should eq(["not found"])
    jobs.ready_for_classify?(event, 12, Time.utc).should be_true
    # waits at most CLASSIFY_WAIT
    jobs.ready_for_classify?(event + 1, 13, Time.utc - 1.hour).should be_true
  end

  it "asks the model only when the rules can't decide, and only trusts words from the input" do
    input = "Title: Wolken - Atlas\nAuthors: Unknown"
    g = CalibreHub::Metadata.model_guess(%({"title": "Wolkenatlas", "authors": ["Unknown"]}), input)
    g.should be_nil
    g = CalibreHub::Metadata.model_guess(%({"title": "Atlas", "authors": ["Wolken"], "seriesIndex": null}), input).not_nil!
    {g.title, g.authors, g.source}.should eq({"Atlas", ["Wolken"], "model"})
    expect_raises(CalibreHub::Classifier::BadAnswer) { CalibreHub::Metadata.model_guess("kein JSON", input) }
  end
end

describe "metadata routes" do
  it "runs, lists, reverts and finds candidates" do
    library, _, m, jobs, _ = setup
    library.add(20, "tolkien - der herr der ringe (z-lib.org)", ["Unbekannt"], identifiers: {"isbn" => "978-3-608-93828-9"})
    library.add(21, "The Left Hand of Darkness", ["Ursula K. LeGuin"])
    CalibreHub.metadata_routes(jobs, library.calibre)

    status, body = call("GET", "/api/metadata/status")
    status.should eq(200)
    body["enabled"].should eq(true)
    body["sources"].should eq(JSON.parse(%(["file", "openlibrary", "dnb"])))
    body["lastRun"].raw.should be_nil

    status, body = call("POST", "/api/metadata/run", %({"target": {"ids": [20, 21]}}))
    status.should eq(202)
    body["total"].should eq(2)
    wait_job(jobs, body["jobId"].as_s).status.should eq("done")
    call("POST", "/api/metadata/run", %({"target": "everything"}))[0].should eq(400)

    status, body = call("GET", "/api/metadata/status")
    body["changedBooks"].should eq(2)
    body["lastRun"]["target"].should eq("ids")

    status, body = call("GET", "/api/metadata/changes?bookId=20")
    status.should eq(200)
    changes = body["changes"].as_a
    changes.map(&.["field"].as_s).should contain("title")
    changes.all? { |c| c["bookId"] == 20 }.should be_true
    body["books"][0]["title"].should eq("Der Herr der Ringe")
    call("GET", "/api/metadata/changes?since=gestern")[0].should eq(400)

    title = changes.find! { |c| c["field"] == "title" }
    status, body = call("POST", "/api/metadata/changes/#{title["id"]}/revert")
    status.should eq(200)
    body["book"]["title"].should eq("tolkien - der herr der ringe (z-lib.org)")
    call("POST", "/api/metadata/changes/#{title["id"]}/revert")[0].should eq(409)
    call("POST", "/api/metadata/changes/9999/revert")[0].should eq(404)
    call("GET", "/api/metadata/changes?reverted=true")[1]["changes"].size.should eq(1)

    status, body = call("POST", "/api/metadata/changes/revert", %({"bookIds": [20, 21]}))
    status.should eq(200)
    body["errors"].should eq(JSON.parse("[]"))
    library.books[21]["authors"].should eq(JSON.parse(%(["Ursula K. LeGuin"])))
    library.books[20]["tags"].should eq(JSON.parse("[]"))
    call("POST", "/api/metadata/changes/revert", %({}))[0].should eq(400)

    status, body = call("GET", "/api/books/20/metadata/candidates")
    status.should eq(200)
    list = body["candidates"].as_a
    list[0]["source"].should eq("rules")
    list[0]["fields"]["title"].should eq("Der Herr der Ringe")
    sure = list.find! { |c| c["source"] == "dnb" }
    sure["sure"].should eq(true)
    sure["fields"]["publisher"].should eq("Klett-Cotta")
    sure["url"].should eq("https://d-nb.info/99386712X")
    call("GET", "/api/books/99/metadata/candidates")[0].should eq(404)
    m.log.changed_books.should eq(0)
  end
end
