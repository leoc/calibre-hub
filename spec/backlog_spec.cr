require "spec"
require "file_utils"
require "../src/calibre_hub/backlog_jobs"
require "../src/calibre_hub/import_repair"

private alias Backlog = CalibreHub::Backlog

OPF_XML = <<-XML
  <?xml version='1.0' encoding='utf-8'?>
  <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="uuid_id" version="2.0">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
          <dc:identifier opf:scheme="calibre" id="calibre_id">257</dc:identifier>
          <dc:identifier opf:scheme="uuid" id="uuid_id">9df8db60-ef64-4c8b-b3ab-baadf37e4528</dc:identifier>
          <dc:title>Problem Solving 101: A Simple Book for Smart People</dc:title>
          <dc:creator opf:file-as="Watanabe, Ken" opf:role="aut">Ken Watanabe</dc:creator>
          <dc:contributor opf:file-as="calibre" opf:role="bkp">calibre (4.13.0) [https://calibre-ebook.com]</dc:contributor>
          <dc:date>2009-04-15T11:01:26.335061+00:00</dc:date>
          <dc:description>The fun and simple problem-solving guide</dc:description>
          <dc:publisher>Portfolio</dc:publisher>
          <dc:identifier opf:scheme="ISBN">9781101028483</dc:identifier>
          <dc:identifier opf:scheme="MOBI-ASIN">B001UFP61C</dc:identifier>
          <dc:language>eng</dc:language>
          <dc:subject>Business</dc:subject>
          <dc:subject>Thinking</dc:subject>
          <meta content="Toolbox" name="calibre:series"/>
          <meta content="2.0" name="calibre:series_index"/>
      </metadata>
  </package>
  XML

private def opf(title : String, author : String, isbn : String? = nil) : String
  OPF_XML.sub("Problem Solving 101: A Simple Book for Smart People", title).gsub("Ken Watanabe", author)
    .sub("9781101028483", isbn || "").sub(%(<dc:identifier opf:scheme="ISBN"></dc:identifier>), "")
end

private def write(path : String, content : String | Bytes)
  Dir.mkdir_p(File.dirname(path))
  File.write(path, content)
end

private def pdf(text = "x") : String
  "%PDF-1.4\n" + text + ("." * 4000)
end

private def epub(text = "x") : String
  "PK\u0003\u0004" + text + ("." * 4000)
end

private def mobi(text = "x") : String
  ("\0" * 60) + "BOOKMOBI" + text + ("." * 4000)
end

private def tmpdir(&)
  dir = File.tempname("backlog")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def book(id : Int64, title : String, authors : Array(String), formats = ["EPUB"], isbn : String? = nil) : CalibreHub::Book
  CalibreHub::Book.new(id: id, title: title, authors: authors, author_sort: nil, tags: [] of String, series: nil,
    series_index: nil, formats: formats, last_modified: Time.utc, timestamp: nil, pubdate: nil, rating: nil,
    publisher: nil, identifiers: isbn ? {"isbn" => isbn} : {} of String => String, languages: [] of String,
    comments: nil, custom: {} of String => JSON::Any)
end

# calibre-server for the import: add-book, set-fields, list, remove, search
private class FakeCalibre
  getter books = {} of Int64 => Hash(String, JSON::Any)
  getter requests = [] of {String, JSON::Any}
  getter url : String
  # add-book answers these titles (from the file name) as duplicates
  property duplicate_titles = {} of String => Int64
  # what calibre "reads" from a file without OPF: file name -> {title, author, isbn}
  property file_meta = {} of String => {String, String, String?}
  # books calibre lists but set-fields fails for (NoSuchBook, HTTP 500)
  getter no_such_book = Set(Int64).new
  @next = 100_i64

  def initialize
    @server = HTTP::Server.new do |ctx|
      path = ctx.request.path
      ctx.response.content_type = "application/json"
      if path.starts_with?("/cdb/add-book/")
        ctx.request.body.try(&.gets_to_end)
        name = URI.decode(path.split('/')[5])
        @requests << {"add-book", JSON::Any.new(name)}
        # without metadata in the file, calibre reads "Title - Author" from its name
        read = CalibreHub::Meta::FileName.calibre(name)
        meta = @file_meta[name]? || {read[0], read[1].first, nil}
        authors = @file_meta.has_key?(name) ? [meta[1]] : read[1]
        if (dup = @duplicate_titles[meta[0]]?) && path.split('/')[4] == "n"
          b = @books[dup]
          ctx.response.print({duplicates: [{title: b["title"], authors: b["authors"]}]}.to_json)
        else
          id = (@next += 1)
          ext = File.extname(name).lchop('.').upcase
          @books[id] = {"title" => JSON::Any.new(meta[0]), "authors" => JSON.parse(authors.to_json),
                        "formats" => JSON.parse([ext].to_json), "tags" => JSON.parse(%(["embedded"])),
                        "identifiers" => JSON.parse((meta[2] ? {"isbn" => meta[2]} : {} of String => String).to_json)}
          ctx.response.print({book_id: id}.to_json)
        end
        next
      end
      body = JSON.parse(ctx.request.body.try(&.gets_to_end).presence || "null")
      @requests << {path, body}
      case path
      when %r{^/cdb/set-fields/(\d+)}
        id = $1.to_i64
        b = @books[id]?
        if b.nil? || @no_such_book.includes?(id)
          ctx.response.status_code = 500
          ctx.response.print "calibre.db.errors.NoSuchBook: 'No book with id: #{id} in database'"
          next
        end
        body["changes"].as_h.each do |k, v|
          if k == "added_formats"
            b["formats"] = JSON.parse((b["formats"].as_a.map(&.as_s) + v.as_a.map(&.["ext"].as_s.upcase)).uniq.to_json)
          else
            b[k] = v
          end
        end
        ctx.response.print %({})
      when "/cdb/cmd/list/0"
        fields = body[0].as_a.map(&.as_s)
        ids = if (m = body[3].as_s.scan(/id:(\d+)/)) && !m.empty?
                m.map(&.[1].to_i64).select { |i| @books.has_key?(i) }
              else
                @books.keys
              end
        data = fields.to_h { |f| {f.sub('*', '#'), ids.to_h { |i| {i.to_s, @books[i][f.sub('*', '#')]? || JSON::Any.new(nil)} }} }
        ctx.response.print({result: {book_ids: ids, data: data}}.to_json)
      when "/cdb/cmd/remove/0"
        body[0].as_a.each { |i| @books.delete(i.as_i64) }
        ctx.response.print %({"result":null})
      when "/ajax/search"
        q = ctx.request.query_params["query"]
        title = q[/title:"=([^"]+)"/, 1]?
        ids = @books.select { |_, b| b["title"].as_s == title }.keys
        ctx.response.print({total_num: ids.size, book_ids: ids}.to_json)
      else
        ctx.response.status_code = 404
      end
    end
    @url = "http://127.0.0.1:#{@server.bind_tcp("127.0.0.1", 0).port}"
    spawn { @server.listen }
  end

  def add(id : Int64, title : String, authors : Array(String), formats = ["EPUB"], isbn : String? = nil,
          tags = [] of String, kategorie : String? = nil)
    @books[id] = {"title" => JSON::Any.new(title), "authors" => JSON.parse(authors.to_json),
                  "formats" => JSON.parse(formats.to_json), "tags" => JSON.parse(tags.to_json),
                  "identifiers" => JSON.parse((isbn ? {"isbn" => isbn} : {} of String => String).to_json),
                  "#kategorie" => JSON::Any.new(kategorie)}
  end

  def calibre : CalibreHub::Calibre
    CalibreHub::Calibre.new(url, "hub", "pw", nil, ["kategorie"])
  end
