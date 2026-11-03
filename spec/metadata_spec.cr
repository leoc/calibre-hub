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
  # reading one of these books takes too long this many times (read timeout)
  getter slow = {} of Int64 => Int32
  # calibre-server down: every request fails
  property down = false

  def initialize
    @server = HTTP::Server.new do |ctx|
      path = ctx.request.path
      body = JSON.parse(ctx.request.body.try(&.gets_to_end).presence || "null")
      ctx.response.content_type = "application/json"
      if @down
        ctx.response.status_code = 503
        next
      end
      case path
      when "/cdb/cmd/list/0"
        search = body[3].as_s
        ids = search.empty? ? @books.keys : search.scan(/id:(\d+)/).map(&.[1].to_i64).select { |id| @books.has_key?(id) }
        if ids.size == 1 && (@slow[ids.first]? || 0) > 0
          @slow[ids.first] -= 1
          sleep 400.milliseconds
        end
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
      when "/hc"
        if r.headers["Authorization"]? != "Bearer hc-token"
          ctx.response.status_code = 401
          ctx.response.print %({"error":"invalid_token","error_description":"Token is not associated with a user"})
          next
        end
        body = JSON.parse(r.body.try(&.gets_to_end) || "{}")
        @requests << "hc #{body["variables"].to_json}"
        query = body["query"].as_s
        vars = body["variables"]
        ctx.response.print(
          if query.includes?("search(")
            vars["q"].as_s.starts_with?("Effortless") ? fixture("hardcover_search_effortless.json") : %({"data":{"search":{"results":{"hits":[]}}}})
          elsif query.includes?("books(where")
            fixture("hardcover_books_effortless.json")
          else
            case vars["isbn"].as_s
            when "9780593135648" then fixture("hardcover_isbn_effortless.json")
            when "9780787958664" then fixture("hardcover_isbn_kegan.json")
            when "9783608938289" then fixture("hardcover_isbn_ringe.json")
            else                      %({"data":{"editions":[]}})
            end
          end)
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
        when "num=9780787958664"  then fixture("dnb_isbn_kegan.xml")
        when /tit="Effortless"/   then fixture("dnb_search_effortless.xml")
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
                 series : String? = nil, tags = [] of String, identifiers : Hash(String, String)? = nil) : CalibreHub::Book
  CalibreHub::Book.new(id: 1_i64, title: title, authors: authors, author_sort: author_sort || CalibreHub::Meta::AuthorSort.for(authors),
    tags: tags, series: series, series_index: series ? 1.0 : nil, formats: [] of String, last_modified: Time::UNIX_EPOCH,
    timestamp: nil, pubdate: pubdate, rating: nil, publisher: publisher,
    identifiers: identifiers || (isbn ? {"isbn" => isbn} : {} of String => String),
    languages: languages, comments: comments, custom: {} of String => JSON::Any)
end

private def setup(read_file : CalibreHub::Metadata::FileReader? = nil, sources = %w(file openlibrary dnb),
                   hardcover_token : String? = nil, alert : CalibreHub::Meta::Hardcover::Alert? = nil,
                   read_timeout : Time::Span? = nil)
  library = FakeLibrary.new
  web = FakeSources.new
  http = CalibreHub::Meta::Http.new(Time::Span.zero, 5.seconds)
  hardcover = CalibreHub::Meta::Hardcover.new(http, hardcover_token, "#{web.url}/hc", alert)
  calibre = library.calibre
  read_timeout.try { |t| calibre.read_timeout = t }
  writer = CalibreHub::Writer.new(calibre, nil, nil, nil)
  db = DB.open("sqlite3://#{File.tempname("hub-metadata", ".sqlite")}?max_pool_size=1")
  db.exec "create table if not exists meta (key text primary key, value text)"
  db.exec "create table if not exists events (id integer primary key autoincrement, type text not null, book_id integer not null, payload text not null, created_at integer not null, done_at integer)"
  m = CalibreHub::Metadata.new(calibre, writer, CalibreHub::MetaLog.new(db), sources,
    CalibreHub::Meta::OpenLibrary.new(http, "#{web.url}/ol", "#{web.url}/covers"),
    CalibreHub::Meta::Dnb.new(http, "#{web.url}/dnb"), http, nil,
    read_file || ->(_b : CalibreHub::Book) { nil.as(CalibreHub::Meta::FileMeta::Info?) }, hardcover: hardcover)
  jobs = CalibreHub::MetadataJobs.new(db, calibre, writer, m)
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

