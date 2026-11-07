require "spec"
require "file_utils"
require "http/server"
require "../src/calibre_hub/intake"

private alias Meta = CalibreHub::Meta
private alias Backlog = CalibreHub::Backlog
private alias Intake = CalibreHub::Intake

private def write(path : String, content : String, age = 1.hour)
  Dir.mkdir_p(File.dirname(path))
  File.write(path, content)
  time = Time.utc - age
  File.utime(time, time, path)
end

private def pdf(text = "x") : String
  "%PDF-1.4\n" + text + ("." * 4000)
end

private def mobi(text = "x") : String
  ("\0" * 60) + "BOOKMOBI" + text + ("." * 4000)
end

private def opf(title : String, author : String, isbn = "") : String
  <<-XML
  <?xml version='1.0' encoding='utf-8'?>
  <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
    <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
      <dc:title>#{title}</dc:title>
      <dc:creator opf:role="aut">#{author}</dc:creator>
      <dc:publisher>Random House, Inc.</dc:publisher>
      <dc:identifier opf:scheme="ISBN">#{isbn}</dc:identifier>
      <dc:subject>Fiction</dc:subject>
    </metadata>
  </package>
  XML
end

# calibre-server as the analysis may see it: it lists books, and every
# other request is noted, nothing here may ever make one
private class ListOnlyCalibre
  getter books = {} of Int64 => {String, Array(String), String?}
  getter others = [] of String
  property down = false
  getter url : String

  def initialize
    @server = HTTP::Server.new do |ctx|
      ctx.response.content_type = "application/json"
      body = JSON.parse(ctx.request.body.try(&.gets_to_end).presence || "null")
      if @down
        ctx.response.status_code = 503
      elsif ctx.request.path == "/cdb/cmd/list/0"
        ids = @books.keys
        fields = body[0].as_a.map(&.as_s)
        data = fields.to_h do |f|
          values = ids.to_h do |i|
            title, authors, isbn = @books[i]
            value = case f
                    when "title"       then JSON::Any.new(title)
                    when "authors"     then JSON.parse(authors.to_json)
                    when "formats"     then JSON.parse(%(["PDF"]))
                    when "identifiers" then JSON.parse((isbn ? {"isbn" => isbn} : {} of String => String).to_json)
                    else                    JSON::Any.new(nil)
                    end
            {i.to_s, value}
          end
          {f.sub('*', '#'), values}
        end
        ctx.response.print({result: {book_ids: ids, data: data}}.to_json)
      else
        @others << ctx.request.path
        ctx.response.status_code = 404
      end
    end
    @url = "http://127.0.0.1:#{@server.bind_tcp("127.0.0.1", 0).port}"
    spawn { @server.listen }
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

private def info(title : String? = nil, authors : Array(String)? = nil, front = "", isbn : String? = nil, format = "PDF") : Meta::FileMeta::Info?
  Meta::FileMeta::Info.new(Meta::Record.new(title: title, authors: authors, isbn: isbn), isbn ? [isbn] : [] of String,
    front: front, format: format).as(Meta::FileMeta::Info?)
end

private def setup(root : String, fake = ListOnlyCalibre.new, db = state_db, stable = 0.seconds)
  calibre = fake.calibre
  writer = CalibreHub::Writer.new(calibre, nil, nil, "kategorie")
  imports = CalibreHub::Importer.new(db, calibre, writer, [root], nil, retries: 0)
  intake = Intake.new(db, calibre, imports, nil, File.join(root, ".covers"), CalibreHub::IntakeTrash.new(File.join(File.dirname(root), "papierkorb")),
    stable: stable, pause: 0.seconds, wait: 10.milliseconds)
  intake.cover_reader = ->(_path : String, _format : String, _target : String) { false }
  {intake, fake, db, imports}
end

private def tmpdir(&)
  dir = File.tempname("intake")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def entries(intake : Intake, **filter) : Array(JSON::Any)
  intake.list(**filter)["entries"].as_a
end

