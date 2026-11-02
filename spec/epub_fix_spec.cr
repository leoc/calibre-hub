require "spec"
require "file_utils"
require "kemal"
require "../src/calibre_hub/api"
require "../src/calibre_hub/epub_fix"

EF_CONTAINER = <<-XML
  <?xml version="1.0"?>
  <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
    <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
  </container>
  XML

# a package with every problem the fixer knows: dc:language "und", no
# toc on the spine, no cover meta
EF_OPF = <<-XML
  <?xml version="1.0" encoding="utf-8"?>
  <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
    <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
      <dc:title>Die Wiese</dc:title>
      <dc:identifier id="id">urn:uuid:1</dc:identifier>
      <dc:language>und</dc:language>
    </metadata>
    <manifest>
      <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
      <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
      <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
      <item id="cover-img" href="images/cover.jpg" media-type="image/jpeg"/>
    </manifest>
    <spine>
      <itemref idref="c1"/>
      <itemref idref="c2"/>
    </spine>
  </package>
  XML

# no XML declaration, an img without src, a link to a body id
EF_CH1 = <<-XML
  <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Eins</title></head>
  <body id="kap1">
  <p>Die Grille sang.<img/></p>
  <p><img src="../images/cover.jpg" alt="Wiese"/><img src="" alt="leer"></img></p>
  <p><a href="ch2.xhtml#kap2">weiter</a> <a href="ch2.xhtml#stelle">Stelle</a> <a href="fehlt.xhtml">weg</a></p>
  </body></html>
  XML

private def ch2 : Bytes
  text = <<-XML
    <?xml version="1.0" encoding="iso-8859-1"?>
    <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Zwei</title></head>
    <body id="kap2"><p id="stelle">Größe der Wiese</p></body></html>
    XML
  text.encode("ISO-8859-1")
end

EF_NCX = <<-XML
  <?xml version="1.0" encoding="utf-8"?>
  <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>
  <navPoint id="n1" playOrder="1"><navLabel><text>Eins</text></navLabel><content src="text/ch1.xhtml"/></navPoint>
  <navPoint id="n2" playOrder="2"><navLabel><text>Zwei</text></navLabel><content src="text/ch2.xhtml#kap2"/></navPoint>
  </navMap></ncx>
  XML

EF_COVER = Bytes[0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4, 0xFF, 0xD9]

# A ZIP with these entries in this order; mimetype compressed unless stored
private def zip(path : String, entries : Array({String, Bytes}), stored_mimetype = false)
  File.open(path, "w") do |io|
    Compress::Zip::Writer.open(io) do |z|
      entries.each do |name, data|
        if name == "mimetype" && stored_mimetype
          e = Compress::Zip::Writer::Entry.new(name)
          e.compression_method = Compress::Zip::CompressionMethod::STORED
          e.crc32 = Digest::CRC32.checksum(data)
          e.compressed_size = e.uncompressed_size = data.size.to_u32
          z.add(e, data)
        else
          z.add(name, data)
        end
      end
    end
  end
  path
end

private def broken_epub(path : String, opf = EF_OPF) : String
  zip(path, [
    {"META-INF/container.xml", EF_CONTAINER.to_slice},
    {"mimetype", "application/epub+zip".to_slice},
    {"OEBPS/content.opf", opf.to_slice},
    {"OEBPS/toc.ncx", EF_NCX.to_slice},
    {"OEBPS/text/ch1.xhtml", EF_CH1.to_slice},
    {"OEBPS/text/ch2.xhtml", ch2},
    {"OEBPS/images/cover.jpg", EF_COVER},
  ])
end

private def entries(path : String) : Array({String, Bytes, Bool})
  list = [] of {String, Bytes, Bool}
  Compress::Zip::File.open(path) do |z|
    z.entries.each { |e| list << {e.filename, e.open(&.getb_to_end), e.compression_method.stored?} }
  end
  list
end

private def text(path : String, name : String) : String
  String.new(entries(path).find! { |n, _, _| n == name }[1])
end