end

private def state_db : DB::Database
  db = DB.open("sqlite3:%3Amemory%3A?max_pool_size=1")
  db.exec "create table if not exists events (id integer primary key autoincrement, type text not null, book_id integer not null, payload text not null, created_at integer not null, done_at integer)"
  db
end

private def wait_job(jobs : CalibreHub::Jobs, id : String) : CalibreHub::Jobs::Job
  200.times do
    j = jobs[id]?.not_nil!
    return j unless j.status == "running"
    sleep 20.milliseconds
  end
  raise "job #{id} still running"
end

# planned as a recheck plans them: book -> the file an import read
private def plan(repair : CalibreHub::ImportRepair, books : Hash(Int32, String?))
  books.each { |id, path| repair.recheck(id.to_i64, path) }
end

private def open_proposals(repair : CalibreHub::ImportRepair) : Hash(Int64, CalibreHub::ImportRepair::Proposal)
  repair.proposals("pending").to_h { |p| {p.book_id, p} }
end

private def opf_series(title : String, author : String, series : String, index : String, isbn : String? = nil) : String
  opf(title, author, isbn).sub(%(content="Toolbox"), %(content="#{series}")).sub(%(content="2.0"), %(content="#{index}"))
end

describe Backlog::OpfMeta do
  it "takes the fields of a calibre folder's metadata.opf, without the old library's ids" do
    m = Backlog::OpfMeta.parse(OPF_XML)
    m.title.should eq "Problem Solving 101: A Simple Book for Smart People"
    m.authors.should eq ["Ken Watanabe"]
    m.tags.should eq ["Business", "Thinking"]
    m.series.should eq "Toolbox"
    m.series_index.should eq 2.0
    m.identifiers.should eq({"isbn" => "9781101028483", "mobi-asin" => "B001UFP61C"})
    m.languages.should eq ["eng"]
    m.publisher.should eq "Portfolio"
    m.pubdate.should eq "2009-04-15"
    c = m.changes
    c["pubdate"].should eq "2009-04-15T12:00:00+00:00"
    c["series_index"].should eq 2.0
    c["tags"].as_a.map(&.as_s).should eq ["Business", "Thinking"]
    c.has_key?("#kategorie").should be_false
  end

  it "always sets the tags, so none calibre read from the file stay" do
    m = Backlog::OpfMeta.parse(opf("T", "A").gsub(%r{<dc:subject>[^<]*</dc:subject>}, ""))
    m.changes["tags"].as_a.should be_empty
  end
end