describe Intake do
  it "proposes metadata from the file, writing nothing to the library" do
    tmpdir do |root|
      write(File.join(root, "Frank Herbert - Dune (Chilton, 1965).pdf"), pdf("dune"))
      write(File.join(root, "other.pdf"), pdf("other"))
      intake, fake, _, _ = setup(root)
      read = [] of String
      intake.reader = ->(path : String, format : String) do
        read << format
        File.basename(path) == "other.pdf" ? info : info("Dune", ["Frank Herbert"], "Dune by Frank Herbert")
      end
      intake.run_once.should eq 2
      read.should eq ["PDF", "PDF"]
      fake.others.should be_empty

      list = entries(intake)
      list.size.should eq 2
      dune = list.first
      dune["name"].should eq "Frank Herbert - Dune (Chilton, 1965).pdf"
      dune["folder"].raw.should be_nil
      dune["proposal"]["title"].should eq "Dune"
      dune["proposal"]["authors"].should eq ["Frank Herbert"]
      dune["proposal"]["publisher"].should eq "Chilton"
      dune["confidence"].should eq Meta::Confidence::META_NAME
      dune["band"].should eq "bulk"
      dune["action"].should eq "add"
      dune["cover"].raw.should be_nil

      other = list.last
      other["band"].should eq "unsure"
      other["level"].should eq Meta::Flow::LEVEL_NAME
    end
  end

  it "stores every candidate with its source and confidence" do
    tmpdir do |root|
      write(File.join(root, "Kahneman - Thinking Fast.pdf"), pdf)
      intake, _, _, _ = setup(root)
      text = "Thinking, Fast and Slow by Daniel Kahneman " + ("word " * 200) + "ISBN 9780374533557"
      intake.reader = ->(_p : String, _f : String) { info("Scan", nil, text, "9780374533557") }
      record = Meta::Record.new(title: "Thinking, Fast and Slow", authors: ["Daniel Kahneman"], isbn: "9780374533557")
      intake.by_isbn = ->(_isbn : String) { [Meta::Candidate.new("openlibrary", record)] }
      searched = 0
      intake.search = ->(_b : CalibreHub::Book, _g : Meta::Guess) { searched += 1; [] of Meta::Candidate }
      intake.run_once
      e = entries(intake).first
      e["proposal"]["title"].should eq "Thinking, Fast and Slow"
      e["proposal"]["isbn"].should eq "9780374533557"
      e["level"].should eq Meta::Flow::LEVEL_ISBN
      e["isbnSource"].should eq "text"

      detail = intake.detail(e["id"].as_i64).not_nil!
      found = detail["candidates"].as_a
      found.map(&.["source"].as_s).should eq ["openlibrary", "name", "file"]
      found.first["confidence"].should eq Meta::Confidence::ISBN_BOTH
      found.first["fields"]["title"].should eq "Thinking, Fast and Slow"
      detail["changes"].as_a.map(&.["field"].as_s).should contain "title"
      # the catalog answered by ISBN: no title search on top
      searched.should eq 0
    end
  end

  it "asks the catalogs by title when no ISBN found anything" do
    tmpdir do |root|
      write(File.join(root, "Ursula Le Guin - The Dispossessed.pdf"), pdf)
      intake, _, _, _ = setup(root)
      intake.reader = ->(_p : String, _f : String) { info }
      hit = Meta::Candidate.new("hardcover", Meta::Record.new(title: "The Dispossessed", authors: ["Ursula K. Le Guin"]))
      hit.score = 0.95
      asked = [] of String
      intake.search = ->(_b : CalibreHub::Book, g : Meta::Guess) { asked << g.title; [hit] }
      intake.run_once
      asked.should eq ["The Dispossessed"]
      c = intake.candidates(entries(intake).first["id"].as_i64).find(&.source.==("hardcover")).not_nil!
      c.confidence.should eq Meta::Confidence::CATALOG_NAME
    end
  end

  it "checks a calibre folder's OPF instead of trusting it" do
    tmpdir do |root|
      dir = File.join(root, "calibre", "Christie Golden", "Allies (177)")
      write(File.join(dir, "Allies - Christie Golden.mobi"), mobi)
      write(File.join(dir, "metadata.opf"), opf("Christie Golden", "Allies"))
      write(File.join(dir, "cover.jpg"), "\xFF\xD8\xFFcover")
      good = File.join(root, "calibre", "Ken Watanabe", "Problem Solving 101 (257)")
      write(File.join(good, "Problem Solving 101 - Ken Watanabe.mobi"), mobi("ps"))
      write(File.join(good, "metadata.opf"), opf("Problem Solving 101", "Ken Watanabe"))
      intake, _, _, _ = setup(root)
      intake.reader = ->(_p : String, _f : String) { info(format: "MOBI") }
      intake.run_once
      # the surer one first
      kept, swapped = entries(intake)
      swapped["kind"].should eq "calibre"
      swapped["folder"].should eq "calibre/Christie Golden/Allies (177)"
      swapped["proposal"]["title"].should eq "Allies"
      swapped["proposal"]["authors"].should eq ["Christie Golden"]
      # the OPF still gives what the name doesn't have
      swapped["proposal"]["publisher"].should eq "Random House, Inc."
      swapped["cover"].as_s.should start_with "/api/intake/"
      kept["proposal"]["title"].should eq "Problem Solving 101"
      kept["confidence"].should eq Meta::Confidence::META_NAME
      found = intake.candidates(kept["id"].as_i64)
      found.map(&.source).should contain Meta::Flow::SOURCE_OPF
    end
  end

  it "reads a file in a folder of calibre's shape as Title - Author" do
    tmpdir do |root|
      # #3119: no OPF left, "Allies" looks like a surname
      write(File.join(root, "Christie Golden", "Allies (177)", "Allies - Christie Golden.mobi"), mobi)
      intake, _, _, _ = setup(root)
      intake.reader = ->(_p : String, _f : String) { info(format: "MOBI") }
      intake.run_once
      e = entries(intake).first
      e["kind"].should eq "file"
      e["proposal"]["title"].should eq "Allies"
      e["proposal"]["authors"].should eq ["Christie Golden"]
    end
  end

  it "doesn't take an EPUB's trust over to its calibre folder's OPF" do
    unit = Backlog::Unit.new("calibre", "/x", [Backlog::BookFile.new("/x/a.epub", "EPUB", 1_i64, 1_i64)], nil, Backlog::OpfMeta.new)
    Intake.flow_info(unit, info(format: "EPUB")).not_nil!.format.should eq "OPF"
  end

  it "marks duplicates of the library and of the list itself" do
    tmpdir do |root|
      write(File.join(root, "Frank Herbert - Dune.pdf"), pdf("a"))
      write(File.join(root, "a", "Ursula Le Guin - The Dispossessed.pdf"), pdf("first"))
      write(File.join(root, "b", "Ursula Le Guin - The Dispossessed.pdf"), pdf("second copy"))
      fake = ListOnlyCalibre.new
      fake.books[7_i64] = {"Dune", ["Frank Herbert"], nil}
      intake, _, _, _ = setup(root, fake)
      intake.reader = ->(_p : String, _f : String) { info }
      intake.run_once
      by_name = entries(intake).group_by(&.["path"].as_s.lchop(root + "/"))
      dune = by_name["Frank Herbert - Dune.pdf"].first
      dune["bookId"].should eq 7
      dune["match"].should eq "title"
      second = by_name["b/Ursula Le Guin - The Dispossessed.pdf"].first
      second["sameAs"].as_s.should end_with "a/Ursula Le Guin - The Dispossessed.pdf"
      by_name["a/Ursula Le Guin - The Dispossessed.pdf"].first["action"].should eq "add"
      # Dune has the book's title and authors: sure, the other is for a person
      entries(intake, duplicates: "sure").size.should eq 1
      entries(intake, duplicates: true).size.should eq 1
      entries(intake, duplicates: false).size.should eq 1
      # the counts are the kind's
      intake.list(duplicates: true)["counts"].as_h.values.sum(&.as_i).should eq 1
      intake.list["counts"].as_h.values.sum(&.as_i).should eq 3
    end
  end

  it "analyses a file only once, also after a restart, and again when it changes" do
    tmpdir do |root|
      path = File.join(root, "Frank Herbert - Dune.pdf")
      write(path, pdf)
      intake, fake, db, _ = setup(root)
      reads = 0
      reader = ->(_p : String, _f : String) { reads += 1; info }
      intake.reader = reader
      intake.run_once.should eq 1
      intake.run_once.should eq 0

      again, _, _, _ = setup(root, fake, db)
      again.reader = reader
      again.run_once.should eq 0
      reads.should eq 1

      write(path, pdf("a longer file than before"))
      again.run_once.should eq 1
      reads.should eq 2
      entries(again).size.should eq 1
    end
  end

  it "drops what left the roots or an import handled" do
    tmpdir do |root|
      gone = File.join(root, "Frank Herbert - Dune.pdf")
      imported = File.join(root, "Ursula Le Guin - The Dispossessed.pdf")
      write(gone, pdf("a"))
      write(imported, pdf("b"))
      intake, _, db, _ = setup(root)
      intake.reader = ->(_p : String, _f : String) { info }
      intake.run_once
      entries(intake).size.should eq 2
      File.delete(gone)
      stat = File.info(imported)
      db.exec "insert into import_files (path, size, mtime, status, book_id, run_id, at) values (?, ?, ?, 'imported', null, 'r', 0)",
        imported, stat.size, stat.modification_time.to_unix
      intake.run_once
      entries(intake).should be_empty
    end
  end

  it "leaves a file alone that may still be copied" do
    tmpdir do |root|
      write(File.join(root, "Frank Herbert - Dune.pdf"), pdf, age: 0.seconds)
      intake, _, _, _ = setup(root, stable: 1.hour)
      intake.run_once.should eq 0
      entries(intake).should be_empty
    end
  end

  it "keeps a file that fails, and goes on" do
    tmpdir do |root|
      write(File.join(root, "a.pdf"), pdf("a"))
      write(File.join(root, "Frank Herbert - Dune.pdf"), pdf("b"))
      intake, _, _, _ = setup(root)
      reads = 0
      intake.reader = ->(p : String, _f : String) do
        reads += 1
        raise "broken" if File.basename(p) == "a.pdf"
        info
      end
      intake.run_once.should eq 2
      # a file that failed has no confidence: the end of the list
      ok, failed = entries(intake)
      failed["status"].should eq "failed"
      failed["detail"].should eq "broken"
      failed["band"].raw.should be_nil
      ok["status"].should eq "analysed"
      intake.list["counts"]["none"].should eq 1
      # a file that failed is in the Eingang, without a proposal
      progress = intake.list(band: "bulk")["progress"]
      {progress["total"], progress["analysed"]}.should eq({2, 1})
      entries(intake, band: "none").size.should eq 1
      # unchanged it isn't tried again
      intake.run_once.should eq 0
      reads.should eq 2
    end
  end

  it "waits for a running import and reports where it is" do
    tmpdir do |root|
      write(File.join(root, "Frank Herbert - Dune.pdf"), pdf)
      intake, _, _, _ = setup(root)
      importing = true
      intake.busy = -> { importing }
      seen = [] of {String, String?, Int64, Int64}
      intake.reader = ->(_p : String, _f : String) do
        p = intake.progress
        seen << {p[:state], p[:current], p[:done], p[:total]}
        info
      end
      spawn { intake.run_once }
      sleep 50.milliseconds
      intake.state.should eq "paused"
      entries(intake).should be_empty
      importing = false
      sleep 100.milliseconds
      seen.should eq [{"analysing", "Frank Herbert - Dune.pdf", 0_i64, 1_i64}]
      intake.progress.should eq({state: "idle", done: 1_i64, total: 1_i64, analysed: 1_i64, current: nil})
    end
  end

  it "can be switched off and on, also over a restart" do
    tmpdir do |root|
      write(File.join(root, "Frank Herbert - Dune.pdf"), pdf)
      intake, fake, db, _ = setup(root)
      intake.reader = ->(_p : String, _f : String) { info }
      intake.analysis = false
      intake.progress[:state].should eq "off"
      again, _, _, _ = setup(root, fake, db)
      again.off?.should be_true
      again.reader = ->(_p : String, _f : String) { info }
      spawn { again.run_once }
      sleep 50.milliseconds
      again.state.should eq "off"
      entries(again).should be_empty
      again.analysis = true
      sleep 100.milliseconds
      entries(again).size.should eq 1
      again.progress[:state].should eq "idle"
    end
  end

  it "filters by confidence and pages through the list" do
    tmpdir do |root|
      write(File.join(root, "Frank Herbert - Dune.pdf"), pdf("a"))
      write(File.join(root, "b.pdf"), pdf("b"))
      write(File.join(root, "c.pdf"), pdf("c"))
      intake, _, _, _ = setup(root)
      intake.reader = ->(p : String, _f : String) do
        File.basename(p).starts_with?("Frank") ? info("Dune", ["Frank Herbert"], "Dune by Frank Herbert") : info
      end
      intake.run_once
      list = intake.list(band: "unsure", limit: 1, offset: 1)
      list["total"].should eq 2
      list["entries"].as_a.map(&.["name"]).should eq ["c.pdf"]
      entries(intake, band: "bulk").size.should eq 1
      entries(intake, band: "review").should be_empty
      expect_raises(CalibreHub::Edit::Invalid) { intake.list(band: "nonsense") }
    end
  end

  it "reads what calibre would without calibre" do
    unit = Backlog::Unit.new("file", "/x", [Backlog::BookFile.new("/x/Dune - Frank Herbert.pdf", "PDF", 1_i64, 1_i64)])
    book = Intake.book(unit, nil)
    book.title.should eq "Dune"
    book.authors.should eq ["Frank Herbert"]
    book.formats.should eq ["PDF"]
    record = Meta::Record.new(title: "Dune Messiah", authors: ["F. Herbert"], isbn: "9780441172696", pubdate: "1969", languages: ["eng"])
    read = Intake.book(unit, Meta::FileMeta::Info.new(record, [] of String))
    read.title.should eq "Dune Messiah"
    read.authors.should eq ["F. Herbert"]
    read.identifiers["isbn"].should eq "9780441172696"
    read.pubdate.try(&.year).should eq 1969
    read.languages.should eq ["eng"]
  end

  it "keeps a standard's name, no flow decides it" do
    tmpdir do |root|
      write(File.join(root, "[DIN EN ISO 14971 2013-04] -- Medizinprodukte.pdf"), pdf)
      intake, _, _, _ = setup(root)
      intake.reader = ->(_p : String, _f : String) { info }
      intake.run_once
      e = entries(intake).first
      e["confidence"].should eq Meta::Confidence::KEPT
      e["proposal"]["title"].as_s.should contain "14971"
    end
  end
