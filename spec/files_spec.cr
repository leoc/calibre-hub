require "spec"
require "file_utils"
require "kemal"
require "../src/calibre_hub/api"
require "../src/calibre_hub/files"

# Answers like calibre-server for one library of books with formats
private class FakeServer
  getter requests = [] of {String, JSON::Any}
  # id -> {title, formats, cover}
  getter books = {} of Int64 => {String, Array(String), Bool}
  getter url : String

  def initialize
    @server = HTTP::Server.new do |ctx|
      path = ctx.request.path
      raw = ctx.request.body.try(&.gets_to_end).presence
      body = path.starts_with?("/cdb/") && raw ? JSON.parse(raw) : JSON::Any.new(nil)
      @requests << {path, body}
      ctx.response.content_type = "application/json"
      case path
      when "/cdb/cmd/list/0"
        search = body[3].as_s
        ids = search.empty? ? @books.keys : search.scan(/id:(\d+)/).map(&.[1].to_i64).select { |id| @books.has_key?(id) }
        data = {
          "title"         => ids.to_h { |id| {id.to_s, JSON::Any.new(@books[id][0])} },
          "formats"       => ids.to_h { |id| {id.to_s, JSON.parse(@books[id][1].to_json)} },
          "cover"         => ids.to_h { |id| {id.to_s, @books[id][2] ? JSON::Any.new("/lib/#{id}/cover.jpg") : JSON::Any.new(nil)} },
          "last_modified" => ids.to_h { |id| {id.to_s, JSON::Any.new("2026-11-02T10:00:00+00:00")} },
        }
        ctx.response.print({result: {book_ids: ids, data: data}}.to_json)
      when "/cdb/cmd/embed_metadata/0"
        ctx.response.print({result: @books[body[0].as_i64]?.try(&.[0])}.to_json)
      when .starts_with?("/cdb/set-fields/")
        ctx.response.print "{}"
      when .starts_with?("/get/")
        ctx.response.content_type = "application/octet-stream"
        ctx.response.print "file #{path}"
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

  def paths : Array(String)
    requests.map(&.[0])
  end

  def close
    @server.close
  end
end

private def with_state(&)
  path = File.tempname("hub-files", ".sqlite")
  db = DB.open("sqlite3://#{path}?max_pool_size=1")
  server = FakeServer.new
  detector = CalibreHub::Detector.new(server.calibre, db)
  yield db, server, detector
ensure
  sleep 20.milliseconds
  server.try &.close
  db.try &.close
  File.delete?(path) if path
end

private def event(db, type, id, changes = nil, book = nil)
  e = CalibreHub::Event.new(type, id.to_i64, changes: changes, book: book)
  db.exec "insert into events (type, book_id, payload, created_at) values (?, ?, ?, ?)", type, id.to_i64, e.to_json, 0
end

private def change(field, old, new) : Hash(String, Array(JSON::Any))
  {field => [JSON.parse(old.to_json), JSON.parse(new.to_json)]}
end

private def sample(size : Int32) : String
  path = File.tempname("sample", ".bin")
  File.write(path, Bytes.new(size) { |i| (i % 251).to_u8 })
  path
end

describe CalibreHub::BookFiles do
  it "computes KOReader's partial MD5" do
    {300_000 => "7b136e8f07380b5ca82c093c325dfd79", 3000 => "78f48e291c086dfe94b62ed830c69fe8"}.each do |size, md5|
      path = sample(size)
      CalibreHub::BookFiles.partial_md5(path).should eq(md5)
    ensure
      File.delete?(path) if path
    end
  end
end