describe Backlog::Scanner do
  it "finds calibre folders, books by name and skips everything else" do
    tmpdir do |root|
      cal = File.join(root, "Ken Watanabe", "Problem Solving 101 (257)")
      write(File.join(cal, "metadata.opf"), OPF_XML)
      write(File.join(cal, "cover.jpg"), "jpg")
      write(File.join(cal, "Problem Solving.mobi"), mobi)
      write(File.join(cal, "Problem Solving.epub"), epub)
      write(File.join(cal, "notes.html"), "<html>")
      write(File.join(root, "Some Author", "book.pdf"), pdf)
      write(File.join(root, "Some Author", "book.epub"), epub)
      write(File.join(root, "Some Author", "other.pdf"), pdf("o"))
      write(File.join(root, "Music", "song.mp3"), "ID3")
      write(File.join(root, "tiny.pdf"), "%PDF-1.4")
      write(File.join(root, "broken.pdf"), "<html>" + "." * 4000)
      write(File.join(root, "readme.txt"), "short")
      write(File.join(root, "Languages", "._a.mp3"), "x")
      write(File.join(root, "_imported", "2026-11-02", "x.pdf"), pdf)
      write(File.join(root, "_SORT", "sorted.pdf"), pdf("s"))
      write(File.join(root, "Empty (3)", "metadata.opf"), OPF_XML)

      scan = Backlog::Scanner.new(root).run
      units = scan.units.map { |u| {u.kind, u.files.map { |f| File.basename(f.path) }.sort} }
      units.should contain({"calibre", ["Problem Solving.epub", "Problem Solving.mobi"]})
      units.should contain({"file", ["book.epub", "book.pdf"]})
      units.should contain({"file", ["other.pdf"]})
      # only the inbox's own folders are left out, not every "_" folder
      units.should contain({"file", ["sorted.pdf"]})
      scan.units.size.should eq 4
      cu = scan.units.find(&.kind.==("calibre")).not_nil!
      cu.cover.should eq File.join(cal, "cover.jpg")
      cu.primary.format.should eq "EPUB"
      reasons = scan.skipped.to_h { |s| {s.path.lchop(root + "/"), s.reason} }
      reasons["Ken Watanabe/Problem Solving 101 (257)/notes.html"].should eq "not a book format"
      reasons["Music/song.mp3"].should eq "not a book format"
      reasons["tiny.pdf"].should eq "too small"
      reasons["broken.pdf"].should eq "broken (not a PDF file)"
      reasons["readme.txt"].should eq "too small"
      reasons["Languages/._a.mp3"].should eq "hidden file"
      reasons["_imported/"].should eq "inbox folder"
      reasons["Empty (3)/metadata.opf"].should eq "calibre folder without a book file"
      scan.units.size.should eq 4
      scan.units.count(&.kind.==("calibre")).should eq 1
    end
  end

  it "walks several folders and lets other fibers run meanwhile" do
    tmpdir do |root|
      100.times { |i| write(File.join(root, "a", "f#{i}.txt"), "x") }
      write(File.join(root, "b", "book.pdf"), pdf)
      write(File.join(root, "b", "_imported", "x.pdf"), pdf("x"))
      ran = false
      seen = false
      spawn { ran = true }
      scan = Backlog::Scanner.new([File.join(root, "a"), File.join(root, "b")])
      scan.on_progress = ->(files : Int32, units : Int32) { seen ||= ran; nil }
      scan.run
      seen.should be_true
      scan.files.should eq 101
      scan.units.map { |u| File.basename(u.files.first.path) }.should eq ["book.pdf"]
      # the inbox's folders at the top of every scanned folder
      scan.skipped.map(&.reason).should contain("inbox folder")
    end
  end

  it "skips files an earlier run handled, unless they changed" do
    tmpdir do |root|
      write(File.join(root, "a.pdf"), pdf)
      write(File.join(root, "b.pdf"), pdf("b"))
      a = File.info(File.join(root, "a.pdf"))
      b = File.info(File.join(root, "b.pdf"))
      known = Backlog::Known{File.join(root, "a.pdf") => {a.size, a.modification_time.to_unix, "imported", 5_i64},
                             File.join(root, "b.pdf") => {b.size + 1, b.modification_time.to_unix, "imported", 6_i64}}
      scan = Backlog::Scanner.new(root, known).run
      scan.units.map { |u| File.basename(u.files.first.path) }.should eq ["b.pdf"]
      scan.already.should eq 1
    end
  end
end

describe Backlog::Index do
  it "finds duplicates by file, ISBN and title with an author" do
    tmpdir do |root|
      lib_file = File.join(root, "lib", "Book.pdf")
      write(lib_file, pdf("same"))
      write(File.join(root, "in", "copy.pdf"), pdf("same"))
      write(File.join(root, "in", "Ken Watanabe", "PS (1)", "metadata.opf"), OPF_XML)
      write(File.join(root, "in", "Ken Watanabe", "PS (1)", "ps.mobi"), mobi)
      write(File.join(root, "in", "Other", "T (2)", "metadata.opf"), opf("Problem solving 101 - a simple book for smart people", "Watanabe, Ken", nil))
      write(File.join(root, "in", "Other", "T (2)", "t.pdf"), pdf("t"))
      write(File.join(root, "in", "New", "N (3)", "metadata.opf"), opf("Ganz neu", "Neue Autorin", "9783446264137"))
      write(File.join(root, "in", "New", "N (3)", "n.epub"), epub("n"))
      write(File.join(root, "in", "New", "N (4)", "metadata.opf"), opf("Ganz neu", "Neue Autorin", "9783446264137"))
      write(File.join(root, "in", "New", "N (4)", "n.epub"), epub("n2"))
      books = [book(1, "Something else", ["X"], ["PDF"]), book(2, "Problem Solving 101: A Simple Book for Smart People", ["Ken Watanabe"], ["MOBI"], "9781101028483")]
      index = Backlog::Index.new(books, [{1_i64, "PDF", lib_file, File.size(lib_file)}])
      scan = Backlog::Scanner.new(File.join(root, "in")).run
      scan.units.each_with_index do |u, i|
        next unless Backlog.plan(u, index)
        # the list counts for what comes after it
        index.planned[-(i.to_i64 + 1)] = u.name
        u.meta.try { |m| index.add_meta(-(i.to_i64 + 1), m) }
        index.add_files(-(i.to_i64 + 1), u.files)
      end
      plan = scan.units.to_h { |u| {File.basename(u.files.first.path), {u.action, u.match, u.book_id, u.add_formats}} }
      plan["copy.pdf"].should eq({"duplicate", "file", 1_i64, [] of String})
      plan["ps.mobi"].should eq({"duplicate", "isbn", 2_i64, [] of String})
      # same title and author spelled differently: the PDF is a new format of #2
      plan["t.pdf"].should eq({"addFormats", "title", 2_i64, ["PDF"]})
      dup = scan.units.select { |u| u.files.first.path.includes?("N (") }
      dup.map(&.action).sort.should eq ["add", "duplicate"]
      dup.find(&.action.==("duplicate")).not_nil!.same_as.should_not be_nil
    end
  end

  it "matches title and author without an ISBN" do
    index = Backlog::Index.new([book(7, "Die Welt: Ein Buch", ["Müller, Anna"])])
    index.by_title("Die Welt - ein Buch", ["Anna Muller"]).should eq 7
    index.by_title("Die Welt - ein Buch", ["Someone Else"]).should be_nil
    index.by_title("Die Welt", ["Anna Müller"]).should be_nil
  end

  it "uses the duplicate page's rules: normalization, never another volume or number" do
    vol = book(8, "Die Chronik Band 1", ["Anna Müller"])
    numbered = CalibreHub::Book.new(id: 9_i64, title: "Saga", authors: ["Bo Berg"], author_sort: nil, tags: [] of String,
      series: "Saga", series_index: 1.0, formats: ["EPUB"], last_modified: Time.utc, timestamp: nil, pubdate: nil,
      rating: nil, publisher: nil, identifiers: {"isbn" => "9783446264137"}, languages: [] of String, comments: nil,
      custom: {} of String => JSON::Any)
    unknown = book(10, "Ohne Namen", ["Unknown"])
    junk = book(11, "Ein Titel (z-lib.org)", ["Cara Cole"])
    index = Backlog::Index.new([vol, numbered, unknown, junk])
    index.by_title("Die Chronik Band 1", ["Müller, Anna"]).should eq 8
    index.by_title("Die Chronik Band 2", ["Anna Müller"]).should be_nil
    # the same ISBN, but another number of the series
    other = Backlog::OpfMeta.parse(opf_series("Saga", "Bo Berg", "Saga", "2.0", "9783446264137"))
    index.match_item(CalibreHub::Dedup::Item.new(Backlog.book(0_i64, other))).should be_nil
    same = Backlog::OpfMeta.parse(opf_series("Saga", "Bo Berg", "Saga", "1.0", "9783446264137"))
    index.match_item(CalibreHub::Dedup::Item.new(Backlog.book(0_i64, same))).should eq({9_i64, "isbn"})
    # an unknown author is no author in common
    index.by_title("Ohne Namen", ["Unknown"]).should be_nil
    # download-site junk in a title is no difference
    index.by_title("Ein Titel", ["Cara Cole"]).should eq 11
  end