private def epub(opf : String | Bytes, pages = {} of String => String | Bytes) : String
  path = File.tempname("meta", ".epub")
  File.open(path, "w") do |f|
    Compress::Zip::Writer.open(f) do |zip|
      zip.add("mimetype", "application/epub+zip")
      zip.add("META-INF/container.xml", %(<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>))
      zip.add("OEBPS/content.opf", opf.to_slice)
      pages.each { |name, html| zip.add("OEBPS/#{name}", html.to_slice) }
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
    # as the backlog import leaves a name without a person (#8408)
    {"Wine Tasting - A Professional Handbook", ["Unknown"]} => {"Wine Tasting - A Professional Handbook", [] of String, nil, nil, false},
    # found on the live library (02.11.): two authors in one field, acronyms
    {"Positioning", ["Al Ries, Jack Trout"]}                               => {"Positioning", ["Al Ries", "Jack Trout"], nil, nil, false},
    {"GAMP 5", ["ISPE"]}                                                   => {"GAMP 5", ["ISPE"], nil, nil, false},
    {"Guidance", ["CDRH CBER"]}                                            => {"Guidance", ["CDRH CBER"], nil, nil, false},
    {"Erdsee", ["Le Guin, Ursula K."]}                                     => {"Erdsee", ["Ursula K. Le Guin"], nil, nil, false},
    {"Hundert Jahre Einsamkeit", ["Garcia Marquez, Gabriel"]}              => {"Hundert Jahre Einsamkeit", ["Gabriel Garcia Marquez"], nil, nil, false},
    {"Baden Powell - Baden Powell. Songbook, Vol. 2 (Guitar Scores) (1974, Tonos)", ["libgen.lc"]} =>
      {"Songbook, Vol. 2 (Guitar Scores)", ["Baden Powell"], nil, nil, false},
    {"Applied Software Project Management (2005, O'Reilly Media)", ["Andrew Stellman", "Jennifer Greene"]} =>
      {"Applied Software Project Management", ["Andrew Stellman", "Jennifer Greene"], nil, nil, false},
    {"Brian Hodel - The Brazilian Masters (Guitar Scores) (, TRO Hollis Music, Inc.)", ["libgen.lc"]} =>
      {"The Brazilian Masters (Guitar Scores)", ["Brian Hodel"], nil, nil, false},
    {"Guidance", ["FDA/CDER"]}                                             => {"Guidance", ["FDA/CDER"], nil, nil, false},
    {"ISO/IEC 42001:2023", ["ISO"]}                                        => {"ISO/IEC 42001:2023", ["ISO"], nil, nil, false},
    {"\u{FEFF}ISO/IEC 42001:2023\u{FEFF}", ["ISO"]}                       => {"ISO/IEC 42001:2023", ["ISO"], nil, nil, false},
    {"Applied Software Project Management", ["libgen.lc"]}                 => {"Applied Software Project Management", [] of String, nil, nil, false},
    {"[DIN EN ISO 14971 2009-10] -- Medizinprodukte", ["Anwendung des Risikomanagements auf Medizinprodukte (ISO 14971 2007), Berichtigungen zu DIN EN I"]} =>
      {"[DIN EN ISO 14971 2009-10] -- Medizinprodukte", ["Anwendung des Risikomanagements auf Medizinprodukte (ISO 14971 2007), Berichtigungen zu DIN EN I"], nil, nil, false},
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

  it "reads an EPUB in Latin-1, declared or not (#8399)" do
    latin1 = ->(s : String) { s.encode("ISO-8859-1") }
    opf = ->(decl : String) { <<-XML }
      #{decl}
      <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
          <dc:title>Die Größe der Wälder</dc:title>
          <dc:creator opf:role="aut">Jürgen Müßig</dc:creator>
          <dc:publisher>Verlag Ärger &amp; Söhne</dc:publisher>
          <dc:language>de</dc:language>
        </metadata>
        <manifest><item id="c1" href="text/c1.xhtml" media-type="application/xhtml+xml"/></manifest>
        <spine><itemref idref="c1"/></spine>
      </package>
      XML
    page = %(<html><head><meta http-equiv="Content-Type" content="text/html; charset=iso-8859-1"/></head>) +
           %(<body><p>Größe © 2009, ISBN 978-3-608-93828-9</p></body></html>)
    [%(<?xml version="1.0" encoding="ISO-8859-1"?>), %(<?xml version="1.0" encoding="windows-1252"?>), %(<?xml version="1.0"?>), ""].each do |decl|
      path = epub(latin1.call(opf.call(decl)), {"text/c1.xhtml" => latin1.call(page)} of String => String | Bytes)
      begin
        info = CalibreHub::Meta::FileMeta.read(path, "EPUB").not_nil!
        info.record.title.should eq("Die Größe der Wälder")
        info.record.authors.should eq(["Jürgen Müßig"])
        info.record.publisher.should eq("Verlag Ärger & Söhne")
        info.isbns.should eq(["9783608938289"])
      ensure
        File.delete?(path)
      end
    end
  end

  it "decodes book text files to valid UTF-8 whatever their encoding" do
    decode = ->(s : String, enc : String) { CalibreHub::Meta::Charset.decode(s.encode(enc)) }
    decode.call(%(<?xml version="1.0" encoding="iso-8859-1"?><a>Größe</a>), "ISO-8859-1").should eq(%(<?xml version="1.0" encoding="utf-8"?><a>Größe</a>))
    # Windows-1252 only: the euro sign and typographic quotes
    decode.call(%(<a>„Größe“ 5 €</a>), "WINDOWS-1252").should eq(%(<a>„Größe“ 5 €</a>))
    decode.call(%(<?xml version="1.0" encoding="utf-8"?><a>Größe</a>), "UTF-8").should eq(%(<?xml version="1.0" encoding="utf-8"?><a>Größe</a>))
    utf16 = IO::Memory.new
    utf16.write(Bytes[0xFF, 0xFE])
    utf16.write(%(<a>Größe</a>).encode("UTF-16LE"))
    CalibreHub::Meta::Charset.decode(utf16.to_slice).should eq("<a>Größe</a>")
    # an encoding iconv doesn't know: Windows-1252
    decode.call(%(<?xml version="1.0" encoding="x-bogus"?><a>Größe</a>), "ISO-8859-1").should eq(%(<?xml version="1.0" encoding="utf-8"?><a>Größe</a>))
    # UTF-8 with a stray Latin-1 byte: the UTF-8 stays, the byte is replaced
    stray = IO::Memory.new
    stray << "Größe "
    stray.write(Bytes[0xE4])
    mixed = CalibreHub::Meta::Charset.decode(stray.to_slice)
    mixed.should eq("Größe \uFFFD")
    mixed.valid_encoding?.should be_true
  end

  it "skips a file whose zip entries have an invalid DOS date" do
    path = epub(SCHWARM_OPF, {} of String => String)
    # month 0 in every local and central header date (seen on the live library)
    bytes = File.read(path).to_slice.dup
    (0..bytes.size - 46).each do |i|
      if bytes[i] == 0x50 && bytes[i + 1] == 0x4b && bytes[i + 2] == 0x03 && bytes[i + 3] == 0x04
        bytes[i + 12] = 0_u8; bytes[i + 13] = 0_u8
      elsif bytes[i] == 0x50 && bytes[i + 1] == 0x4b && bytes[i + 2] == 0x01 && bytes[i + 3] == 0x02
        bytes[i + 14] = 0_u8; bytes[i + 15] = 0_u8
      end
    end
    File.write(path, bytes)
    CalibreHub::Meta::FileMeta.read(path, "EPUB").should be_nil
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

  it "takes the language of a sure match when the file says \"und\" (live: #31)" do
    b = book("Die Psychologie sexueller Leidenschaft", ["David Schnarch"], isbn: "9783608106381", publisher: "Klett Cotta")
    file = record(publisher: "Klett Cotta", languages: ["und"])
    dnb = CalibreHub::Meta::Candidate.new("dnb", record(title: "Die Psychologie sexueller Leidenschaft", authors: ["David Schnarch"],
      publisher: "Klett-Cotta", pubdate: "2016", languages: ["deu"]))
    dnb.sure = true
    dnb.score = 1.0
    changes = CalibreHub::Meta::Merge.plan(b, nil, file, [dnb]).to_h { |c| {c.field, {c.new.raw, c.source}} }
    changes["languages"].should eq({["deu"].map { |l| JSON::Any.new(l) }, "dnb"})
    CalibreHub::Meta::Lang.list(["und", "ger"]).should eq(["deu"])
  end

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

  it "ignores a translation with the same title (live: Effortless by Crown vs. REDLINE)" do
    b = book("Effortless", ["Greg McKeown"], publisher: "Crown", languages: ["eng"])
    german = CalibreHub::Meta::Candidate.new("dnb", record(title: "Effortless", authors: ["Greg McKeown"],
      isbn: "9783962673741", publisher: "REDLINE Verlag", languages: ["deu"]), by_isbn: "9783962673741")
    german.sure = true
    german.score = 1.0
    CalibreHub::Meta::Merge.plan(b, nil, nil, [german]).should be_empty
  end

  it "corrects existing fields only on a sure match, and never the description" do
    # the book's own ISBN: the same edition, so even the language is corrected
    b = book("Der Herr der Ringe", ["J. R. R. Tolkien"], publisher: "Rowohlt", comments: "<p>Eigene</p>",
      pubdate: Time.utc(1972, 1, 1, 12, 0, 0), languages: ["eng"])
    file = record(isbn: "9783608938289")
    changes = CalibreHub::Meta::Merge.plan(b, nil, file, [sure, text_match]).to_h { |c| {c.field, c.new.raw} }
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

  it "keeps the issuing bodies of standards apart" do
    counts = {"DIN" => 50, "ISO" => 3, "CEN" => 1, "IEC" => 1, "IEEE" => 1, "Dina Nayeri" => 1, "Din" => 1}
    CalibreHub::Meta::Authors.groups(counts).should eq([{"DIN", ["Din"]}])
    CalibreHub::Meta::Clean.authors(["DIN", "IEEE"]).should eq(["DIN", "IEEE"])
    CalibreHub::Meta::AuthorSort.for("DIN").should eq("DIN")
  end
end