end

private def reset_routes
  Kemal::RouteHandler::INSTANCE.routes = Radix::Tree(Kemal::Route).new
  Kemal::RouteHandler::INSTANCE.cached_routes = Kemal::LRUCache(String, Radix::Result(Kemal::Route)).new(Kemal.config.max_route_cache_size)
end

private def call(path : String, method = "GET", body : String? = nil) : HTTP::Client::Response
  io = IO::Memory.new
  ctx = HTTP::Server::Context.new(HTTP::Request.new(method, path, body: body), HTTP::Server::Response.new(io))
  Kemal::RouteHandler::INSTANCE.call(ctx)
  ctx.response.close
  HTTP::Client::Response.from_io(IO::Memory.new(io.to_s))
end

describe "intake routes" do
  it "serves the list, an entry and its cover" do
    tmpdir do |root|
      write(File.join(root, "Frank Herbert - Dune.pdf"), pdf)
      intake, _, _, _ = setup(root)
      intake.reader = ->(_p : String, _f : String) { info }
      intake.cover_reader = ->(_path : String, _format : String, target : String) do
        File.write(target, "\xFF\xD8\xFFcover")
        true
      end
      intake.run_once
      reset_routes
      CalibreHub.intake_routes(intake)

      list = JSON.parse(call("/api/intake?band=review&limit=5").body)
      list["enabled"].should be_true
      list["progress"]["state"].should eq "idle"
      entry = list["entries"][0]
      JSON.parse(call("/api/intake/#{entry["id"]}").body)["candidates"].as_a.should_not be_empty
      cover = call(entry["cover"].as_s)
      cover.status_code.should eq 200
      cover.headers["Content-Type"].should eq "image/jpeg"
      call("/api/intake/999").status_code.should eq 404
      call("/api/intake/999/cover").status_code.should eq 404
      call("/api/intake?band=nonsense").status_code.should eq 400
      JSON.parse(call("/api/intake?duplicates=sure").body)["entries"].as_a.all?(&.["sure"].as_bool).should be_true

      JSON.parse(call("/api/intake/analysis", "POST", %({"on":false})).body)["state"].should eq "off"
      intake.off?.should be_true
      call("/api/intake/analysis", "POST", %({"on":true})).status_code.should eq 200
      intake.off?.should be_false
      call("/api/intake/analysis", "POST", %({"on":"maybe"})).status_code.should eq 400
    end
  end

  it "sends the first pages when a look is enough, and says so" do
    tmpdir do |root|
      write(File.join(root, "big.pdf"), pdf + "." * 3000)
      write(File.join(root, "scan.djvu"), "AT&TFORM" + "." * 4000)
      intake, _, _, _ = setup(root)
      intake.peeks = File.join(root, "..", "#{File.basename(root)}-peeks")
      intake.peek_from = 0_i64
      intake.peek_reader = ->(_path : String, format : String, target : String) do
        File.write(target, "first pages") unless format == "DJVU"
        (format == "DJVU" ? nil : 100).as(Int32?)
      end
      intake.run_once
      reset_routes
      CalibreHub.intake_routes(intake)
      ids = JSON.parse(call("/api/intake").body)["entries"].as_a.to_h { |e| {e["name"].as_s, e["id"].as_i64} }
      big, scan = ids["big.pdf"], ids["scan.djvu"]

      whole = call("/api/intake/#{big}/file?format=PDF")
      whole.body.size.should eq File.size(File.join(root, "big.pdf"))
      whole.headers[Intake::PEEK_HEADER]?.should be_nil
      first = call("/api/intake/#{big}/file?format=PDF&first=1")
      first.status_code.should eq 200
      first.body.should eq "first pages"
      first.headers["Content-Length"].should eq "11"
      first.headers[Intake::PEEK_HEADER].should eq "30"
      first.headers["Content-Disposition"].should eq "attachment"
      # never a DjVu as it is, and nothing to send when the tools can't
      call("/api/intake/#{scan}/file?format=DJVU").status_code.should eq 404
      call("/api/intake/#{scan}/file?format=DJVU&first=1").status_code.should eq 422
    ensure
      FileUtils.rm_rf(intake.peeks) if intake
    end
  end

  it "says so without import roots" do
    reset_routes
    CalibreHub.intake_routes(nil)
    JSON.parse(call("/api/intake").body)["enabled"].should be_false
    call("/api/intake/1").status_code.should eq 404
  end
end

describe "FileName.swapped?" do
  it "knows a pair of the name the other way round, also of two words" do
    reading = Meta::Guess.new("Allies", ["Christie Golden"])
    Meta::FileName.swapped?("Christie Golden", ["Allies"], reading).should be_true
    Meta::FileName.swapped?("Allies", ["Christie Golden"], reading).should be_false
  end
end

describe CalibreHub::AuthHandler do
  it "keeps the Eingang for admins" do
    CalibreHub::AuthHandler.reader_may?(HTTP::Request.new("GET", "/api/intake")).should be_false
    CalibreHub::AuthHandler.reader_may?(HTTP::Request.new("GET", "/api/intake/1/cover")).should be_false
    CalibreHub::AuthHandler.reader_may?(HTTP::Request.new("GET", "/api/intake/1/file")).should be_false
  end
end