describe CalibreHub::Embedder do
  it "queues metadata and cover changes and new formats, not the rest" do
    rel = ->(c : Hash(String, Array(JSON::Any))) { CalibreHub::Embedder.relevant("changed", JSON.parse(c.to_json).as_h) }
    rel.call(change("title", "A", "B")).should eq({true, false})
    rel.call(change("identifiers", {} of String => String, {"isbn" => "1"})).should eq({true, false})
    rel.call(change("#kategorie", "A", "B")).should eq({false, false})
    rel.call(change("formats", ["EPUB"], ["EPUB", "PDF"])).should eq({true, true})
    # the event the embedder sends itself, or calibre reordering the list
    rel.call(change("formats", ["EPUB", "PDF"], ["PDF", "EPUB"])).should eq({false, false})
    rel.call(change("formats", ["EPUB", "PDF"], ["EPUB"])).should eq({false, false})
    CalibreHub::Embedder.relevant("added", nil).should eq({false, false})
  end

  it "debounces edits into one embed, keeps the old checksum and tells the handlers" do
    with_state do |db, server, detector|
      libdir = File.tempname("hub-lib")
      Dir.mkdir_p(File.join(libdir, "A/B (1)"))
      File.rename(sample(300_000), File.join(libdir, "A/B (1)/B - A.epub"))
      library_fixture(libdir)
      server.books[1_i64] = {"B", ["EPUB", "TXT"], true}
      e = CalibreHub::Embedder.new(db, server.calibre, libdir, 60.seconds, detector)
      e.follow_events # nothing yet; the cursor starts at 0
      t0 = Time.utc
      event(db, "changed", 1, change("title", "A", "B"))
      event(db, "changed", 1, change("lastModified", "x", "y"))
      e.follow_events(t0)
      event(db, "changed", 1, change("authors", ["X"], ["Y"]))
      e.follow_events(t0 + 30.seconds)
      e.pending.should eq(1)
      # due 60 s after the last edit
      e.run_due(t0 + 80.seconds).should eq(0)
      e.run_due(t0 + 91.seconds).should eq(1)
      e.pending.should eq(0)
      embeds = server.requests.select { |p, _| p == "/cdb/cmd/embed_metadata/0" }
      embeds.map(&.[1]).should eq([JSON.parse(%([1, ["epub"]]))])
      db.query_one("select format || ' ' || partial_md5 from file_checksums where book_id = 1", as: String)
        .should eq("EPUB 7b136e8f07380b5ca82c093c325dfd79")
      # the nudge for the reading list: formats the same on both sides
      payload = db.query_one("select payload from events order by id desc limit 1", as: String)
      JSON.parse(payload)["changes"].should eq(JSON.parse(%({"formats": [["EPUB", "TXT"], ["EPUB", "TXT"]]})))
      # ... which the embedder itself ignores
      e.follow_events(t0 + 100.seconds)
      e.pending.should eq(0)

      # the same metadata again: nothing to do, unless forced (a new cover)
      e.embed(1).should eq("unchanged")
      e.embed(1, force: true).should start_with("embedded")
      e.enqueue(9, now: t0)
      event(db, "deleted", 9)
      e.follow_events(t0)
      e.pending.should eq(0)
    ensure
      FileUtils.rm_rf(libdir) if libdir
    end
  end

  it "skips formats calibre can't write and rewrites coverless books through downloads" do
    with_state do |db, server, detector|
      e = CalibreHub::Embedder.new(db, server.calibre, nil, 1.second, detector)
      server.books[2_i64] = {"Comic", ["CBZ"], true}
      e.embed(2).should start_with("skipped")
      server.books[3_i64] = {"Ohne Cover", ["EPUB", "DOCX"], false}
      e.embed(3).should eq("embedded into EPUB")
      server.paths.should contain("/get/epub/3")
      server.paths.should contain("/cdb/set-fields/3")
      server.paths.should_not contain("/cdb/cmd/embed_metadata/0")
    end
  end
end