describe CalibreHub::Meta::Norms do
  # the live library (02.11.), as calibre split the file names:
  # {title, authors} -> {title, full title, language, series, index, tags}
  {
    {"[DIN EN ISO 11073-10404 2011-07] -- Medizinische Informatik - Kommunikation von Geräten für die persönliche Gesundheit - Teil 10404 Gerätespezifikation", ["Pulsoximeter (ISO IEEE 11073-10"]} =>
      {"DIN EN ISO 11073-10404:2011-07 – Pulsoximeter",
       "Medizinische Informatik – Kommunikation von Geräten für die persönliche Gesundheit – Teil 10404: Gerätespezifikation – Pulsoximeter",
       nil, "DIN EN ISO 11073", 10404.0, %w(Norm)},
    {"[DIN EN ISO 11073-10102 Entwurf 2013-07] -- Medizinische Informatik - Kommunikation patientennaher medizinischer Geräte - Teil 10102 Nomenklatur", ["Mit Annotationen versehenes EKG (ISO IEEE FDIS"]} =>
      {"DIN EN ISO 11073-10102:2013-07 (Entwurf) – Mit Annotationen versehenes EKG",
       "Medizinische Informatik – Kommunikation patientennaher medizinischer Geräte – Teil 10102: Nomenklatur – Mit Annotationen versehenes EKG",
       nil, "DIN EN ISO 11073", 10102.0, %w(Norm Entwurf)},
    {"[DIN EN 13606-2 2007-11] -- Medizinische Informatik - Kommunikation von Patientendaten in elektronischer Form", ["Teil 2 Spezifikation für den Austausch von Archetypen Englische"]} =>
      {"DIN EN 13606-2:2007-11 – Spezifikation für den Austausch von Archetypen",
       "Medizinische Informatik – Kommunikation von Patientendaten in elektronischer Form – Teil 2: Spezifikation für den Austausch von Archetypen",
       "eng", "DIN EN 13606", 2.0, %w(Norm)},
    {"[DIN EN ISO 11073-10101 2006-05] -- Medizinische Informatik - Kommunikation patientennaher medizinischer Geräte", ["Teil 10101 Nomenklatur (ISO IEEE 11073-10101 2004) Englische Fassung E"]} =>
      {"DIN EN ISO 11073-10101:2006-05 – Nomenklatur",
       "Medizinische Informatik – Kommunikation patientennaher medizinischer Geräte – Teil 10101: Nomenklatur",
       "eng", "DIN EN ISO 11073", 10101.0, %w(Norm)},
    {"[DIN EN ISO 12052 2011-06] -- Medizinische Informatik", ["Digitale Bildverarbeitung und Kommunikation in der Medizin (DICOM) inklusive Workflow und Datenmanagement (ISO 12052 2006)"]} =>
      {"DIN EN ISO 12052:2011-06 – Digitale Bildverarbeitung und Kommunikation in der Medizin (DICOM) inklusive Workflow und Datenmanagement",
       "Medizinische Informatik – Digitale Bildverarbeitung und Kommunikation in der Medizin (DICOM) inklusive Workflow und Datenmanagement",
       nil, nil, nil, %w(Norm)},
    {"[DIN EN ISO 14971 2009-10] -- Medizinprodukte Anwendung des Risikomanagements auf Medizinprodukte (ISO 14971 2007, korrigierte Fassung 2007-10-01) Deutsche Fassung EN ISO 14971 20", ["Unknown"]} =>
      {"DIN EN ISO 14971:2009-10 – Medizinprodukte Anwendung des Risikomanagements auf Medizinprodukte",
       "Medizinprodukte Anwendung des Risikomanagements auf Medizinprodukte",
       "deu", nil, nil, %w(Norm)},
    {"[DIN EN ISO 10781 Entwurf 2012-04] -- Funktionales Modell für ein elektronisches Gesundheitsaktensystem (EHRS FM), Ausgabe 2 (ISO HL7 DIS 10781) (ISO DIS 10781 2012) Englische Fassung prE", ["Unknown"]} =>
      {"DIN EN ISO 10781:2012-04 (Entwurf) – Funktionales Modell für ein elektronisches Gesundheitsaktensystem (EHRS FM), Ausgabe 2",
       "Funktionales Modell für ein elektronisches Gesundheitsaktensystem (EHRS FM), Ausgabe 2",
       "eng", nil, nil, %w(Norm Entwurf)},
    # edge cases: a corrigendum, an ISO standard without "Teil", parts in English, nur auf CD-R
    {"[DIN EN ISO 14971 2009-10] -- Medizinprodukte", ["Anwendung des Risikomanagements auf Medizinprodukte (ISO 14971 2007), Berichtigungen zu DIN EN I"]} =>
      {"DIN EN ISO 14971:2009-10 (Berichtigung) – Anwendung des Risikomanagements auf Medizinprodukte",
       "Medizinprodukte – Anwendung des Risikomanagements auf Medizinprodukte", nil, nil, nil, %w(Norm Berichtigung)},
    {"[ISO IEC 27001 2013-10] -- Information technology - Security techniques", ["Information security management systems - Requirements"]} =>
      {"ISO IEC 27001:2013-10 – Requirements",
       "Information technology – Security techniques – Information security management systems – Requirements", nil, nil, nil, %w(Norm)},
    {"[IEC 62304 2006-05] -- Medical device software - Software life cycle processes nur auf CD-ROM", ["Unknown"]} =>
      {"IEC 62304:2006-05 – Software life cycle processes",
       "Medical device software – Software life cycle processes", nil, nil, nil, %w(Norm)},
    {"[DIN EN 62304 2016-10] -- Medizingeräte-Software - Software-Lebenszyklus-Prozesse - Part 1 General", ["Unknown"]} =>
      {"DIN EN 62304:2016-10 – General",
       "Medizingeräte-Software – Software-Lebenszyklus-Prozesse – Part 1: General", nil, nil, nil, %w(Norm)},
    # live books 53, 94, 90, 97 (02.11.): a prestandard "DIN V ENV", an
    # amendment "A1", a numbered corrigendum, "Fassung" cut off
    {"[DIN V ENV 13606-2 2000-09] -- Medizinische Informatik - Kommunikation von Patientendaten in elektronischer Form", ["Teil 2 Liste der Benennungen für Anwendungen Englische Fassung E"]} =>
      {"DIN V ENV 13606-2:2000-09 – Liste der Benennungen für Anwendungen",
       "Medizinische Informatik – Kommunikation von Patientendaten in elektronischer Form – Teil 2: Liste der Benennungen für Anwendungen",
       "eng", "DIN V ENV 13606", 2.0, %w(Norm)},
    {"[DIN V ENV 13606-4 2000-09] -- Medizinische Informatik - Kommunikation von Patientendaten in elektronischer Form", ["Teil 4 Nachrichten für den Informationsaustausch Englische Fassu"]} =>
      {"DIN V ENV 13606-4:2000-09 – Nachrichten für den Informationsaustausch",
       "Medizinische Informatik – Kommunikation von Patientendaten in elektronischer Form – Teil 4: Nachrichten für den Informationsaustausch",
       "eng", "DIN V ENV 13606", 4.0, %w(Norm)},
    {"[DIN EN ISO 14971 A1 Entwurf 2003-01] -- Medizinprodukte Anwendung des Risikomanagements auf Medizinprodukte Änderung 1 Begründung der Anforderungen (ISO 14971 2000 FDAM 1 2002) Deutsche Fa", ["Unknown"]} =>
      {"DIN EN ISO 14971/A1:2003-01 (Entwurf) – Medizinprodukte Anwendung des Risikomanagements auf Medizinprodukte Änderung 1 Begründung der Anforderungen",
       "Medizinprodukte Anwendung des Risikomanagements auf Medizinprodukte Änderung 1 Begründung der Anforderungen",
       "deu", nil, nil, %w(Norm Entwurf)},
    {"[DIN EN ISO 14971 Berichtigung 1 2007-10] -- Medizinprodukte", ["Anwendung des Risikomanagements auf Medizinprodukte (ISO 14971 2007) Deutsche Fassung EN ISO 14971 2007, Berichtigungen zu DIN EN I"]} =>
      {"DIN EN ISO 14971:2007-10 (Berichtigung) – Anwendung des Risikomanagements auf Medizinprodukte",
       "Medizinprodukte – Anwendung des Risikomanagements auf Medizinprodukte", "deu", nil, nil, %w(Norm Berichtigung)},
  }.each do |(title, authors), (want_title, full, language, series, index, tags)|
    it "reads #{title[0, 60].inspect}" do
      n = CalibreHub::Meta::Norms.parse(title, authors).not_nil!
      {n.title, n.full_title, n.language, n.series, n.series_index}.should eq({want_title, full, language, series, index})
      changes = CalibreHub::Meta::Norms.plan(book(title, authors), n)
      changes.find! { |c| c.field == "tags" }.new.should eq(JSON.parse(tags.to_json))
    end
  end

  it "makes all fields of a standard from the bracket form" do
    title = "[DIN EN ISO 11073-10404 2011-07] -- Medizinische Informatik - Kommunikation von Geräten für die persönliche Gesundheit - Teil 10404 Gerätespezifikation"
    authors = ["Pulsoximeter (ISO IEEE 11073-10"]
    n = CalibreHub::Meta::Norms.parse(title, authors).not_nil!
    {n.id, n.body, n.publisher, n.pubdate, n.scheme, n.identifier}.should eq(
      {"DIN EN ISO 11073-10404:2011-07", "DIN", "Beuth", "2011-07-01", "din", "DIN EN ISO 11073-10404:2011-07"})
    changes = CalibreHub::Meta::Norms.plan(book(title, authors), n).to_h { |c| {c.field, c.new} }
    changes.should eq({
      "title"          => JSON::Any.new("DIN EN ISO 11073-10404:2011-07 – Pulsoximeter"),
      "authors"        => JSON.parse(%(["DIN"])),
      "publisher"      => JSON::Any.new("Beuth"),
      "pubdate"        => JSON::Any.new("2011-07-01"),
      "comments"       => JSON::Any.new("<p>Medizinische Informatik – Kommunikation von Geräten für die persönliche Gesundheit – Teil 10404: Gerätespezifikation – Pulsoximeter</p>"),
      "series"         => JSON::Any.new("DIN EN ISO 11073"),
      "seriesIndex"    => JSON::Any.new(10404.0),
      "identifier:din" => JSON::Any.new("DIN EN ISO 11073-10404:2011-07"),
      "tags"           => JSON.parse(%(["Norm"])),
    })
    # a description, language, publisher and series of its own stay
    b = book(title, authors, publisher: "Beuth Verlag", comments: "<p>Eigene</p>", languages: ["deu"], series: "Medizin", tags: ["norm", "Lesen"])
    changes = CalibreHub::Meta::Norms.plan(b, n)
    changes.map(&.field).sort.should eq(%w(authors identifier:din pubdate title))
    # a European standard by itself: CEN
    e = CalibreHub::Meta::Norms.parse("[EN 1789 2021-03] -- Rettungsdienstfahrzeuge", ["Unknown"]).not_nil!
    {e.body, e.publisher, e.scheme}.should eq({"CEN", "CEN", "en"})
    i = CalibreHub::Meta::Norms.parse("[ISO IEC 27001 2013-10] -- Information technology", ["Unknown"]).not_nil!
    {i.body, i.publisher, i.scheme}.should eq({"ISO", "ISO", "iso"})
  end

  it "reads its own titles again, so a second run changes nothing" do
    title = "[DIN EN ISO 11073-10102 Entwurf 2013-07] -- Medizinische Informatik - Kommunikation patientennaher medizinischer Geräte - Teil 10102 Nomenklatur"
    n = CalibreHub::Meta::Norms.parse(title, ["Mit Annotationen versehenes EKG (ISO IEEE FDIS"]).not_nil!
    again = CalibreHub::Meta::Norms.parse(n.title, ["DIN"], "Beuth").not_nil!
    {again.title, again.id, again.draft, again.series}.should eq({n.title, n.id, true, "DIN EN ISO 11073"})
    b = book(n.title, ["DIN"], publisher: "Beuth", pubdate: Time.utc(2013, 7, 1, 12), series: "DIN EN ISO 11073",
      tags: ["Norm", "Entwurf"], comments: "<p>x</p>", identifiers: {"din" => "DIN EN ISO 11073-10102:2013-07"})
    CalibreHub::Meta::Norms.plan(b, again).should be_empty
    # the amendment and the prestandard too
    {"DIN EN ISO 14971/A1:2003-01 (Entwurf) – Änderung 1" => {"DIN EN ISO 14971/A1", true, "14971"},
     "DIN V ENV 13606-2:2000-09 – Liste der Benennungen"  => {"DIN V ENV 13606-2", false, "13606-2"}}.each do |t, (designation, draft, number)|
      x = CalibreHub::Meta::Norms.parse(t, ["DIN"], "Beuth").not_nil!
      {x.title, x.designation, x.draft, x.number, x.scheme}.should eq({t, designation, draft, number, "din"})
    end
  end

  it "takes a standard's designation as title only from an issuing body" do
    n = CalibreHub::Meta::Norms.parse("ISO/IEC 42001:2023", ["ISO"]).not_nil!
    {n.title, n.body, n.scheme, n.pubdate, n.series, n.draft}.should eq({"ISO/IEC 42001:2023", "ISO", "iso", "2023", nil, false})
    CalibreHub::Meta::Norms.parse("ISO/IEC 42001:2023", ["Unknown"], "Beuth Verlag").should_not be_nil
    # books about standards, and standards by persons
    CalibreHub::Meta::Norms.parse("ISO/IEC 42001:2023", ["Unknown"]).should be_nil
    CalibreHub::Meta::Norms.parse("ISO/IEC 42001:2023", ["Hans Müller"]).should be_nil
    CalibreHub::Meta::Norms.parse("ISO 9001:2015 for Small Enterprises - What to do ?", ["ISO"]).should be_nil
    CalibreHub::Meta::Norms.parse("Understanding ISO 9001 2015 - A Practical Guide", ["David Hoyle"]).should be_nil
    CalibreHub::Meta::Norms.parse("ISO 13485:2016 - Medical devices - A practical guide", ["ISO"]).should be_nil
    CalibreHub::Meta::Norms.parse("[Kafka] -- Der Process", ["Unknown"]).should be_nil
    CalibreHub::Meta::Norms.parse("[2011-07] DIN EN ISO 11073 erklärt", ["Unknown"]).should be_nil
  end

  it "takes the full title from the cover page of the PDF" do
    cover = fixture("din_cover_14971.txt")
    title = "[DIN EN ISO 14971 2009-10] -- Medizinprodukte Anwendung des Risikomanagements auf Medizinprodukte (ISO 14971 2007, korrigierte Fassung 2007-10-01) Deutsche Fassung EN ISO 14971 20"
    n = CalibreHub::Meta::Norms.parse(title, ["Unknown"], nil, cover).not_nil!
    {n.title, n.full_title, n.language}.should eq({"DIN EN ISO 14971:2009-10 – Anwendung des Risikomanagements auf Medizinprodukte",
                                                   "Medizinprodukte – Anwendung des Risikomanagements auf Medizinprodukte", "deu"})
    # cut off in the middle: the cover has the rest
    cover = fixture("din_cover_11073-10404.txt")
    n = CalibreHub::Meta::Norms.parse("[DIN EN ISO 11073-10404 2011-07] -- Medizinische Informatik - Kommunikation von Geräten für die persönliche Gesundh",
      ["Unknown"], nil, cover).not_nil!
    {n.title, n.full_title, n.language}.should eq({"DIN EN ISO 11073-10404:2011-07 – Pulsoximeter",
                                                   "Medizinische Informatik – Kommunikation von Geräten für die persönliche Gesundheit – Teil 10404: Gerätespezifikation – Pulsoximeter", "eng"})
    # the description of an already named standard
    n = CalibreHub::Meta::Norms.parse("DIN EN ISO 11073-10404:2011-07 – Pulsoximeter", ["DIN"], nil, cover).not_nil!
    {n.title, n.full_title}.should eq({"DIN EN ISO 11073-10404:2011-07 – Pulsoximeter",
                                       "Medizinische Informatik – Kommunikation von Geräten für die persönliche Gesundheit – Teil 10404: Gerätespezifikation – Pulsoximeter"})
    # the cover of another standard is no help
    n = CalibreHub::Meta::Norms.parse("[DIN EN ISO 12052 2011-06] -- Medizinische Informatik", ["Unknown"], nil, cover).not_nil!
    n.full_title.should eq("Medizinische Informatik")
  end

  it "knows older editions replaced by newer ones" do
    parse = ->(t : String) { CalibreHub::Meta::Norms.parse(t, ["Unknown"]).not_nil! }
    old = parse.call("[DIN EN ISO 14971 2001-03] -- Medizinprodukte")
    now = parse.call("[DIN EN ISO 14971 2009-10] -- Medizinprodukte")
    draft = parse.call("[DIN EN ISO 14971 Entwurf 2018-02] -- Medizinprodukte")
    newest = parse.call("[DIN EN ISO 14971 2020-07] -- Medizinprodukte")
    other = parse.call("[DIN EN ISO 14972 2020-07] -- Medizinprodukte")
    named = CalibreHub::Meta::Norms.parse("DIN EN ISO 14971:2020-07 – Medizinprodukte", ["DIN"]).not_nil!
    CalibreHub::Meta::Norms.replaced?(old, [now]).should be_true
    CalibreHub::Meta::Norms.replaced?(now, [old, draft, other]).should be_false
    CalibreHub::Meta::Norms.replaced?(now, [named]).should be_true
    CalibreHub::Meta::Norms.replaced?(draft, [newest]).should be_true
    CalibreHub::Meta::Norms.replaced?(newest, [newest]).should be_false
    tags = CalibreHub::Meta::Norms.plan(book(), old, replaced: true).find! { |c| c.field == "tags" }
    {tags.old, tags.new}.should eq({JSON.parse("[]"), JSON.parse(%(["Norm", "ersetzt"]))})
    CalibreHub::Meta::Norms.replace(book(tags: ["Norm", "Lesen"])).not_nil!.new.should eq(JSON.parse(%(["Norm", "ersetzt"])))
    CalibreHub::Meta::Norms.replace(book(tags: ["Norm", "ersetzt"])).should be_nil
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
    b["authors"].should eq(JSON.parse(%(["J. R. R. Tolkien"])))
    b["author_sort"].should eq("Tolkien, J. R. R.")
    b["identifiers"].should eq(JSON.parse(%({"isbn": "9783608938289"})))
    b["publisher"].should eq("Klett-Cotta")
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

  it "retries a book after a read timeout, then fails it and goes on (live 03.11.: stopped at 19/114)" do
    library, _, m, jobs, _ = setup(sources: [] of String, read_timeout: 150.milliseconds)
    jobs.retry_policy(3, 10.milliseconds, 20.milliseconds)
    library.add(30, "Dune", ["Frank Herbert"])
    library.add(31, "Erdsee", ["Ursula K. Le Guin"])
    library.add(32, "Kindred", ["Octavia E. Butler"])
    # two timeouts, then it answers; 32 never does in time
    library.slow[30_i64] = 2
    library.slow[32_i64] = 10
    job = wait_job(jobs, jobs.submit_target(JSON.parse(%({"ids": [30, 32, 31]}))).id)
    job.status.should eq("done")
    job.error.should be_nil
    job.done.should eq(3)
    job.errors.map(&.[:bookId]).should eq([32_i64])
    job.errors.first[:error].should contain("tried 4 times")
    m.log.status(30).should eq("done")
    m.log.status(32).should eq("failed")
    m.log.status(31).should eq("done")
  end

  it "pauses a job while calibre-server is down and goes on when it is back" do
    library, _, m, jobs, _ = setup(sources: [] of String)
    jobs.retry_policy(0, 10.milliseconds, 20.milliseconds)
    library.add(33, "Dune", ["Frank Herbert"])
    library.down = true
    job = jobs.submit_target(JSON.parse(%({"ids": [33]})))
    sleep 150.milliseconds
    jobs[job.id]?.not_nil!.status.should eq("running")
    m.log.status(33).should eq("queued")
    library.down = false
    job = wait_job(jobs, job.id)
    job.status.should eq("done")
    job.errors.should be_empty
    m.log.status(33).should eq("done")
  end

  it "runs the books a stopped job left queued again" do
    library, _, m, jobs, db = setup(sources: [] of String)
    library.add(40, "Dune", ["Frank Herbert"])
    library.add(41, "Erdsee", ["Ursula K. Le Guin"])
    library.add(42, "Kindred", ["Octavia E. Butler"])
    # an "added" catch-up that stopped at its first book (before retries)
    db.exec "insert into metadata_jobs (id, status, done, ids, changes, created_at, error) values ('old', 'failed', 1, '[40,41]', '{\"target\":\"added\"}', 0, 'calibre-server: Read timed out')"
    m.log.set_status(40, "done")
    m.log.set_status(41, "queued")
    # 42 is queued in a job that is still running: not twice
    db.exec "insert into metadata_jobs (id, status, done, ids, changes, created_at) values ('running', 'running', 0, '[42]', '{\"target\":\"added\"}', 0)"
    m.log.set_status(42, "queued")
    job = jobs.requeue_stranded.not_nil!
    job.total.should eq(1)
    wait_job(jobs, job.id).status.should eq("done")
    m.log.status(41).should eq("done")
    wait_job(jobs, "running")
    m.log.status(42).should eq("done")
    # follow_events does it on every pass; nothing left now
    jobs.requeue_stranded.should be_nil
  end

  it "names standards by the rules, without online sources, and tags older editions ersetzt" do
    cover = fixture("din_cover_14971.txt")
    file = CalibreHub::Meta::FileMeta::Info.new(record, [] of String, cover)
    library, web, m, _, _ = setup(->(b : CalibreHub::Book) { (b.id == 21 ? file : nil).as(CalibreHub::Meta::FileMeta::Info?) })
    library.add(20, "[DIN EN ISO 14971 2001-03] -- Medizinprodukte - Anwendung des Risikomanagements auf Medizinprodukte", ["Unknown"],
      formats: ["PDF"], tags: ["Lesen"])
    library.add(21, "[DIN EN ISO 14971 2009-10] -- Medizinprodukte Anwendung des Risikomanagements auf Medizinprodukte (ISO 14971 2007, korrigierte Fassung 2007-10-01) Deutsche Fassung EN ISO 14971 20",
      ["Unknown"], formats: ["PDF"])
    library.add(22, "ISO 9001:2015 for Small Enterprises - What to do ?", ["ISO"])
    entries = m.run(21)
    b = library.books[21]
    b["title"].should eq("DIN EN ISO 14971:2009-10 – Anwendung des Risikomanagements auf Medizinprodukte")
    b["authors"].should eq(JSON.parse(%(["DIN"])))
    b["publisher"].should eq("Beuth")
    b["pubdate"].as_s.should start_with("2009-10-01")
    b["languages"].should eq(JSON.parse(%(["deu"])))
    b["comments"].should eq("<p>Medizinprodukte – Anwendung des Risikomanagements auf Medizinprodukte</p>")
    b["identifiers"].should eq(JSON.parse(%({"din": "DIN EN ISO 14971:2009-10"})))
    b["tags"].should eq(JSON.parse(%(["Norm", "auto-metadaten"])))
    entries.map(&.field).sort.should eq(%w(authors comments identifier:din languages pubdate publisher tags title))
    entries.all? { |e| e.source == "rules" }.should be_true
    # the older edition got "ersetzt" from the newer one, logged
    library.books[20]["tags"].should eq(JSON.parse(%(["Lesen", "ersetzt", "auto-metadaten"])))
    m.log.list(20_i64).map { |e| {e.field, e.old, e.new} }.should eq([{"tags", JSON.parse("[]"), JSON.parse(%(["ersetzt"]))}])
    web.requests.should be_empty
    m.log.status(21).should eq("done")
    m.run(21).should be_empty

    # its own run names it and keeps "ersetzt"
    m.run(20).map(&.field).sort.should eq(%w(authors comments identifier:din pubdate publisher tags title))
    library.books[20]["title"].should eq("DIN EN ISO 14971:2001-03 – Anwendung des Risikomanagements auf Medizinprodukte")
    library.books[20]["tags"].should eq(JSON.parse(%(["Lesen", "ersetzt", "auto-metadaten", "Norm"])))
    web.requests.should be_empty

    # tags are reverted like the other fields, the last change takes auto-metadaten
    m.revert_books([20_i64]).each { |id| m.revert(id) }
    library.books[20]["tags"].should eq(JSON.parse(%(["Lesen"])))
    library.books[20]["title"].as_s.should start_with("[DIN EN ISO 14971 2001-03]")

    # a book about a standard goes the usual way
    m.run(22)
    web.requests.should_not be_empty
    library.books[22]["title"].should eq("ISO 9001:2015 for Small Enterprises - What to do ?")
    m.candidates(21).map(&.source).should eq(["rules"])
  end

  it "decides an unclear file name by a good match of the sources (#8408)" do
    library, _, m, _, _ = setup(sources: %w(openlibrary))
    library.add(25, "Ursula K. Le Guin", ["The Left Hand of Darkness"])
    readings = [CalibreHub::Meta::Guess.new("Ursula K. Le Guin", ["The Left Hand of Darkness"]),
                CalibreHub::Meta::Guess.new("The Left Hand of Darkness", ["Ursula K. Le Guin"])]
    book = m.@calibre.book(25).not_nil!
    g, by = m.decide(book, "x.epub", readings).not_nil!
    {g.title, g.authors, by}.should eq({"The Left Hand of Darkness", ["Ursula K. Le Guin"], "openlibrary"})
    # nothing found, no model: undecided
    m.decide(book, "x.epub", [CalibreHub::Meta::Guess.new("Wolken", ["Atlas"]), CalibreHub::Meta::Guess.new("Atlas", ["Wolken"])]).should be_nil
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