end

describe CalibreHub::ImportCleanup do
  it "reads the folders from the category and its tags" do
    f = ->(k : String, t : Array(String)) { CalibreHub::ImportCleanup.folders(k, t) }
    f.call("Defaults.Algebra & Trigonometry", ["Algebra & Trigonometry", "Defaults"]).should eq ["Defaults", "Algebra & Trigonometry"]
    f.call("J.R.R. Tolkien.Der Hobbit (12)", ["Der Hobbit (12)", "J.R.R. Tolkien"]).should eq ["J.R.R. Tolkien", "Der Hobbit (12)"]
    f.call("Roman.Krimi", ["Roman"]).should be_nil
    f.call("Ken Watanabe", ["Ken Watanabe", "auto-metadaten"]).should eq ["Ken Watanabe"]
  end
end

describe CalibreHub::ImportCleanup do
  it "clears folder categories and tags of inbox imports, and undoes it" do
    fake = FakeCalibre.new
    fake.add(120, "A", ["X"], tags: ["Algebra", "Defaults", "auto-metadaten"], kategorie: "Defaults.Algebra")
    fake.add(121, "B", ["Y"], tags: ["Roman"], kategorie: "Roman.Krimi")
    fake.add(50, "Old", ["Z"], tags: ["Defaults"], kategorie: "Defaults")
    db = state_db
    ev = ->(type : String, id : Int64, kat : String?, tags : Array(String), at : Int64) do
      db.exec "insert into events (type, book_id, payload, created_at) values (?, ?, ?, ?)", type, id,
        {type: type, bookId: id, book: {tags: tags, custom: {kategorie: kat}}}.to_json, at
    end
    ev.call("added", 50_i64, "Defaults", ["Defaults"], 1000_i64)
    # the detector saw the add before the inbox set category and tags
    ev.call("added", 120_i64, nil, ["embedded"], 2000_i64)
    ev.call("changed", 120_i64, "Defaults.Algebra", ["Algebra", "Defaults"], 2001_i64)
    # category from the user later, not from folders
    ev.call("added", 121_i64, nil, [] of String, 2002_i64)
    ev.call("changed", 121_i64, "Roman.Krimi", ["Roman"], 2003_i64)
    calibre = fake.calibre
    writer = CalibreHub::Writer.new(calibre, nil, nil, "kategorie")
    tmpdir do |backup|
      c = CalibreHub::ImportCleanup.new(db, calibre, writer, "kategorie", backup)
      expect_raises(CalibreHub::Edit::Invalid) { c.plan({} of String => JSON::Any) }
      dry = c.submit_cleanup({"minId" => JSON::Any.new(100_i64)}, true)
      dry["total"].should eq 1
      e = dry["entries"][0]
      e["bookId"].should eq 120
      e["removeTags"].should eq ["Algebra", "Defaults"]
      e["clearKategorie"].should eq true
      by_time = c.submit_cleanup({"since" => JSON::Any.new(Time.unix(1500).to_rfc3339)}, true)
      by_time["total"].should eq 1

      applied = c.submit_cleanup({"minId" => JSON::Any.new(100_i64)}, false)
      wait_job(c, applied["job"]["id"].as_s).status.should eq "done"
      fake.books[120_i64]["tags"].should eq ["auto-metadaten"]
      fake.books[120_i64]["#kategorie"].raw.should be_nil
      fake.books[121_i64]["#kategorie"].should eq "Roman.Krimi"
      Dir.children(backup).size.should eq 1
      # idempotent: nothing left to do
      c.submit_cleanup({"minId" => JSON::Any.new(100_i64)}, true)["total"].should eq 0

      undo = c.undo(applied["id"].as_s, false)
      wait_job(c, undo["undoJob"]["id"].as_s).status.should eq "done"
      fake.books[120_i64]["tags"].as_a.map(&.as_s).sort.should eq ["Algebra", "Defaults", "auto-metadaten"]
      fake.books[120_i64]["#kategorie"].should eq "Defaults.Algebra"
    end
  end