private def with_dir(&)
  dir = File.tempname("epub-fix")
  Dir.mkdir_p(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

describe CalibreHub::EpubFix do
  it "maps calibre's languages to what goes into dc:language" do
    CalibreHub::EpubFix.language(["deu"]).should eq("de")
    CalibreHub::EpubFix.language(["und", "eng"]).should eq("en")
    CalibreHub::EpubFix.language(["und"]).should be_nil
    CalibreHub::EpubFix.language(["gsw"]).should eq("gsw")
    CalibreHub::EpubFix.language([] of String).should be_nil
  end

  it "resolves references inside the EPUB" do
    CalibreHub::EpubFix.resolve("OEBPS/text/ch1.xhtml", "../images/a%20b.jpg").should eq("OEBPS/images/a b.jpg")
    CalibreHub::EpubFix.resolve("OEBPS/toc.ncx", "text/ch1.xhtml").should eq("OEBPS/text/ch1.xhtml")
    CalibreHub::EpubFix.resolve("ch1.xhtml", "https://example.org/x").should be_nil
    CalibreHub::EpubFix.resolve("ch1.xhtml", "mailto:a@b").should be_nil
  end

  it "repairs a broken EPUB without losing anything, and finds nothing the second time" do
    with_dir do |dir|
      src = broken_epub(File.join(dir, "in.epub"))
      dst = File.join(dir, "out.epub")
      report = CalibreHub::EpubFix.run(src, dst, "de")
      report.fixes.map(&.code).sort.should eq(%w(body-id-link body-id-link cover-meta encoding language mimetype spine-toc stray-img xml-declaration))
      report.problems.map { |p| {p.code, p.file} }.should eq([{"broken-reference", "OEBPS/text/ch1.xhtml"}])

      out = entries(dst)
      out.first.should eq({"mimetype", "application/epub+zip".to_slice, true})
      out.map(&.[0]).sort.should eq(entries(src).map(&.[0]).sort)
      out.find! { |n, _, _| n == "OEBPS/images/cover.jpg" }[1].should eq(EF_COVER)

      opf = text(dst, "OEBPS/content.opf")
      opf.should contain("<dc:language>de</dc:language>")
      opf.should_not contain("und")
      opf.should contain(%(<spine toc="ncx">))
      opf.should contain(%(<meta name="cover" content="cover-img"/>))
      XML.parse(opf).root.not_nil!.name.should eq("package")

      c1 = text(dst, "OEBPS/text/ch1.xhtml")
      c1.should start_with(%(<?xml version="1.0" encoding="utf-8"?>\n<html))
      c1.should contain(%(<img src="../images/cover.jpg" alt="Wiese"/>))
      c1.scan(/<img\b/).size.should eq(1)
      c1.should contain(%(<p>Die Grille sang.</p>))
      c1.should contain(%(href="ch2.xhtml">weiter))
      c1.should contain(%(href="ch2.xhtml#stelle"))
      c1.should contain(%(href="fehlt.xhtml"))

      c2 = text(dst, "OEBPS/text/ch2.xhtml")
      c2.valid_encoding?.should be_true
      c2.should start_with(%(<?xml version="1.0" encoding="utf-8"?>))
      c2.should contain("Größe der Wiese")
      XML.parse(c2).root.not_nil!.name.should eq("html")

      text(dst, "OEBPS/toc.ncx").should contain(%(<content src="text/ch2.xhtml"/>))

      again = CalibreHub::EpubFix.run(dst, File.join(dir, "again.epub"), "de")
      again.fixes.should be_empty
      File.exists?(File.join(dir, "again.epub")).should be_false
    end
  end

  it "only reports what it can't repair safely" do
    with_dir do |dir|
      # no language in calibre: "und" stays
      src = broken_epub(File.join(dir, "in.epub"))
      report = CalibreHub::EpubFix.run(src, nil, nil)
      report.fixes.map(&.code).should_not contain("language")
      report.problems.map(&.code).should contain("language")

      # UTF-8 with a stray Latin-1 byte: converting would garble the umlauts
      mixed = IO::Memory.new
      mixed << %(<?xml version="1.0" encoding="utf-8"?>\n<html xmlns="http://www.w3.org/1999/xhtml"><body><p>Größe )
      mixed.write(Bytes[0xE4])
      mixed << "</p></body></html>"
      opf = EF_OPF.sub("<dc:language>und</dc:language>", "<dc:language>de-DE</dc:language>")
      path = zip(File.join(dir, "mixed.epub"), [
        {"mimetype", "application/epub+zip".to_slice},
        {"META-INF/container.xml", EF_CONTAINER.to_slice},
        {"OEBPS/content.opf", opf.to_slice},
        {"OEBPS/text/ch1.xhtml", mixed.to_slice},
      ], stored_mimetype: true)
      dst = File.join(dir, "mixed-out.epub")
      report = CalibreHub::EpubFix.run(path, dst, "de")
      report.problems.map { |p| {p.code, p.file} }.should contain({"encoding", "OEBPS/text/ch1.xhtml"})
      report.problems.map(&.code).should contain("missing-file")
      # nothing else wrong (de-DE is a language), so nothing written
      report.fixes.should be_empty
      File.exists?(dst).should be_false

      # a dry run writes nothing
      CalibreHub::EpubFix.run(src, nil, "de").changed?.should be_true
    end
  end

  it "adds a missing dc:language and refuses what isn't an EPUB" do
    with_dir do |dir|
      # and whitespace before the XML declaration
      opf = "\n  " + EF_OPF.sub(/\s*<dc:language>und<\/dc:language>/, "")
      src = broken_epub(File.join(dir, "in.epub"), opf)
      dst = File.join(dir, "out.epub")
      fixes = CalibreHub::EpubFix.run(src, dst, "en").fixes
      fixes.map(&.detail).should contain("added en")
      fixes.find! { |f| f.file == "OEBPS/content.opf" && f.code == "xml-declaration" }.detail.should contain("whitespace")
      text(dst, "OEBPS/content.opf").should start_with(%(<?xml version="1.0" encoding="utf-8"?>\n<package))
      text(dst, "OEBPS/content.opf").should contain("<dc:language>en</dc:language>")

      File.write(File.join(dir, "kaputt.epub"), "kein zip")
      expect_raises(CalibreHub::EpubFix::Error) { CalibreHub::EpubFix.run(File.join(dir, "kaputt.epub"), nil, nil) }
      nocontainer = zip(File.join(dir, "nc.epub"), [{"mimetype", "application/epub+zip".to_slice}], stored_mimetype: true)
      expect_raises(CalibreHub::EpubFix::Error, /package document/) { CalibreHub::EpubFix.run(nocontainer, nil, nil) }
    end
  end
end

# calibre-server for one book with an EPUB: serves the file, takes formats
private class FakeServer
  getter requests = [] of {String, JSON::Any}
  getter url : String
  property epub : Bytes = Bytes.empty
  property formats = ["EPUB"]
  property languages = ["deu"]

  def initialize
    @server = HTTP::Server.new do |ctx|
      path = ctx.request.path
      raw = ctx.request.body.try(&.gets_to_end).presence
      body = path.starts_with?("/cdb/") && raw ? JSON.parse(raw) : JSON::Any.new(nil)
      @requests << {path, body}
      ctx.response.content_type = "application/json"
      case path
      when "/cdb/cmd/list/0"
        data = {
          "title"         => {"1" => "Die Wiese"},
          "formats"       => {"1" => @formats},
          "languages"     => {"1" => @languages},
          "last_modified" => {"1" => "2026-11-02T10:00:00+00:00"},
        }
        ctx.response.print({result: {book_ids: [1], data: data}}.to_json)
      when "/cdb/set-fields/1"
        body["changes"]["added_formats"]?.try &.as_a.each do |f|
          ext = f["ext"].as_s.upcase
          @formats << ext unless @formats.includes?(ext)
          @epub = Base64.decode(f["data_url"].as_s) if ext == "EPUB"
        end
        ctx.response.print "{}"
      when "/get/epub/1"
        ctx.response.content_type = "application/epub+zip"
        ctx.response.write @epub
      else
        ctx.response.status_code = 404
      end
    end
    address = @server.bind_tcp("127.0.0.1", 0)
    @url = "http://127.0.0.1:#{address.port}"
    spawn { @server.listen }
  end

  def calibre : CalibreHub::Calibre
    CalibreHub::Calibre.new(url, "hub", "pw")
  end

  def added : Array(String)
    requests.select { |p, _| p == "/cdb/set-fields/1" }.flat_map { |_, b| b["changes"]["added_formats"].as_a.map(&.["ext"].as_s) }
  end

  def close
    @server.close
  end
end

private def wait(jobs, id)
  200.times { break unless jobs.running?; sleep 10.milliseconds }
  jobs[id]?.not_nil!
end

describe CalibreHub::EpubFixJobs do
  it "checks in a dry run, repairs for real keeping the original, and follows added books" do
    with_dir do |dir|
      path = File.tempname("hub-epubfix", ".sqlite")
      db = DB.open("sqlite3://#{path}?max_pool_size=1")
      server = FakeServer.new
      server.epub = File.read(broken_epub(File.join(dir, "in.epub"))).to_slice
      original = server.epub
      detector = CalibreHub::Detector.new(server.calibre, db)
      writer = CalibreHub::Writer.new(server.calibre, nil, nil, nil)
      jobs = CalibreHub::EpubFixJobs.new(db, server.calibre, writer, nil, true, true, detector)

      # a dry run over the library: found, nothing written
      job = jobs.submit_fix({} of String => JSON::Any)
      job.total.should eq(1)
      wait(jobs, job.id).status.should eq("done")
      server.added.should be_empty
      s = jobs.summary(jobs[job.id]?.not_nil!, results: true)
      s["dryRun"].should eq(true)
      s["booksWithFixes"].should eq(1)
      s["booksFixed"].should eq(0)
      s["fixes"]["language"].should eq(1)
      s["results"][0]["fixes"].as_a.map(&.["code"].as_s).should contain("stray-img")

      expect_raises(CalibreHub::Edit::Invalid) { jobs.submit_fix({"dryRun" => JSON::Any.new("ja")}) }

      # for real: the original first, then the repaired EPUB
      job = jobs.submit_fix({"dryRun" => JSON::Any.new(false), "target" => JSON.parse(%({"ids": [1]}))})
      wait(jobs, job.id).status.should eq("done")
      server.added.should eq(["original_epub", "epub"])
      server.formats.should eq(["EPUB", "ORIGINAL_EPUB"])
      jobs.summary(jobs[job.id]?.not_nil!)["booksFixed"].should eq(1)
      File.write(File.join(dir, "fixed.epub"), server.epub)
      text(File.join(dir, "fixed.epub"), "OEBPS/content.opf").should contain("<dc:language>de</dc:language>")
      # the handlers hear that the file changed
      payload = db.query_one("select payload from events order by id desc limit 1", as: String)
      JSON.parse(payload)["changes"]["formats"][0].should eq(JSON.parse(%(["EPUB", "ORIGINAL_EPUB"])))

      # again: nothing to do, the original isn't replaced
      job = jobs.submit_fix({"dryRun" => JSON::Any.new(false)})
      wait(jobs, job.id)
      server.added.size.should eq(2)

      # an added book with an EPUB is repaired on its own
      server.epub = original
      server.formats = ["EPUB", "ORIGINAL_EPUB"]
      jobs.follow_events
      e = CalibreHub::Event.new("added", 1_i64, book: JSON.parse(%({"formats": ["EPUB"]})))
      db.exec "insert into events (type, book_id, payload, created_at) values (?, ?, ?, ?)", "added", 1_i64, e.to_json, 0
      e = CalibreHub::Event.new("added", 2_i64, book: JSON.parse(%({"formats": ["PDF"]})))
      db.exec "insert into events (type, book_id, payload, created_at) values (?, ?, ?, ?)", "added", 2_i64, e.to_json, 0
      jobs.follow_events
      last = jobs.last.not_nil![0]
      last.total.should eq(1)
      last.changes["from"].should eq("added")
      wait(jobs, last.id).status.should eq("done")
      server.added.last.should eq("epub")
    ensure
      sleep 20.milliseconds
      server.try &.close
      db.try &.close
      File.delete?(path) if path
    end
  end
end