private def hc_query(title, author, languages = [] of String, publisher = nil)
  CalibreHub::Meta::Query.new(title, author, languages, publisher)
end

# A JWT-shaped token with this expiry (not signed: only exp is read)
private def jwt(exp : Time) : String
  payload = Base64.urlsafe_encode(%({"exp": #{exp.to_unix}}), padding: false)
  "eyJhbGciOiJIUzI1NiJ9.#{payload}.signature"
end

describe CalibreHub::Meta::Hardcover do
  it "reads an edition by ISBN: title, subtitle, author (not the translator), publisher, description" do
    data = JSON.parse(fixture("hardcover_isbn_effortless.json"))["data"]
    c = CalibreHub::Meta::Hardcover.parse_editions(data, "9780593135648").first
    f = c.fields
    {c.source, c.by_isbn, c.url}.should eq({"hardcover", "9780593135648", "https://hardcover.app/books/effortless"})
    {f.title, f.subtitle, f.authors}.should eq({"Effortless", "Make It Easier to Do What Matters Most", ["Greg McKeown"]})
    {f.isbn, f.publisher, f.languages}.should eq({"9780593135648", "Crown Currency", ["eng"]})
    # "2021-01-01" is a year, not a day
    f.pubdate.should eq("2021")
    f.comments.not_nil!.should start_with("<p>NEW YORK TIMES BESTSELLER")
  end

  it "searches only very similar title and author, no summary, no placeholder" do
    data = JSON.parse(fixture("hardcover_search_effortless.json"))["data"]
    # "Summary: Effortless by Greg McKeown" (Meaningful Publishing) is not the book
    CalibreHub::Meta::Hardcover.hits(data, hc_query("Effortless", "Greg Mckeown", ["eng"])).should eq([427508_i64, 2789518_i64])
    CalibreHub::Meta::Hardcover.hits(data, hc_query("Effortless", "Daniel Pink", ["eng"])).should be_empty
    CalibreHub::Meta::Hardcover.hits(data, hc_query("Effortless Living", "Greg McKeown", ["eng"])).should be_empty
    untitled = JSON.parse(%({"search": {"results": {"hits": [{"document": {"id": "1", "title": "Untitled", "author_names": ["Rebecca Yarros"]}}]}}}))
    CalibreHub::Meta::Hardcover.hits(untitled, hc_query("Untitled", "Rebecca Yarros")).should be_empty
  end

  it "takes a searched work only with an edition in the book's language (Effortless: English, not the German one)" do
    data = JSON.parse(fixture("hardcover_books_effortless.json"))["data"]
    ids = [427508_i64, 2789518_i64]
    english = CalibreHub::Meta::Hardcover.parse_books(data, hc_query("Effortless", "Greg Mckeown", ["eng"], "Crown"), ids)
    english.map(&.url).should eq(["https://hardcover.app/books/effortless"])
    # the only edition of the book's publisher: its ISBN and publisher
    c = english.first
    c.edition.should be_true
    {c.fields.isbn, c.fields.publisher, c.fields.languages}.should eq({"9780593135648", "Crown Currency", ["eng"]})
    # without a publisher it isn't clear which of the English editions
    unclear = CalibreHub::Meta::Hardcover.parse_books(data, hc_query("Effortless", "Greg Mckeown", ["eng"]), ids).first
    {unclear.edition, unclear.fields.isbn, unclear.fields.publisher}.should eq({false, nil, nil})
    # unknown language and an English title: English
    CalibreHub::Meta::Hardcover.parse_books(data, hc_query("Effortless", "Greg Mckeown"), ids).map(&.url).should eq(["https://hardcover.app/books/effortless"])
    german = CalibreHub::Meta::Hardcover.parse_books(data, hc_query("Effortless", "Greg McKeown", ["deu"]), ids)
    german.map(&.fields.languages).should eq([["deu"]])
  end

  it "pauses on a rejected token and alerts once a day" do
    db = DB.open("sqlite3://#{File.tempname("hub-alert", ".sqlite")}?max_pool_size=1")
    dir = File.tempname("hub-alert")
    Dir.mkdir(dir)
    log = File.join(dir, "alerts.log")
    script = File.join(dir, "alert")
    File.write(script, "#!/bin/sh\necho \"$1|$2\" >> #{log}\n")
    File.chmod(script, 0o755)
    alert = CalibreHub::DailyAlert.new(db, [script])
    web = FakeSources.new
    http = CalibreHub::Meta::Http.new(Time::Span.zero, 5.seconds)
    hc = CalibreHub::Meta::Hardcover.new(http, "Bearer wrong", "#{web.url}/hc", alert.proc)
    hc.enabled?.should be_true
    hc.by_isbn("9780593135648").should be_empty
    hc.available?.should be_false
    hc.paused_until.not_nil!.should be > Time.utc + 50.minutes
    # paused: no more requests
    hc.search(hc_query("Effortless", "Greg McKeown", ["eng"])).should be_empty
    web.requests.count("/hc").should eq(1)
    # a new instance (restart) with the same state DB: no second alert today
    CalibreHub::Meta::Hardcover.new(http, "wrong", "#{web.url}/hc", alert.proc).by_isbn("9780593135648")
    lines = File.read_lines(log)
    lines.size.should eq(1)
    lines.first.should start_with("calibre-hub: Hardcover-Token abgelaufen oder ungültig|")
    alert.call("hardcover-token", "s", "t", Time.utc + 25.hours).should be_true
    # with the right token ("Bearer " from the token page is fine)
    ok = CalibreHub::Meta::Hardcover.new(http, "Bearer hc-token\n", "#{web.url}/hc", alert.proc)
    ok.by_isbn("9780593135648").first.fields.title.should eq("Effortless")
  end

  it "doesn't count an alert whose command failed" do
    db = DB.open("sqlite3://#{File.tempname("hub-alert", ".sqlite")}?max_pool_size=1")
    dir = File.tempname("hub-alert")
    Dir.mkdir(dir)
    log = File.join(dir, "alerts.log")
    script = File.join(dir, "alert")
    # fails until the mail relay is back (a marker file)
    File.write(script, "#!/bin/sh\ntest -e #{dir}/up || exit 1\necho \"$1\" >> #{log}\n")
    File.chmod(script, 0o755)
    alert = CalibreHub::DailyAlert.new(db, [script])
    alert.call("k", "eins", "t").should be_false
    File.write(File.join(dir, "up"), "")
    alert.call("k", "zwei", "t").should be_true
    alert.call("k", "drei", "t").should be_false
    File.read_lines(log).should eq(["zwei"])
    # a command that doesn't exist: not sent either
    missing = CalibreHub::DailyAlert.new(db, [File.join(dir, "nope")])
    missing.call("m", "s", "t").should be_false
    db.query_one?("select at from alerts where key = 'm'", as: Int64).should be_nil
  ensure
    db.try &.close
    dir.try { |d| FileUtils.rm_rf(d) }
  end

  it "warns 14 days before a JWT token expires" do
    sent = [] of {String, String, String}
    alert = ->(k : String, s : String, t : String) { sent << {k, s, t}; nil }
    http = CalibreHub::Meta::Http.new(Time::Span.zero, 5.seconds)
    now = Time.utc
    CalibreHub::Meta::Hardcover.new(http, jwt(now + 30.days), "http://127.0.0.1:9/hc", alert).available?(now).should be_true
    CalibreHub::Meta::Hardcover.new(http, "opaque-token", "http://127.0.0.1:9/hc", alert).available?(now).should be_true
    sent.should be_empty
    CalibreHub::Meta::Hardcover.new(http, "Bearer #{jwt(now + 10.days)}", "http://127.0.0.1:9/hc", alert).available?(now).should be_true
    sent.map(&.[0]).should eq(["hardcover-token-expiry"])
    sent.first[1].should eq("calibre-hub: Hardcover-Token läuft bald ab")
    CalibreHub::Meta::Hardcover.expiry(jwt(Time.unix(1_900_000_000))).should eq(Time.unix(1_900_000_000))
    CalibreHub::Meta::Hardcover.expiry("a.b.c").should be_nil
  end
end

describe "stricter DNB" do
  it "searches by title only for German books, always with author and language" do
    CalibreHub::Meta::Dnb.cql(hc_query("Effortless", "Greg Mckeown", ["eng"])).should be_nil
    # unknown language: only a German-looking title
    CalibreHub::Meta::Dnb.cql(hc_query("Effortless", "Greg Mckeown")).should be_nil
    CalibreHub::Meta::Dnb.cql(hc_query("Der Schwarm", nil, ["deu"])).should be_nil
    CalibreHub::Meta::Dnb.cql(hc_query("Der Schwarm", "Frank Schätzing")).should eq(%(tit="Der Schwarm" and per="Schätzing" and spr=ger))
    CalibreHub::Meta::Dnb.cql(hc_query("Psychokybernetik", "Maxwell Maltz", ["deu"])).should eq(%(tit="Psychokybernetik" and per="Maltz" and spr=ger))
  end

  it "rejects the German translations of an English book (live: Effortless, REDLINE)" do
    list = CalibreHub::Meta::Dnb.parse(fixture("dnb_search_effortless.xml"))
    list.size.should eq(4)
    list.all?(&.translation).should be_true
    list.all? { |c| c.fields.languages == ["deu"] }.should be_true
    list.each do |c|
      CalibreHub::Meta::Match.reject(c, ["eng"], "Effortless", [] of String).should eq("translation")
      # unknown language, English title: not German, so no translation either
      CalibreHub::Meta::Match.reject(c, [] of String, "Effortless", [] of String).should eq("translation")
      # a German book may be a translation
      CalibreHub::Meta::Match.reject(c, ["deu"], "Effortless", [] of String).should be_nil
    end
    # "und" (undetermined, live: #31 from its OPF) is no language: a German
    # title makes the book German, an English one doesn't
    german = list.first.tap { |c| c.fields.title = "Die Psychologie sexueller Leidenschaft" }
    CalibreHub::Meta::Match.reject(german, ["und"], "Die Psychologie sexueller Leidenschaft", [] of String).should be_nil
    CalibreHub::Meta::Match.reject(german, ["und"], "Effortless", [] of String).should eq("translation")
    CalibreHub::Meta::Lang.known(["und", "deu", "zxx"]).should eq(["deu"])
    # found by the book's own ISBN it is this edition
    own = list.first.tap { |c| c.by_isbn = c.fields.isbn }
    CalibreHub::Meta::Match.reject(own, ["eng"], "Effortless", [own.fields.isbn.not_nil!]).should be_nil
  end

  it "compares the volume of a multi-volume work (live: Baden Powell, Songbook Vol. 1/2/3)" do
    list = CalibreHub::Meta::Dnb.parse(fixture("dnb_search_songbook.xml"))
    list.map { |c| {c.fields.title, c.volume} }.should eq([
      {"Songbook. Vol. 3", "3"}, {"Songbook. Vol. 2", "2"}, {"Songbook. Vol. 1", "1"}, {"Songbook. Vol. 2", "2"},
    ])
    keep = ->(title : String) { list.select { |c| CalibreHub::Meta::Match.reject(c, ["deu"], title, [] of String).nil? }.map(&.volume) }
    keep.call("Songbook, Vol. 1 (Guitar Scores)").should eq(["1"])
    keep.call("Songbook, Vol. 2 (Guitar Scores)").should eq(["2", "2"])
    keep.call("Songbook").should eq(["3", "2", "1", "2"])
    CalibreHub::Meta::Text.volume("Der Herr der Ringe, Band II").should eq("2")
    CalibreHub::Meta::Text.volume("Teil 3: Die Rückkehr").should eq("3")
    CalibreHub::Meta::Text.volume("Volume IV").should eq("4")
    CalibreHub::Meta::Text.volume("Dune").should be_nil
  end

  it "reads a co-author from a DNB record (live: Kegan & Lahey)" do
    c = CalibreHub::Meta::Dnb.parse(fixture("dnb_isbn_kegan.xml")).first
    c.fields.authors.should eq(["Robert Kegan", "Lisa Laskow Lahey"])
    c.fields.languages.should eq(["eng"])
    c.translation.should be_false
  end
end

describe "merge precedence (#8449)" do
  sure = ->(c : CalibreHub::Meta::Candidate, isbn : String) { c.by_isbn = isbn; c.sure = true; c.score = 1.0; c }

  it "adds Hardcover's subtitle and description and the DNB's co-author (live: Kegan)" do
    isbn = "9780787958664"
    hc = sure.call(CalibreHub::Meta::Hardcover.parse_editions(JSON.parse(fixture("hardcover_isbn_kegan.json"))["data"], isbn).first, isbn)
    dnb = sure.call(CalibreHub::Meta::Dnb.parse(fixture("dnb_isbn_kegan.xml")).first, isbn)
    ol = CalibreHub::Meta::Candidate.new("openlibrary", record(title: "How the Way We Talk Can Change the Way We Work", comments: "<p>OL</p>"))
    ol.score = 0.9
    b = book("How the Way We Talk Can Change the Way We Work", ["Robert Kegan"], isbn: isbn, languages: ["eng"],
      publisher: "John Wiley & Sons", pubdate: Time.utc(2001, 1, 1, 12, 0, 0))
    changes = CalibreHub::Meta::Merge.plan(b, nil, nil, [ol, dnb, hc]).to_h { |c| {c.field, {c.new, c.source}} }
    changes["title"].should eq({JSON::Any.new("How the Way We Talk Can Change the Way We Work: Seven Languages for Transformation"), "hardcover"})
    changes["authors"].should eq({JSON.parse(%(["Robert Kegan", "Lisa Laskow Lahey"])), "dnb"})
    changes["comments"][1].should eq("hardcover")
    changes.has_key?("publisher").should be_false
    changes.has_key?("pubdate").should be_false
  end

  it "never takes Hardcover's year, publisher or language over the book's (live: Essentialism 2014, $100M Offers)" do
    isbn = "9780593135648"
    hc = sure.call(CalibreHub::Meta::Candidate.new("hardcover", record(title: "Essentialism", authors: ["Greg McKeown"],
      isbn: isbn, publisher: "Random House", pubdate: "2011", languages: ["deu"], comments: "<p>HC</p>")), isbn)
    b = book("Essentialism", ["Greg McKeown"], isbn: isbn, publisher: "Ebury Publishing", languages: ["eng"],
      pubdate: Time.utc(2014, 4, 1, 12, 0, 0))
    CalibreHub::Meta::Merge.plan(b, nil, nil, [hc]).map(&.field).should eq(["comments"])
    # an empty field it fills, after the edition sources
    dnb = sure.call(CalibreHub::Meta::Candidate.new("dnb", record(title: "Essentialism", publisher: "Ebury", pubdate: "2014")), isbn)
    empty = book("Essentialism", ["Greg McKeown"], isbn: isbn, languages: ["eng"])
    changes = CalibreHub::Meta::Merge.plan(empty, nil, nil, [hc, dnb]).to_h { |c| {c.field, {c.new.raw, c.source}} }
    changes["publisher"].should eq({"Ebury", "dnb"})
    changes["pubdate"].should eq({"2014", "dnb"})
    CalibreHub::Meta::Merge.plan(empty, nil, nil, [hc]).find! { |c| c.field == "publisher" }.source.should eq("hardcover")
  end

  it "takes descriptions Hardcover first, then DNB, then Open Library" do
    mk = ->(source : String, text : String) do
      c = CalibreHub::Meta::Candidate.new(source, record(title: "Dune", authors: ["Frank Herbert"], comments: text))
      c.score = 0.95
      c
    end
    list = [mk.call("openlibrary", "<p>OL</p>"), mk.call("dnb", "<p>DNB</p>"), mk.call("hardcover", "<p>HC</p>")]
    CalibreHub::Meta::Merge.plan(book, nil, nil, list).find! { |c| c.field == "comments" }.new.should eq("<p>HC</p>")
    CalibreHub::Meta::Merge.plan(book, nil, nil, list[0, 2]).find! { |c| c.field == "comments" }.new.should eq("<p>DNB</p>")
  end

  it "uses the year and publisher of a \"(1974, Tonos)\" title suffix for empty fields" do
    title = "Baden Powell - Baden Powell. Songbook, Vol. 2 (Guitar Scores) (1974, Tonos)"
    g = CalibreHub::Meta::Clean.guesses(title, ["libgen.lc"])[0].first
    {g.title, g.authors, g.publisher, g.pubdate}.should eq({"Songbook, Vol. 2 (Guitar Scores)", ["Baden Powell"], "Tonos", "1974"})
    changes = CalibreHub::Meta::Merge.plan(book(title, ["libgen.lc"]), g, nil, [] of CalibreHub::Meta::Candidate).to_h { |c| {c.field, {c.new.raw, c.source}} }
    changes["publisher"].should eq({"Tonos", "rules"})
    changes["pubdate"].should eq({"1974", "rules"})
    # a date already there stays
    dated = book(title, ["libgen.lc"], pubdate: Time.utc(2003, 1, 1, 12, 0, 0))
    CalibreHub::Meta::Merge.plan(dated, g, nil, [] of CalibreHub::Meta::Candidate).map(&.field).should_not contain("pubdate")
    h = CalibreHub::Meta::Clean.guesses("Brian Hodel - The Brazilian Masters (Guitar Scores) (, TRO Hollis Music, Inc.)", ["libgen.lc"])[0].first
    {h.publisher, h.pubdate}.should eq({"TRO Hollis Music, Inc.", nil})
  end
end

describe "Mc and Mac" do
  {
    "GREG MCKEOWN"     => "Greg McKeown",
    "greg mckeown"     => "Greg McKeown",
    "Greg Mckeown"     => "Greg McKeown",
    "Greg McKeown"     => "Greg McKeown",
    "RAMSAY MACDONALD" => "Ramsay MacDonald",
    "Ramsay MacDonald" => "Ramsay MacDonald",
    # written so on purpose: only all caps or lower case get the Mac rule
    "John A. Macdonald" => "John A. Macdonald",
    "JOHN MACK"         => "John Mack",
    "MACY GRAY"         => "Macy Gray",
    "ROSE MACAULAY"     => "Rose Macaulay",
    "ANTONIO MACHADO"   => "Antonio Machado",
    "MARIA MACIAS"      => "Maria Macias",
  }.each do |name, want|
    it "writes #{name.inspect} as #{want.inspect}" do
      CalibreHub::Meta::Clean.authors([name]).should eq([want])
    end
  end

  it "makes a book with \"Mckeown\" messy and prefers \"McKeown\" when unifying" do
    CalibreHub::Meta::Clean.messy?(book("Effortless", ["Greg Mckeown"])).should be_true
    CalibreHub::Meta::Clean.messy?(book("Effortless", ["Greg McKeown"])).should be_false
    CalibreHub::Meta::Authors.groups({"Greg Mckeown" => 3, "Greg McKeown" => 1}).should eq([{"Greg McKeown", ["Greg Mckeown"]}])
    # a source's "McKeown" is the better spelling
    CalibreHub::Meta::Merge.better_form?("Greg McKeown", "Greg Mckeown").should be_true
    CalibreHub::Meta::Merge.better_form?("Greg Mckeown", "Greg McKeown").should be_false
  end
end

describe "the catalogs for a reading without an author" do
  it "asks them, and a source that fails counts as not knowing (#8528)" do
    _, web, m, _, _ = setup(sources: %w(openlibrary dnb))
    b = book("The Left Hand of Darkness", ["Unknown"])
    g = CalibreHub::Meta::Guess.new("The Left Hand of Darkness", [] of String)
    v = m.check(b, g).not_nil!
    # one catalog: a suggestion, not a decision
    v.confirmed.should be_false
    v.authors.should eq ["Ursula K. Le Guin"]
    web.down = true
    m.check(b, g).should be_nil
  end

  it "searches Hardcover and the DNB by the title alone" do
    q = hc_query("Der Schwarm im Eis", nil, ["deu"])
    CalibreHub::Meta::Dnb.cql(q).should eq(%(tit="Der Schwarm im Eis" and spr=ger))
    data = JSON.parse(%({"search":{"results":{"hits":[{"document":{"id":"7","title":"The Pragmatic Programmer","author_names":["Andrew Hunt"]}},
      {"document":{"id":"8","title":"The Pragmatic Programmer: Summary","author_names":["Quick Reads"]}}]}}}))
    CalibreHub::Meta::Hardcover.hits(data, hc_query("The Pragmatic Programmer", nil)).should eq [7_i64]
    CalibreHub::Meta::Hardcover.hits(data, hc_query("Programmer", nil)).should be_empty
  end
end

describe "metadata run with Hardcover" do
  it "takes the English Effortless from Hardcover and doesn't ask the DNB" do
    library, web, m, _, _ = setup(sources: %w(file hardcover dnb openlibrary), hardcover_token: "hc-token")
    library.add(23, "Effortless", ["Greg Mckeown"], publisher: "Crown", languages: ["eng"])
    m.run(23)
    b = library.books[23]
    b["title"].should eq("Effortless: Make It Easier to Do What Matters Most")
    b["authors"].should eq(JSON.parse(%(["Greg McKeown"])))
    b["pubdate"].as_s.should start_with("2021")
    b["identifiers"].should eq(JSON.parse(%({"isbn": "9780593135648"})))
    b["publisher"].should eq("Crown")
    b["languages"].should eq(JSON.parse(%(["eng"])))
    b["comments"].as_s.should start_with("<p>NEW YORK TIMES BESTSELLER")
    sources = m.log.list(23).to_h { |e| {e.field, e.source} }
    sources.should eq({"title" => "hardcover", "authors" => "rules", "isbn" => "hardcover", "pubdate" => "hardcover", "comments" => "hardcover"})
    web.requests.none?(&.includes?("query=tit")).should be_true
    m.log.status(23).should eq("done")
  end

  it "goes on without Hardcover when the token is rejected" do
    sent = [] of String
    alert = ->(k : String, _s : String, _t : String) { sent << k; nil }
    file = CalibreHub::Meta::FileMeta::Info.new(record, ["9783608938289"])
    library, _, m, _, _ = setup(->(_b : CalibreHub::Book) { file.as(CalibreHub::Meta::FileMeta::Info?) },
      %w(file hardcover dnb openlibrary), hardcover_token: "expired", alert: alert)
    library.add(1, "Der Herr der Ringe", ["Tolkien"])
    m.run(1)
    library.books[1]["publisher"].should eq("Klett-Cotta")
    sent.should eq(["hardcover-token"])
    # not a failed source: the book isn't retried for it
    m.log.status(1).should eq("done")
    m.active_sources.should eq(%w(file hardcover dnb openlibrary))
    setup(sources: %w(file hardcover dnb openlibrary))[2].active_sources.should eq(%w(file dnb openlibrary))
  end
end