end

describe CalibreHub::ImportRepair do
  it "plans, applies only on books untouched since the import, logs and reverts (#8408)" do
    tmpdir do |root|
      dir = File.join(root, "Algebra")
      carr = File.join(dir, "Carr - Formulas and Theorems in Pure Mathematics 2e (Chelsea, 1970).djvu")
      duffy = File.join(dir, "Duffy - Advanced Engineering Mathematics (1998).pdf")
      sowell = File.join(dir, "Sowell - Applied Economics.pdf")
      jung = File.join(dir, "Jungnickel - Graphs, Networks and Algorithms 3e (Springer, 2008).pdf")
      edited = File.join(dir, "Brass - Advanced Data Structures (Cambridge, 2008).pdf")
      wine = File.join(dir, "Wine Tasting - A Professional Handbook.pdf")
      dune = File.join(dir, "Herbert - Dune.pdf")
      opf_book = File.join(root, "Old", "Book (3)", "book.pdf")
      [carr, duffy, sowell, jung, edited, wine, dune, opf_book].each { |p| write(p, pdf(p)) }
      write(File.join(File.dirname(opf_book), "metadata.opf"), OPF_XML)
      fake = FakeCalibre.new
      # as calibre's add-book left them
      fake.add(201, "Carr", ["Formulas", "Theorems in Pure Mathematics 2e (Chelsea, 1970)"], ["DJVU"])
      # title edited by hand since, the authors still calibre's
      fake.add(202, "Advanced Engineering Mathematics", ["Advanced Engineering Mathematics (1998)"], ["PDF"])
      # the PDF's own title says nothing (the added event), the authors from the name
      fake.add(203, "100767", ["Applied Economics"], ["PDF"])
      # the metadata rules turned calibre's "Graphs, Networks" round since
      fake.add(204, "Jungnickel", ["Networks Graphs", "Algorithms 3e (Springer, 2008)"], ["PDF"])
      # someone set the authors by hand
      fake.add(205, "Brass", ["Peter Brass"], ["PDF"])
      fake.add(206, "Brass", ["Peter Brass"], ["PDF"])
      # no person on one side: unclear, nobody decides, the subtitle goes
      fake.add(207, "Wine Tasting", ["A Professional Handbook"], ["PDF"])
      # a tie of two names: the decider (the sources) says Herbert
      fake.add(208, "Herbert", ["Dune"], ["PDF"])
      db = state_db
      db.exec "create table if not exists meta (key text primary key, value text)"
      CalibreHub::Importer.migrate(db)
      {carr => 201, duffy => 202, sowell => 203, jung => 204, edited => 205, opf_book => 206, wine => 207, dune => 208}.each do |path, id|
        db.exec "insert into import_files (path, size, mtime, status, book_id, run_id, at) values (?, 1, 1, 'imported', ?, 'r', 100)", path, id.to_i64
      end
      db.exec "insert into events (type, book_id, payload, created_at) values ('added', 203, ?, 100)",
        {type: "added", bookId: 203, book: {title: "100767", authors: ["Applied Economics"]}}.to_json
      calibre = fake.calibre
      writer = CalibreHub::Writer.new(calibre, nil, nil, "kategorie")
      log = CalibreHub::MetaLog.new(db)
      log.add(204, "authors", JSON.parse(%(["Graphs, Networks", "Algorithms 3e (Springer, 2008)"])),
        JSON.parse(%(["Networks Graphs", "Algorithms 3e (Springer, 2008)"])), "rules", "meta1")
      metadata = CalibreHub::Metadata.new(calibre, writer, log, [] of String, nil, nil, CalibreHub::Meta::Http.new(Time::Span.zero))
      repair = CalibreHub::ImportRepair.new(db, calibre, writer, log)
      asked = [] of String
      repair.decider = ->(_b : CalibreHub::Book, name : String, readings : Array(CalibreHub::Meta::Guess)) do
        asked << name
        readings.find { |r| r.authors == ["Herbert"] }.try { |r| {r, "hardcover"} }
      end

      plan(repair, {201 => carr, 202 => duffy, 203 => sowell, 204 => jung, 205 => edited, 207 => wine, 208 => dune} of Int32 => String?)
      entries = open_proposals(repair)
      fields = ->(id : Int32) { entries[id.to_i64].changes.map(&.field) }
      entries[201_i64].changes.map { |c| {c.field, c.new} }.should eq [
        {"title", JSON::Any.new("Formulas and Theorems in Pure Mathematics")}, {"authors", JSON.parse(%(["Carr"]))},
        {"authorSort", JSON::Any.new("Carr")}, {"publisher", JSON::Any.new("Chelsea")}, {"pubdate", JSON::Any.new("1970")},
      ]
      entries[201_i64].decided.should eq "name"
      fields.call(202).should eq ["authors", "authorSort", "pubdate"]
      fields.call(203).should eq ["title", "authors", "authorSort"]
      entries[204_i64].changes.find! { |c| c.field == "authors" }.new.should eq JSON.parse(%(["Jungnickel"]))
      # authors by hand: they stay, calibre's title goes
      fields.call(205).should eq ["title", "publisher", "pubdate"]
      # unclear and undecided: below the threshold nothing but the tag, the
      # reading is a suggestion for the review
      fields.call(207).should eq ["tags", "candidate"]
      entries[207_i64].decided.should eq "unsure"
      entries[207_i64].confidence.should eq 30
      entries[207_i64].changes.first.new.should eq JSON.parse(%(["auto-unsicher"]))
      # a surname and a title: reviewed; the sources between two names
      entries[201_i64].confidence.should eq 70
      entries[201_i64].level.should eq 3
      entries[208_i64].confidence.should eq 70
      entries[208_i64].decided.should eq "hardcover"
      fields.call(208).should eq ["title", "authors", "authorSort"]
      asked.map { |n| File.basename(n) }.sort.should eq ["Herbert - Dune.pdf", "Wine Tasting - A Professional Handbook.pdf"]
      entries.size.should eq 7
      fake.books[201_i64]["title"].should eq "Carr"

      # one book first, one rejected, one changed by hand since the plan
      accepted = repair.accept([201_i64])
      wait_job(repair, accepted["job"]["id"].as_s).status.should eq "done"
      fake.books[201_i64]["title"].should eq "Formulas and Theorems in Pure Mathematics"
      fake.books[201_i64]["authors"].should eq ["Carr"]
      fake.books[201_i64]["publisher"].should eq "Chelsea"
      fake.books[202_i64]["authors"].should eq ["Advanced Engineering Mathematics (1998)"]
      repair.reject([205_i64]).should eq 1
      fake.books[203_i64]["authors"] = JSON.parse(%(["Thomas Sowell"]))
      all = repair.accept([202_i64, 203_i64, 204_i64, 208_i64])
      job = wait_job(repair, all["job"]["id"].as_s)
      job.errors.map(&.[:bookId]).should eq [203_i64]
      fake.books[207_i64]["tags"].as_a.should be_empty
      one = repair.accept([207_i64])
      wait_job(repair, one["job"]["id"].as_s).errors.should be_empty
      fake.books[202_i64]["authors"].should eq ["Duffy"]
      fake.books[203_i64]["title"].should eq "100767"
      fake.books[204_i64]["authors"].should eq ["Jungnickel"]
      fake.books[205_i64]["title"].should eq "Brass"
      fake.books[207_i64]["tags"].should eq ["auto-unsicher", "auto-metadaten"]
      fake.books[207_i64]["title"].should eq "Wine Tasting"
      fake.books[208_i64]["authors"].should eq ["Herbert"]
      fake.books[208_i64]["title"].should eq "Dune"
      fake.books[201_i64]["tags"].should eq ["auto-metadaten"]
      counts = {} of String => Int64
      db.query_each("select status, count(*) from import_repairs group by status") { |rs| counts[rs.read(String)] = rs.read(Int64) }
      counts.should eq({"applied" => 5_i64, "rejected" => 1_i64, "failed" => 1_i64})
      changes = log.list(201_i64)
      changes.map(&.source).uniq.should eq ["rules"]
      changes.map(&.job_id).uniq.should eq [accepted["job"]["id"].as_s]
      # the failed one again, without the authors set by hand since
      plan(repair, {203 => sowell} of Int32 => String?)
      repair.proposals("pending").map { |p| {p.book_id, p.changes.map(&.field)} }.should eq [{203_i64, ["title"]}]

      # revertible like any metadata change
      title = changes.find! { |e| e.field == "title" }
      metadata.revert(title.id)
      fake.books[201_i64]["title"].should eq "Carr"
      tag = log.list(207_i64).find! { |e| e.field == "tags" }
      metadata.revert(tag.id)
      fake.books[207_i64]["tags"].as_a.should be_empty
    end
  end

  it "plans suspicious books without an import file, keeps edits, never applies a suggestion (#8528)" do
    tmpdir do |root|
      path = File.join(root, "09 - The Pragmatic Programmer - From Journeyman to Master.pdf")
      write(path, pdf)
      fake = FakeCalibre.new
      fake.add(401, "09 - The Pragmatic Programmer", ["From Journeyman to Master"], ["PDF"])
      # uploaded, not imported
      fake.add(402, "100M Money Models", ["How To Make Money"], ["EPUB"])
      fake.add(403, "57390", ["Unknown"], ["PDF"])
      # a person set the title since it was added
      fake.add(404, "Mein Titel", ["How To Make Money"], ["EPUB"])
      # fine as it is
      fake.add(405, "The Art of UNIX Programming", ["Eric S. Raymond"], ["PDF"])
      db = state_db
      db.exec "create table if not exists meta (key text primary key, value text)"
      CalibreHub::Importer.migrate(db)
      db.exec "insert into import_files (path, size, mtime, status, book_id, run_id, at) values (?, 1, 1, 'imported', 401, 'r1', 100)", path
      db.exec "insert into events (type, book_id, payload, created_at) values ('added', 404, ?, 100)",
        {type: "added", bookId: 404, book: {title: "8508 Fm Frame", authors: ["How To Make Money"]}}.to_json
      calibre = fake.calibre
      writer = CalibreHub::Writer.new(calibre, nil, nil, "kategorie")
      log = CalibreHub::MetaLog.new(db)
      repair = CalibreHub::ImportRepair.new(db, calibre, writer, log)
      repair.checker = ->(b : CalibreHub::Book, g : CalibreHub::Meta::Guess) do
        raise "a catalog fails" if b.id == 403
        CalibreHub::Meta::Verdict.new(false, g.title, ["Alex Hormozi"], "openlibrary", ["openlibrary"]).as(CalibreHub::Meta::Verdict?)
      end

      plan(repair, {401 => path, 402 => nil, 404 => nil} of Int32 => String?)
      # a source that fails stops one book
      expect_raises(Exception, "a catalog fails") { repair.recheck(403_i64, nil) }
      entries = open_proposals(repair)
      entries.keys.sort.should eq [401_i64, 402_i64, 404_i64]
      entries[402_i64].file.should eq ""
      entries[402_i64].decided.should eq "unsure"
      entries[402_i64].changes.map(&.field).should eq ["candidate", "tags"]
      entries[402_i64].confidence.should eq 50
      # the person's title stays
      entries[404_i64].changes.none? { |c| c.field == "title" }.should be_true

      all = repair.accept(entries.keys)
      wait_job(repair, all["job"]["id"].as_s).errors.should be_empty
      fake.books[402_i64]["authors"].should eq ["How To Make Money"]
      fake.books[402_i64]["tags"].as_a.map(&.as_s).should contain "auto-unsicher"
    end
  end

  it "plans the books of the first portion: what the import wrote is automatic, a hand's stays (#8528)" do
    tmpdir do |root|
      vol = File.join(root, "Vol 17 - Cumulative Index.pdf")
      mcevoy = File.join(root, "McEvoy - Molecular Basis of Medical Cell Biology (Lange, 1998).djvu")
      yosida = File.join(root, "Functional Analysis 6th ed - K. Yoshida (Springer, 1980) WW.pdf")
      print = File.join(root, "Ta-Tsien - Problems and Solutions In Mathematics (World Scientific, 1999).pdf")
      edited = File.join(root, "Vol 09 - Birds 2.pdf")
      [vol, mcevoy, yosida, print, edited].each { |p| write(p, pdf) }
      fake = FakeCalibre.new
      fake.add(601, "Grzimek's animal life encyclopedia.: Vol 17", ["Cumulative Index"], ["PDF"])
      fake.add(602, "McEvoy", ["Molecular Basis of Medical Cell Biology (Lange, 1998)"], ["DJVU"])
      fake.add(603, %q(C:\Program Files\eMule\Incoming\Yoshida K. -  Functional analysis (Springer, 1980)(256s).djvu), ["R. Tunç Mısırlıoğlu", "Kosaku Yosida"], ["PDF"], "9783540102106")
      fake.add(604, "Print PROBLEMS AND SOLUTIONS IN MATHEMATICS (547 pages)", ["Ta-Tsien"], ["PDF"], "9789810234799")
      fake.add(605, "Mein Titel", ["Meine Autorin"], ["PDF"])
      db = state_db
      db.exec "create table if not exists meta (key text primary key, value text)"
      CalibreHub::Importer.migrate(db)
      {vol => 601, mcevoy => 602, yosida => 603, print => 604, edited => 605}.each do |p, id|
        db.exec "insert into import_files (path, size, mtime, status, book_id, run_id, at) values (?, 1, 1, 'imported', ?, 'r1', 100)", p, id
      end
      # calibre's reading was added, the import's set-fields followed at once
      db.exec "insert into events (type, book_id, payload, created_at) values ('added', 601, ?, 100)",
        {type: "added", bookId: 601, book: {title: "Vol 17", authors: ["Cumulative Index"]}}.to_json
      db.exec "insert into events (type, book_id, payload, created_at) values ('changed', 601, ?, 101)",
        {type: "changed", bookId: 601, changes: {title: ["Vol 17", "Grzimek's animal life encyclopedia.: Vol 17"]}}.to_json
      {602, 603, 604}.each do |id|
        title = fake.books[id.to_i64]["title"].as_s
        authors = fake.books[id.to_i64]["authors"]
        db.exec "insert into events (type, book_id, payload, created_at) values ('added', ?, ?, 100)", id,
          {type: "added", bookId: id, book: {title: title, authors: authors}}.to_json
      end
      # a day later somebody named it
      db.exec "insert into events (type, book_id, payload, created_at) values ('added', 605, ?, 100)",
        {type: "added", bookId: 605, book: {title: "Vol 09", authors: ["Birds 2"]}}.to_json
      db.exec "insert into events (type, book_id, payload, created_at) values ('changed', 605, ?, 100000)",
        {type: "changed", bookId: 605, changes: {title: ["Vol 09", "Mein Titel"], authors: [["Birds 2"], ["Meine Autorin"]]}}.to_json
      calibre = fake.calibre
      repair = CalibreHub::ImportRepair.new(db, calibre, CalibreHub::Writer.new(calibre, nil, nil, "kategorie"), CalibreHub::MetaLog.new(db))

      plan(repair, {601 => vol, 602 => mcevoy, 603 => yosida, 604 => print, 605 => edited} of Int32 => String?)
      entries = open_proposals(repair)
      fields = ->(id : Int64) { entries[id].changes.to_h { |c| {c.field, c.new} } }
      entries.keys.sort.should eq [601_i64, 602_i64, 603_i64, 604_i64]
      fields.call(601_i64)["tags"].as_a.map(&.as_s).should contain "auto-unsicher"
      fields.call(602_i64)["title"].should eq "Molecular Basis of Medical Cell Biology"
      fields.call(602_i64)["authors"].should eq JSON.parse(%(["McEvoy"]))
      fields.call(603_i64)["title"].should eq "Functional Analysis"
      fields.call(604_i64)["title"].should eq "Problems and Solutions In Mathematics"
    end
  end

  it "plans the library's books and keeps what was accepted (#8528)" do
    tmpdir do |root|
      fake = FakeCalibre.new
      fake.add(501, "Hacker's Delight", ["Unknown"], ["PDF"])
      fake.add(502, "The Art of UNIX Programming", ["Eric S. Raymond"], ["PDF"])
      fake.add(503, "Zwischen Ich und Du", ["Angelika Krebs"], ["EPUB"], "9783518730898")
      fake.add(505, "Copy of Hacker's Delight", ["Henry S. Warren"], ["PDF"], "9780201914658")
      db = state_db
      db.exec "create table if not exists meta (key text primary key, value text)"
      CalibreHub::Importer.migrate(db)
      calibre = fake.calibre
      writer = CalibreHub::Writer.new(calibre, nil, nil, "kategorie")
      log = CalibreHub::MetaLog.new(db)
      repair = CalibreHub::ImportRepair.new(db, calibre, writer, log)
      warren = CalibreHub::Meta::Record.new(title: "Hacker's Delight", authors: ["Henry S. Warren"], isbn: "9780201914658")
      repair.reader = ->(b : CalibreHub::Book, _path : String?) do
        text = b.id.in?(501, 505) ? "Hacker's Delight\nHenry S. Warren\nCopyright 2003\nISBN 0-201-91465-4\n" : ""
        CalibreHub::Meta::FileMeta::Info.new(CalibreHub::Meta::Record.new, [] of String, nil, text, "", "PDF").as(CalibreHub::Meta::FileMeta::Info?)
      end
      repair.by_isbn = ->(isbn : String) do
        isbn == "9780201914658" ? [CalibreHub::Meta::Candidate.new("hardcover", warren, by_isbn: isbn)] : [] of CalibreHub::Meta::Candidate
      end
      repair.owners = ->(isbn : String) { isbn == "9780201914658" ? [505_i64] : [] of Int64 }

      plan(repair, {501 => nil, 502 => nil, 503 => nil, 505 => nil} of Int32 => String?)
      entries = open_proposals(repair)
      # the same ISBN as another book: reviewed, not written
      entries[501_i64].level.should eq 1
      entries[501_i64].confidence.should eq 89
      entries[501_i64].notes[0].kind.should eq "duplicateIsbn"
      entries[501_i64].changes.map(&.field).should eq ["authors", "authorSort"]
      # nothing to change is no proposal
      entries.has_key?(502_i64).should be_false

      one = repair.accept([501_i64])
      wait_job(repair, one["job"]["id"].as_s).errors.should be_empty
      changes = log.list(501_i64)
      changes.map(&.source).uniq.should eq ["hardcover"]
      changes.map(&.level).uniq.should eq [1]
      log.from_source("hardcover", 1).size.should eq changes.size

      # again: neither touched nor proposed anew
      plan(repair, {501 => nil} of Int32 => String?)
      open_proposals(repair).has_key?(501_i64).should be_false
    end
  end

  it "plans no book that went to the trash after its import (#1182)" do
    tmpdir do |root|
      path = File.join(root, "Duffy - Advanced Engineering Mathematics (1998).pdf")
      write(path, pdf)
      fake = FakeCalibre.new
      db = state_db
      db.exec "create table if not exists meta (key text primary key, value text)"
      CalibreHub::Importer.migrate(db)
      db.exec "insert into import_files (path, size, mtime, status, book_id, run_id, at) values (?, 1, 1, 'imported', 1182, 'r', 100)", path
      calibre = fake.calibre
      repair = CalibreHub::ImportRepair.new(db, calibre, CalibreHub::Writer.new(calibre, nil, nil, "kategorie"), CalibreHub::MetaLog.new(db))
      repair.recheck_list("r")[0].should be_empty
    end
  end

  it "reads the proposals of an older plan" do
    p = CalibreHub::ImportRepair::Proposed.from_json(%({"field": "title", "old": "a", "new": "b"}))
    p.source.should eq "rules"
  end

  it "tells edits by hand from what the import and the cleanup wrote (#8528)" do
    entry = ->(field : String, new : String, reverted : Bool) do
      CalibreHub::MetaLog::Entry.new(1_i64, 1_i64, field, JSON::Any.new("old"), JSON::Any.new(new), "rules", nil, Time.utc, reverted ? Time.utc : nil)
    end
    changed = ->(field : String, new : String) { JSON.parse({changes: {field => ["old", new]}}.to_json) }
    hand = ->(at : Int64, log : Array(CalibreHub::MetaLog::Entry)) do
      CalibreHub::ImportRepair.hand_fields(100_i64, [{at, changed.call("title", "New")}], log)
    end
    # the import's own set-fields right after adding
    hand.call(110_i64, [] of CalibreHub::MetaLog::Entry).should be_empty
    hand.call(100_000_i64, [] of CalibreHub::MetaLog::Entry).should eq Set{"title"}
    # the cleanup's
    hand.call(100_000_i64, [entry.call("title", "New", false)]).should be_empty
    # other fields are nobody's concern
    CalibreHub::ImportRepair.hand_fields(100_i64, [{100_000_i64, changed.call("rating", "5")}], [] of CalibreHub::MetaLog::Entry).should be_empty
    isbn = JSON.parse({changes: {identifiers: [{isbn: "1"}, {isbn: "2"}]}}.to_json)
    CalibreHub::ImportRepair.hand_fields(nil, [{100_000_i64, isbn}], [] of CalibreHub::MetaLog::Entry).should eq Set{"isbn"}
  end

  it "queues a metadata run for the repaired books" do
    tmpdir do |root|
      path = File.join(root, "Duffy - Advanced Engineering Mathematics (1998).pdf")
      write(path, pdf)
      fake = FakeCalibre.new
      fake.add(301, "Duffy", ["Advanced Engineering Mathematics (1998)"], ["PDF"])
      db = state_db
      db.exec "create table if not exists meta (key text primary key, value text)"
      CalibreHub::Importer.migrate(db)
      db.exec "insert into import_files (path, size, mtime, status, book_id, run_id, at) values (?, 1, 1, 'imported', 301, 'r', 100)", path
      calibre = fake.calibre
      writer = CalibreHub::Writer.new(calibre, nil, nil, "kategorie")
      log = CalibreHub::MetaLog.new(db)
      metadata = CalibreHub::Metadata.new(calibre, writer, log, [] of String, nil, nil, CalibreHub::Meta::Http.new(Time::Span.zero))
      metadata_jobs = CalibreHub::MetadataJobs.new(db, calibre, writer, metadata)
      repair = CalibreHub::ImportRepair.new(db, calibre, writer, log)
      repair.metadata = metadata_jobs
      plan(repair, {301 => path} of Int32 => String?)
      fake.books[301_i64]["authors"].should eq ["Advanced Engineering Mathematics (1998)"]
      repair.proposals("pending").map(&.book_id).should eq [301_i64]
      accepted = repair.accept([301_i64])
      wait_job(repair, accepted["job"]["id"].as_s).status.should eq "done"
      fake.books[301_i64]["authors"].should eq ["Duffy"]
      run, _ = metadata_jobs.last.not_nil!
      run.ids.should eq [301_i64]
      metadata_jobs.target(run).should eq "ids"
      wait_job(metadata_jobs, run.id).status.should eq "done"
    end
  end
end
