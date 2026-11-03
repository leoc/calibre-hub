require "spec"
require "file_utils"
require "../src/calibre_hub/backlog_jobs"

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
        meta = @file_meta[name]? || {File.basename(name, File.extname(name)), "Unknown", nil}
        if (dup = @duplicate_titles[meta[0]]?) && path.split('/')[4] == "n"
          b = @books[dup]
          ctx.response.print({duplicates: [{title: b["title"], authors: b["authors"]}]}.to_json)
        else
          id = (@next += 1)
          ext = File.extname(name).lchop('.').upcase
          @books[id] = {"title" => JSON::Any.new(meta[0]), "authors" => JSON.parse([meta[1]].to_json),
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

# a run once its scan is done
private def wait_run(jobs : CalibreHub::ImportJobs, id : String) : JSON::Any
  200.times do
    r = jobs.run(id).not_nil!
    return r unless r["status"] == "scanning"
    sleep 20.milliseconds
  end
  raise "run #{id} still scanning"
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

      summary = Backlog.summary(scan.units, scan.skipped, scan.already, root)
      summary["books"].should eq 4
      summary["calibreFolders"].should eq 1
      summary["skipped"]["byType"]["mp3"].should eq 2
      summary["skipped"]["byFolder"].as_a.map(&.["folder"].as_s).should contain("Music")
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
      summary = Backlog.summary(scan.units, scan.skipped, scan.already, [File.join(root, "a"), File.join(root, "b")])
      summary["skipped"]["byFolder"].as_a.map(&.["folder"].as_s).sort.should eq ["a", "b/_imported"]
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
      Backlog.plan_all(scan.units, index)
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

  it "takes the next books of a scan up to a limit, duplicates on the way go along" do
    units = %w(add duplicate add addFormats duplicate add).map do |a|
      Backlog::Unit.new("file", "/x", [Backlog::BookFile.new("/x/#{a}", "PDF", 3000_i64, 0_i64)]).tap(&.action=(a))
    end
    Backlog.take(units, nil).should eq [0, 1, 2, 3, 4, 5]
    Backlog.take(units, 2).should eq [0, 1, 2]
    Backlog.take(units, 3).should eq [0, 1, 2, 3]
    Backlog.take(units, 10).size.should eq 6
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

describe CalibreHub::ImportJobs do
  it "plans a dry run and imports, without folder categories or tags" do
    tmpdir do |root|
      cal = File.join(root, "Ken Watanabe", "Problem Solving 101 (257)")
      write(File.join(cal, "metadata.opf"), OPF_XML)
      write(File.join(cal, "cover.jpg"), Bytes[0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 0x4A, 0x46, 0x49, 0x46, 0, 1])
      write(File.join(cal, "ps.mobi"), mobi)
      write(File.join(cal, "ps.epub"), epub)
      write(File.join(root, "Some Author", "book.pdf"), pdf)
      write(File.join(root, "Some Author", "known.pdf"), pdf("k"))
      write(File.join(root, "Some Author", "isbn.pdf"), pdf("i"))
      write(File.join(root, "song.mp3"), "ID3")
      fake = FakeCalibre.new
      fake.add(1, "Bekannt", ["Alte Autorin"], ["EPUB"])
      fake.add(2, "Mit ISBN", ["Wer"], ["EPUB"], "9783446264137")
      fake.duplicate_titles["known"] = 1_i64
      fake.file_meta["isbn.pdf"] = {"Anders betitelt", "Wer anders", "978-3-446-26413-7"}
      calibre = fake.calibre
      db = state_db
      writer = CalibreHub::Writer.new(calibre, nil, nil, "kategorie")
      jobs = CalibreHub::ImportJobs.new(db, calibre, writer, [root], nil, retries: 0)

      expect_raises(CalibreHub::Edit::Invalid, /not below an import root/) { jobs.start("/tmp", true) }
      started = jobs.start(".", true)
      # the scan is the job's, the run comes back right away
      started["status"].should eq "scanning"
      started["summary"].raw.should be_nil
      dry = wait_run(jobs, started["id"].as_s)
      dry["status"].should eq "planned"
      dry["scan"]["files"].should eq 8
      dry["scan"]["planned"].should eq 4
      # a dry run doesn't pause the hooks
      CalibreHub::Backlog.paused?(db).should be_false
      dry["summary"]["books"].should eq 4
      dry["summary"]["toAdd"].should eq 4
      dry["summary"]["skipped"]["byType"]["mp3"].should eq 1
      fake.requests.none? { |r| r[0] == "add-book" }.should be_true

      run = jobs.start(root, false)
      run["status"].should eq "scanning"
      CalibreHub::Backlog.paused?(db).should be_true
      job = wait_job(jobs, run["jobId"].as_s)
      job.status.should eq "done"
      job.errors.should be_empty
      CalibreHub::Backlog.paused?(db).should be_false
      done = jobs.run(run["id"].as_s).not_nil!
      done["results"].as_h.transform_values(&.as_i).should eq({"imported" => 2, "formatAdded" => 2})

      ps = fake.books.values.find { |b| b["title"] == "Problem Solving 101: A Simple Book for Smart People" }.not_nil!
      ps["authors"].should eq ["Ken Watanabe"]
      ps["tags"].should eq ["Business", "Thinking"]
      ps["formats"].as_a.map(&.as_s).sort.should eq ["EPUB", "MOBI"]
      ps["cover"].as_s.should start_with "data:image/jpeg;base64,"
      ps.has_key?("#kategorie").should be_false
      plain = fake.books.values.find { |b| b["title"] == "book" }.not_nil!
      plain["tags"].as_a.should be_empty
      # calibre's title/author check: no new book, only the missing format
      fake.books[1_i64]["formats"].as_a.map(&.as_s).sort.should eq ["EPUB", "PDF"]
      # the ISBN calibre read from the file is #2's: removed again, the PDF goes to #2
      fake.books.values.count { |b| b["title"] == "Anders betitelt" }.should eq 0
      fake.books[2_i64]["formats"].as_a.map(&.as_s).sort.should eq ["EPUB", "PDF"]
      report = jobs.report(run["id"].as_s).not_nil!
      report["skipped"].as_a.map(&.["reason"].as_s).should eq ["not a book format"]

      # another run: everything handled already
      again = wait_run(jobs, jobs.start(root, true)["id"].as_s)
      again["summary"]["books"].should eq 0
      again["summary"]["alreadyImported"].should eq 5
    end
  end
end

describe CalibreHub::ImportJobs do
  it "imports several folders in portions of a limit" do
    tmpdir do |root|
      write(File.join(root, "A", "a1.pdf"), pdf("a1"))
      write(File.join(root, "A", "a2.pdf"), pdf("a2"))
      write(File.join(root, "A", "dup.pdf"), pdf("dup"))
      write(File.join(root, "B", "b1.pdf"), pdf("b1"))
      write(File.join(root, "B", "b2.pdf"), pdf("b2"))
      write(File.join(root, "C", "c1.pdf"), pdf("c1"))
      fake = FakeCalibre.new
      fake.add(1, "Bekannt", ["Alte Autorin"], ["EPUB"])
      fake.duplicate_titles["dup"] = 1_i64
      calibre = fake.calibre
      db = state_db
      writer = CalibreHub::Writer.new(calibre, nil, nil, "kategorie")
      jobs = CalibreHub::ImportJobs.new(db, calibre, writer, [root], nil, retries: 0)

      expect_raises(CalibreHub::Edit::Invalid) { jobs.start(["A"], true, 0) }
      dry = wait_run(jobs, jobs.start(["A", "B", File.join(root, "A")], true, 2)["id"].as_s)
      dry["paths"].should eq [File.realpath(File.join(root, "A")), File.realpath(File.join(root, "B"))]
      dry["limit"].should eq 2
      dry["summary"]["books"].should eq 5
      dry["summary"]["selected"]["books"].should eq 2
      dry["summary"]["deferred"].should eq 3
      dry["results"].as_h.transform_values(&.as_i).should eq({"pending" => 2, "deferred" => 3})

      run = jobs.start(["A", "B"], false, 2)
      expect_raises(CalibreHub::ImportJobs::Busy) { jobs.start(["C"], false) }
      job = wait_job(jobs, run["jobId"].as_s)
      job.status.should eq "done"
      job.total.should eq 2
      jobs.run(run["id"].as_s).not_nil!["results"].as_h.transform_values(&.as_i).should eq({"imported" => 2, "deferred" => 3})
      fake.books.values.map(&.["title"].as_s).sort.should eq ["Bekannt", "a1", "a2"]

      # the next portion: calibre's check makes dup.pdf a format of #1
      run = jobs.start(["A", "B"], false, 2)
      wait_job(jobs, run["jobId"].as_s).status.should eq "done"
      jobs.run(run["id"].as_s).not_nil!["results"].as_h.transform_values(&.as_i).should eq({"imported" => 1, "formatAdded" => 1, "deferred" => 1})
      run = jobs.start(["A", "B"], false, 2)
      wait_job(jobs, run["jobId"].as_s).status.should eq "done"
      jobs.run(run["id"].as_s).not_nil!["results"].as_h.transform_values(&.as_i).should eq({"imported" => 1})
      fake.books.values.map(&.["title"].as_s).sort.should eq ["Bekannt", "a1", "a2", "b1", "b2"]
      wait_run(jobs, jobs.start(["A", "B"], true)["id"].as_s)["summary"]["books"].should eq 0
    end
  end

  it "reports phase, times, failures and the whole backlog's progress" do
    tmpdir do |root|
      write(File.join(root, "A", "a1.pdf"), pdf("a1"))
      write(File.join(root, "A", "a2.pdf"), pdf("a2"))
      write(File.join(root, "B", "b1.pdf"), pdf("b1"))
      write(File.join(root, "B", "b2.pdf"), pdf("b2"))
      fake = FakeCalibre.new
      calibre = fake.calibre
      db = state_db
      jobs = CalibreHub::ImportJobs.new(db, calibre, CalibreHub::Writer.new(calibre, nil, nil, "kategorie"), [root], nil, retries: 0)
      empty = jobs.backlog
      empty["total"].should eq 0
      empty["basis"].raw.should be_nil

      dry = wait_run(jobs, jobs.start(".", true)["id"].as_s)
      dry["phase"].should eq "planned"
      dry["startedAt"].as_s.should_not be_empty
      dry["finishedAt"].should eq dry["scannedAt"]
      dry["scan"]["phase"].should eq "check"
      dry["current"].raw.should be_nil
      jobs.backlog["open"]["books"].should eq 4
      jobs.backlog["basis"]["runId"].should eq dry["id"]

      run = jobs.start(".", false, 2)
      wait_job(jobs, run["jobId"].as_s).status.should eq "done"
      done = jobs.run(run["id"].as_s).not_nil!
      done["phase"].should eq "done"
      done["elapsedSeconds"].as_i.should be >= 0
      done["finishedAt"].as_s.should_not be_empty
      done["failures"].as_a.should be_empty
      done["etaSeconds"].raw.should be_nil
      b = jobs.backlog(30.0)
      {b["imported"], b["total"], b["open"]["books"], b["open"]["failed"]}.should eq({2, 4, 2, 0})
      b["basis"]["runId"].should eq run["id"]
      # 2 books left at 30 a minute
      b["etaSeconds"].should eq 4

      # a book calibre-server fails on stays open
      fake.no_such_book << 1_i64
      write(File.join(root, "C", "Bekannt (1)", "metadata.opf"), opf("Bekannt", "Alte Autorin"))
      write(File.join(root, "C", "Bekannt (1)", "b.pdf"), pdf("bk"))
      fake.add(1, "Bekannt", ["Alte Autorin"], ["EPUB"])
      run = jobs.start(".", false)
      wait_job(jobs, run["jobId"].as_s)
      failed = jobs.run(run["id"].as_s).not_nil!
      failed["failures"].as_a.size.should eq 1
      failed["failures"][0]["path"].as_s.should end_with "Bekannt (1)"
      failed["failures"][0]["detail"].as_s.should contain "HTTP 500"
      b = jobs.backlog
      {b["imported"], b["total"], b["open"]["books"], b["open"]["formats"], b["open"]["failed"]}.should eq({4, 4, 0, 1, 1})
    end
  end

  it "counts the hooks' followup of imported books" do
    db = state_db
    db.exec "create table meta (key text primary key, value text)"
    calibre = FakeCalibre.new.calibre
    jobs = CalibreHub::ImportJobs.new(db, calibre, CalibreHub::Writer.new(calibre, nil, nil, "kategorie"), ["/tmp"], nil, retries: 0)
    jobs.followup = [
      CalibreHub::ImportJobs::FollowupHook.new("metadata", "metadata_event_seq", "added", jobs: "metadata_jobs"),
      CalibreHub::ImportJobs::FollowupHook.new("embed", "embed_event_seq", "changed", queue: "embed_queue"),
      # not set up: nothing
      CalibreHub::ImportJobs::FollowupHook.new("convert", "convert_event_seq", "added", jobs: "convert_jobs"),
    ]
    3.times { |i| db.exec "insert into events (type, book_id, payload, created_at) values (?, ?, '{}', 0)", i == 2 ? "changed" : "added", i + 10 }
    db.exec "insert into meta (key, value) values ('metadata_event_seq', '0'), ('embed_event_seq', '0')"
    db.exec "create table metadata_jobs (id text, status text, ids text, done integer)"
    # one book done, one to go, then the author pass (0)
    db.exec "insert into metadata_jobs values ('m1', 'running', '[5,6,0]', 1), ('m0', 'done', '[7]', 1)"
    db.exec "create table embed_queue (book_id integer primary key)"
    db.exec "insert into embed_queue values (4)"
    f = jobs.followup_status
    f["queues"].as_h.transform_values(&.as_i).should eq({"metadata" => 3, "embed" => 2, "convert" => 0})
    f["total"].should eq 5
    f["paused"].should be_false
  end

  it "matches only books still in the library and plans files of removed books again" do
    tmpdir do |root|
      # different past the first KiB, where the partial MD5 starts
      %w(x y z w).each { |n| write(File.join(root, "#{n}.pdf"), pdf(n * 2000)) }
      fake = FakeCalibre.new
      fake.add(1, "Bekannt", ["Alte Autorin"], ["PDF"])
      calibre = fake.calibre
      db = state_db
      jobs = CalibreHub::ImportJobs.new(db, calibre, CalibreHub::Writer.new(calibre, nil, nil, "kategorie"), [root], nil, retries: 0)
      CalibreHub::BookFiles.create_checksums(db)
      sum = ->(name : String) { {CalibreHub::BookFiles.partial_md5(File.join(root, name)), File.size(File.join(root, name))} }
      # x.pdf was a file of #370, removed (calibre's trash) since; z.pdf one of #1
      {"x.pdf" => 370_i64, "z.pdf" => 1_i64}.each do |name, id|
        md5, size = sum.call(name)
        db.exec "insert into file_checksums (book_id, format, partial_md5, size, recorded_at) values (?, 'PDF', ?, ?, 0)", id, md5, size
      end
      # an earlier run took y.pdf for a duplicate of #371, removed since, and w.pdf for one of #1
      {"y.pdf" => 371_i64, "w.pdf" => 1_i64}.each do |name, id|
        path = File.join(root, name)
        info = File.info(path)
        db.exec "insert into import_files (path, size, mtime, status, book_id, run_id, at) values (?, ?, ?, 'duplicate', ?, 'old', 0)",
          path, info.size, info.modification_time.to_unix, id
      end

      dry = wait_run(jobs, jobs.start(".", true)["id"].as_s)
      dry["summary"]["alreadyImported"].should eq 1
      dry["summary"]["books"].should eq 3
      dry["summary"]["toAdd"].should eq 2
      dry["summary"]["duplicates"]["file"].should eq 1

      run = jobs.start(".", false)
      wait_job(jobs, run["jobId"].as_s).status.should eq "done"
      jobs.run(run["id"].as_s).not_nil!["results"].as_h.transform_values(&.as_i).should eq({"imported" => 2, "duplicate" => 1})
      fake.books.values.map(&.["title"].as_s).sort.should eq ["Bekannt", "x", "y"]
    end
  end

  it "fails only the unit of a book calibre-server errs on and goes on" do
    tmpdir do |root|
      cal = File.join(root, "A", "Bekannt (1)")
      write(File.join(cal, "metadata.opf"), opf("Bekannt", "Alte Autorin"))
      write(File.join(cal, "b.pdf"), pdf("b"))
      write(File.join(root, "B", "neu.pdf"), pdf("n"))
      fake = FakeCalibre.new
      fake.add(1, "Bekannt", ["Alte Autorin"], ["EPUB"])
      # calibre lists #1, but adding a format fails: NoSuchBook, HTTP 500
      fake.no_such_book << 1_i64
      calibre = fake.calibre
      db = state_db
      jobs = CalibreHub::ImportJobs.new(db, calibre, CalibreHub::Writer.new(calibre, nil, nil, "kategorie"), [root], nil, retries: 0)
      run = jobs.start(".", false)
      job = wait_job(jobs, run["jobId"].as_s)
      job.status.should eq "done"
      job.error.should be_nil
      job.errors.size.should eq 1
      job.errors.first[:error].should contain("HTTP 500")
      jobs.run(run["id"].as_s).not_nil!["results"].as_h.transform_values(&.as_i).should eq({"failed" => 1, "imported" => 1})
      failed = jobs.report(run["id"].as_s).not_nil!["units"].as_a.find(&.["status"].==("failed")).not_nil!
      failed["detail"].as_s.should contain("set-fields/1")
      fake.books.values.map(&.["title"].as_s).sort.should eq ["Bekannt", "neu"]
    end
  end

  it "fails the run when the scan fails" do
    tmpdir do |root|
      Dir.mkdir_p(File.join(root, "x"))
      db = state_db
      # nothing listens there: the library can't be read for the plan
      calibre = CalibreHub::Calibre.new("http://127.0.0.1:1", "hub", "pw", nil, ["kategorie"])
      jobs = CalibreHub::ImportJobs.new(db, calibre, CalibreHub::Writer.new(calibre, nil, nil, "kategorie"), [root], nil, retries: 0)
      run = wait_run(jobs, jobs.start("x", true)["id"].as_s)
      run["status"].should eq "failed"
      run["error"].as_s.should contain("calibre-server unavailable")
      run["summary"].raw.should be_nil
    end
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