# metadata.db with just what the embedder reads
private def library_fixture(libdir)
  db = DB.open("sqlite3://#{File.join(libdir, "metadata.db")}")
  db.exec "create table books (id integer primary key, path text)"
  db.exec "create table data (id integer primary key, book integer, format text, name text)"
  db.exec "insert into books values (1, 'A/B (1)')"
  db.exec "insert into data (book, format, name) values (1, 'EPUB', 'B - A'), (1, 'TXT', 'B - A')"
  db.close
end

describe CalibreHub::ConvertJobs do
  it "picks a source format" do
    ignore = %w(PDF CBZ CBR)
    CalibreHub::ConvertJobs.source(["TXT"], "EPUB", ignore).should eq("TXT")
    CalibreHub::ConvertJobs.source(["TXT", "DOCX"], "EPUB", ignore).should eq("DOCX")
    CalibreHub::ConvertJobs.source(["EPUB", "TXT"], "EPUB", ignore).should be_nil
    CalibreHub::ConvertJobs.source(["PDF", "CBZ"], "EPUB", ignore).should be_nil
    CalibreHub::ConvertJobs.source(["PDF"], "EPUB", [] of String).should eq("PDF")
    CalibreHub::ConvertJobs.source(["EPUB"], "AZW3", ignore).should eq("EPUB")
    CalibreHub::ConvertJobs.target!(nil, "EPUB").should eq("EPUB")
    CalibreHub::ConvertJobs.target!(JSON::Any.new("azw3"), "EPUB").should eq("AZW3")
    expect_raises(CalibreHub::Edit::Invalid) { CalibreHub::ConvertJobs.target!(JSON::Any.new("exe"), "EPUB") }
  end

  it "converts added books and the library, keeping the original" do
    with_state do |db, server, detector|
      bin = File.tempname("fake-bin")
      Dir.mkdir_p(bin)
      File.write(File.join(bin, "ebook-convert"), "#!/bin/sh\ncp \"$1\" \"$2\"\n")
      File.chmod(File.join(bin, "ebook-convert"), 0o755)
      old_path = ENV["PATH"]
      ENV["PATH"] = "#{bin}:#{old_path}"
      server.books[1_i64] = {"Text", ["TXT"], true}
      server.books[2_i64] = {"Fertig", ["EPUB", "TXT"], true}
      server.books[3_i64] = {"Comic", ["CBZ"], true}
      writer = CalibreHub::Writer.new(server.calibre, nil, nil, nil)
      jobs = CalibreHub::ConvertJobs.new(db, server.calibre, writer, "epub", %w(pdf cbz cbr), true)
      jobs.follow_events
      book = ->(id : Int32) { JSON.parse({formats: server.books[id.to_i64][1]}.to_json) }
      event(db, "added", 1, book: book.call(1))
      event(db, "added", 2, book: book.call(2))
      event(db, "added", 3, book: book.call(3))
      jobs.follow_events
      job = jobs.last.not_nil![0]
      job.total.should eq(1)
      200.times { break unless jobs.running?; sleep 10.milliseconds }
      jobs[job.id]?.not_nil!.status.should eq("done")
      server.paths.should contain("/get/txt/1")
      added = server.requests.find { |p, _| p == "/cdb/set-fields/1" }.not_nil![1]
      added["changes"]["added_formats"][0]["ext"].should eq("epub")
      Base64.decode_string(added["changes"]["added_formats"][0]["data_url"].as_s).should eq("file /get/txt/1")

      # the library: every book without EPUB that has something to convert
      jobs.submit_target(nil).total.should eq(1)
      jobs.submit_target(JSON::Any.new("azw3")).total.should eq(2)
      # some books only (the command palette's selection)
      jobs.submit_target(nil, JSON.parse(%({"ids": [2, 3]}))).total.should eq(0)
      jobs.submit_target(JSON::Any.new("azw3"), JSON.parse(%({"ids": [2, 3]}))).total.should eq(1)
    ensure
      ENV["PATH"] = old_path if old_path
      FileUtils.rm_rf(bin) if bin
    end
  end
end
