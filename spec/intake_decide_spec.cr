require "spec"
require "file_utils"
require "http/server"
require "../src/calibre_hub/intake"

private alias Meta = CalibreHub::Meta
private alias Backlog = CalibreHub::Backlog
private alias Intake = CalibreHub::Intake
private alias IntakeTrash = CalibreHub::IntakeTrash

private def write(path : String, content : String, age = 1.hour)
  Dir.mkdir_p(File.dirname(path))
  File.write(path, content)
  time = Time.utc - age
  File.utime(time, time, path)
end

private def pdf(text = "x") : String
  "%PDF-1.4\n" + text + ("." * 4000)
end

private def opf(title : String, author : String) : String
  <<-XML
  <?xml version='1.0' encoding='utf-8'?>
  <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
    <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
      <dc:title>#{title}</dc:title>
      <dc:creator opf:role="aut">#{author}</dc:creator>
      <dc:subject>Fiction</dc:subject>
    </metadata>
  </package>
  XML
end

# calibre-server for decisions: it adds books, sets fields and lists them
private class FakeCalibre
  getter books = {} of Int64 => Hash(String, JSON::Any)
  getter requests = [] of {String, JSON::Any}
  getter url : String
  property down = false
  # add-book answers these file names as duplicates of the book
  property duplicate_names = {} of String => Int64
  @next = 100_i64

  def initialize
    @server = HTTP::Server.new do |ctx|
      path = ctx.request.path
      ctx.response.content_type = "application/json"
      if @down
        ctx.response.status_code = 503
        next
      end
      if path.starts_with?("/cdb/add-book/")
        ctx.request.body.try(&.gets_to_end)
        name = URI.decode(path.split('/')[5])
        @requests << {"add-book", JSON::Any.new(name)}
        if (dup = @duplicate_names[name]?) && path.split('/')[4] == "n"
          b = @books[dup]
          ctx.response.print({duplicates: [{title: b["title"], authors: b["authors"]}]}.to_json)
        else
          id = (@next += 1)
          read = Meta::FileName.calibre(name)
          add(id, read[0], read[1], [File.extname(name).lchop('.').upcase], tags: ["embedded"])
          ctx.response.print({book_id: id}.to_json)
        end
        next
      end
      body = JSON.parse(ctx.request.body.try(&.gets_to_end).presence || "null")
      @requests << {path, body}
      case path
      when %r{^/cdb/set-fields/(\d+)}
        b = @books[$1.to_i64]
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
        m = body[3].as_s.scan(/id:(\d+)/)
        ids = m.empty? ? @books.keys : m.map(&.[1].to_i64).select { |i| @books.has_key?(i) }
        data = fields.to_h { |f| {f.sub('*', '#'), ids.to_h { |i| {i.to_s, @books[i][f.sub('*', '#')]? || JSON::Any.new(nil)} }} }
        ctx.response.print({result: {book_ids: ids, data: data}}.to_json)
      when "/ajax/search"
        title = ctx.request.query_params["query"][/title:"=([^"]+)"/, 1]?
        ids = @books.select { |_, b| b["title"].as_s == title }.keys
        ctx.response.print({total_num: ids.size, book_ids: ids}.to_json)
      else
        ctx.response.status_code = 404
      end
    end
    @url = "http://127.0.0.1:#{@server.bind_tcp("127.0.0.1", 0).port}"
    spawn { @server.listen }
  end

  def add(id : Int64, title : String, authors : Array(String), formats = ["PDF"], tags = [] of String)
    @books[id] = {"title" => JSON::Any.new(title), "authors" => JSON.parse(authors.to_json),
                  "formats" => JSON.parse(formats.to_json), "tags" => JSON.parse(tags.to_json),
                  "identifiers" => JSON.parse("{}")}
  end

  def fields(id : Int64) : JSON::Any
    @requests.reverse.find! { |r| r[0].starts_with?("/cdb/set-fields/#{id}") && r[1]["changes"]["added_formats"]?.nil? }[1]["changes"]
  end

  def added : Array(String)
    @requests.select { |r| r[0] == "add-book" }.map(&.[1].as_s)
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

# A library folder as calibre keeps it: book -> {folder, name, format, content}
private def library(dir : String, files : Hash(Int64, {String, String, String, String})) : String
  shelf = File.join(dir, "library")
  Dir.mkdir_p(shelf)
  db = DB.open("sqlite3://#{File.join(shelf, "metadata.db")}")
  db.exec "create table books (id integer primary key, path text)"
  db.exec "create table data (book integer, name text, format text, uncompressed_size integer)"
  files.each do |id, (folder, name, format, content)|
    write(File.join(shelf, folder, "#{name}.#{format.downcase}"), content)
    db.exec "insert into books (id, path) values (?, ?)", id, folder
    db.exec "insert into data (book, name, format, uncompressed_size) values (?, ?, ?, ?)", id, name, format, content.bytesize
  end
  db.close
  shelf
end

private def setup(root : String, fake = FakeCalibre.new, shelf : String? = nil, db = state_db)
  calibre = fake.calibre
  writer = CalibreHub::Writer.new(calibre, nil, nil, "kategorie")
  imports = CalibreHub::Importer.new(db, calibre, writer, [root], shelf, retries: 0)
  intake = Intake.new(db, calibre, imports, shelf, File.join(root, ".covers"), stable: 0.seconds, pause: 0.seconds, wait: 10.milliseconds)
  intake.cover_reader = ->(_path : String, _format : String, _target : String) { false }
  intake.reader = ->(path : String, _format : String) do
    Meta::FileMeta::Info.new(Meta::Record.new, [] of String, front: "", format: "PDF").as(Meta::FileMeta::Info?)
  end
  {intake, fake, db, imports}
end

private def tmpdir(&)
  dir = File.tempname("intake")
  Dir.mkdir_p(dir)
  begin
    yield File.realpath(dir), File.join(File.realpath(dir), "backlog")
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def entries(intake : Intake, **filter) : Array(JSON::Any)
  intake.list(**filter)["entries"].as_a
end

private def id_of(intake : Intake, name : String) : Int64
  entries(intake).find! { |e| e["name"] == name }["id"].as_i64
end

private def decide(intake : Intake, ids : Array(Int64), decision : String, **extra) : JSON::Any
  body = JSON.parse({target: {ids: ids}, decision: decision}.merge(extra).to_json).as_h
  intake.decide(body)[1]
end

private def wait(intake : Intake, result : JSON::Any) : CalibreHub::Jobs::Job
  id = result["jobId"].as_s
  300.times do
    j = intake.decisions[id]?.not_nil!
    return j unless j.status == "running"
    sleep 10.milliseconds
  end
  raise "job #{id} still running"
end

private def settled(intake : Intake)
  300.times do
    return unless intake.decisions.running?
    sleep 10.milliseconds
  end
  raise "decisions still running"
end

describe CalibreHub::BookFiles do
  it "tells files of one size apart, also where a partial MD5 doesn't look" do
    tmpdir do |dir, _|
      a, b, c = File.join(dir, "a"), File.join(dir, "b"), File.join(dir, "c")
      content = "x" * 5000
      File.write(a, content)
      File.write(b, content)
      # byte 3000 is between what the partial MD5 reads
      File.write(c, content.sub(3000, 'y'))
      CalibreHub::BookFiles.partial_md5(a).should eq CalibreHub::BookFiles.partial_md5(c)
      CalibreHub::BookFiles.same_content?(a, b).should be_true
      CalibreHub::BookFiles.same_content?(a, c).should be_false
      CalibreHub::BookFiles.same_content?(a, a).should be_false
      CalibreHub::BookFiles.same_content?(a, File.join(dir, "gone")).should be_false
    end
  end
end

describe IntakeTrash do
  it "moves a file under its path in the root, next to the root" do
    tmpdir do |_, root|
      write(File.join(root, "Fach/a.pdf"), "a")
      moved = IntakeTrash.move([root], [File.join(root, "Fach/a.pdf")])
      moved.should eq ["#{root}-papierkorb/Fach/a.pdf"]
      File.read(moved.first).should eq "a"
      File.exists?(File.join(root, "Fach/a.pdf")).should be_false
    end
  end

  it "never overwrites what is in the folder" do
    tmpdir do |_, root|
      write(File.join(root, "a.pdf"), "new")
      write("#{root}-papierkorb/a.pdf", "old")
      write("#{root}-papierkorb/a (2).pdf", "older")
      moved = IntakeTrash.move([root], [File.join(root, "a.pdf")])
      moved.should eq ["#{root}-papierkorb/a (3).pdf"]
      File.read("#{root}-papierkorb/a.pdf").should eq "old"
      File.read("#{root}-papierkorb/a (2).pdf").should eq "older"
      File.read(moved.first).should eq "new"
    end
  end

  it "takes nothing outside its roots" do
    tmpdir do |dir, root|
      write(File.join(dir, "other/a.pdf"), "a")
      expect_raises(File::Error) { IntakeTrash.move([root], [File.join(dir, "other/a.pdf")]) }
      expect_raises(File::Error) { IntakeTrash.move([root], [root]) }
      File.exists?(File.join(dir, "other/a.pdf")).should be_true
    end
  end
end

describe CalibreHub::IntakeJobs do
  it "accepts the proposal through the import, and the import leaves the file alone" do
    tmpdir do |_, root|
      write(File.join(root, "Frank Herbert - Dune (Chilton, 1965).pdf"), pdf("dune"))
      intake, fake, db, imports = setup(root)
      intake.run_once
      e = entries(intake).first
      e["proposal"]["title"].should eq "Dune"

      r = decide(intake, [e["id"].as_i64], "accept")
      # it left the list before its job got anywhere
      entries(intake).should be_empty
      wait(intake, r).errors.should be_empty

      fake.added.should eq ["Frank Herbert - Dune (Chilton, 1965).pdf"]
      id = fake.books.keys.max
      fake.books[id]["title"].should eq "Dune"
      fake.books[id]["authors"].as_a.map(&.as_s).should eq ["Frank Herbert"]
      fake.books[id]["tags"].as_a.should be_empty
      fake.books[id]["publisher"].should eq "Chilton"
      imports.known.keys.should eq [File.join(root, "Frank Herbert - Dune (Chilton, 1965).pdf")]
      db.query_one("select status from import_files", as: String).should eq "imported"
      File.exists?(File.join(root, "Frank Herbert - Dune (Chilton, 1965).pdf")).should be_true
      # the next pass neither brings it back nor adds it again
      intake.run_once.should eq 0
      entries(intake).should be_empty
    end
  end

  it "takes a file as it is, without the proposal" do
    tmpdir do |_, root|
      write(File.join(root, "Frank Herbert - Dune (Chilton, 1965).pdf"), pdf("dune"))
      intake, fake, db, imports = setup(root)
      log = CalibreHub::MetaLog.new(db)
      imports.decisions = log
      intake.run_once
      r = decide(intake, [entries(intake).first["id"].as_i64], "file")
      wait(intake, r).errors.should be_empty
      id = fake.books.keys.max
      fake.fields(id).as_h.keys.should eq ["tags"]
      fake.books[id]["publisher"]?.should be_nil
      log.decided(id).not_nil!.binding?.should be_true
    end
  end

  it "accepts a candidate, and edited values over it" do
    tmpdir do |_, root|
      write(File.join(root, "a.pdf"), pdf("a"))
      write(File.join(root, "b.pdf"), pdf("b"))
      intake, fake, db, _ = setup(root)
      intake.run_once
      a, b = id_of(intake, "a.pdf"), id_of(intake, "b.pdf")
      db.exec "delete from intake_candidates"
      db.exec "insert into intake_candidates (entry_id, idx, source, confidence, fields) values (?, 0, 'dnb', 70, ?)",
        a, Meta::Record.new(title: "Aus dem Katalog", authors: ["Kat Alog"], publisher: "Verlag").to_json
      expect_raises(CalibreHub::Edit::Invalid, /no such candidate/) { decide(intake, [b], "accept", candidate: 0) }
      expect_raises(CalibreHub::Edit::Invalid, /at least one author/) { decide(intake, [b], "accept", authors: [" "]) }
      expect_raises(CalibreHub::Edit::Invalid, /only for one/) { decide(intake, [a, b], "accept", title: "x") }
      wait(intake, decide(intake, [a], "accept", candidate: 0)).errors.should be_empty
      id = fake.books.keys.max
      fake.books[id]["title"].should eq "Aus dem Katalog"
      fake.books[id]["publisher"].should eq "Verlag"

      wait(intake, decide(intake, [b], "accept", title: " Von Hand ", authors: ["Ann Other"])).errors.should be_empty
      id = fake.books.keys.max
      fake.books[id]["title"].should eq "Von Hand"
      fake.books[id]["authors"].as_a.map(&.as_s).should eq ["Ann Other"]
    end
  end

  it "keeps title and authors a person accepted from the metadata run" do
    tmpdir do |_, root|
      write(File.join(root, "Frank Herbert - Dune.pdf"), pdf("dune"))
      intake, fake, db, imports = setup(root)
      log = CalibreHub::MetaLog.new(db)
      imports.decisions = log
      intake.run_once
      wait(intake, decide(intake, [entries(intake).first["id"].as_i64], "accept")).errors.should be_empty
      log.decided(fake.books.keys.max).not_nil!.binding?.should be_true
    end
  end

  it "adds a format to the book the file belongs to" do
    tmpdir do |_, root|
      write(File.join(root, "Dune (7)/Dune.mobi"), ("\0" * 60) + "BOOKMOBI" + ("." * 4000))
      write(File.join(root, "Dune (7)/metadata.opf"), opf("Dune", "Frank Herbert"))
      fake = FakeCalibre.new
      fake.add(1_i64, "Dune", ["Frank Herbert"], ["EPUB"])
      intake, _, _, imports = setup(root, fake)
      intake.run_once
      e = entries(intake).first
      e["action"].should eq "addFormats"
      wait(intake, decide(intake, [e["id"].as_i64], "accept")).errors.should be_empty
      fake.added.should be_empty
      fake.books[1_i64]["formats"].as_a.map(&.as_s).should eq ["EPUB", "MOBI"]
      imports.known.values.first[3].should eq 1_i64
    end
  end

  it "adds a marked duplicate only because a person says so" do
    tmpdir do |_, root|
      write(File.join(root, "Frank Herbert - Dune.pdf"), pdf("dune"))
      fake = FakeCalibre.new
      fake.add(1_i64, "Dune", ["Frank Herbert"])
      intake, _, _, _ = setup(root, fake)
      intake.run_once
      e = entries(intake).first
      e["action"].should eq "duplicate"
      e["bookTitle"].should eq "Dune"
      list = intake.list
      list["takeable"].should eq 0
      wait(intake, decide(intake, [e["id"].as_i64], "accept")).errors.should be_empty
      fake.added.should eq ["Frank Herbert - Dune.pdf"]
      fake.books.size.should eq 2
    end
  end

  it "brings a book back marked when it turns out to be in the library" do
    tmpdir do |_, root|
      write(File.join(root, "a.pdf"), pdf("a"))
      fake = FakeCalibre.new
      fake.add(1_i64, "Schon da", ["Wer"])
      fake.duplicate_names["a.pdf"] = 1_i64
      intake, _, _, imports = setup(root, fake)
      intake.run_once
      id = entries(intake).first["id"].as_i64
      fake.books[1_i64]["formats"] = JSON.parse(%(["PDF"]))
      wait(intake, decide(intake, [id], "accept"))
      e = entries(intake).first
      e["action"].should eq "duplicate"
      e["bookId"].should eq 1
      imports.known.should be_empty
      fake.books.size.should eq 1
    end
  end

  it "skips: the entry stays, no bulk asks it, until it is taken back" do
    tmpdir do |_, root|
      write(File.join(root, "a.pdf"), pdf("a"))
      write(File.join(root, "b.pdf"), pdf("b"))
      intake, fake, _, _ = setup(root)
      intake.run_once
      a = id_of(intake, "a.pdf")
      intake.decide(JSON.parse({target: {ids: [a]}, decision: "skip"}.to_json).as_h)[0].should eq 200
      list = intake.list
      list["entries"].as_a.size.should eq 2
      list["entries"].as_a.find! { |e| e["id"] == a }["skipped"].should eq true
      list["takeable"].should eq 1
      list["skipped"].should eq 1
      entries(intake, skipped: true).map(&.["id"].as_i64).should eq [a]
      intake.list(skipped: true)["takeable"].should eq 1
      fake.added.should be_empty
      intake.run_once.should eq 0
      intake.list["skipped"].should eq 1

      decide(intake, [a], "unskip")
      intake.list["takeable"].should eq 2
      intake.list["skipped"].should eq 0
    end
  end

  it "moves a file to the trash folder, nothing to the library" do
    tmpdir do |_, root|
      write(File.join(root, "Fach/a.pdf"), pdf("a"))
      write(File.join(root, "Fach/a.epub"), "PK" + ("." * 4000))
      write(File.join(root, "Fach/notes.txt"), "stays")
      intake, fake, _, imports = setup(root)
      intake.run_once
      e = entries(intake).first
      e["files"].as_a.size.should eq 2
      wait(intake, decide(intake, [e["id"].as_i64], "trash")).errors.should be_empty
      File.exists?("#{root}-papierkorb/Fach/a.pdf").should be_true
      File.exists?("#{root}-papierkorb/Fach/a.epub").should be_true
      File.exists?(File.join(root, "Fach/a.pdf")).should be_false
      File.exists?(File.join(root, "Fach/notes.txt")).should be_true
      entries(intake).should be_empty
      fake.added.should be_empty
      imports.known.should be_empty
      intake.run_once.should eq 0
    end
  end

  it "moves a calibre folder as a whole" do
    tmpdir do |_, root|
      folder = File.join(root, "Frank Herbert/Dune (7)")
      write(File.join(folder, "Dune.pdf"), pdf("a"))
      write(File.join(folder, "metadata.opf"), opf("Dune", "Frank Herbert"))
      write(File.join(folder, "cover.jpg"), "jpg")
      intake, _, _, _ = setup(root)
      intake.run_once
      wait(intake, decide(intake, [entries(intake).first["id"].as_i64], "trash")).errors.should be_empty
      Dir.exists?(folder).should be_false
      Dir.children("#{root}-papierkorb/Frank Herbert/Dune (7)").sort.should eq ["Dune.pdf", "cover.jpg", "metadata.opf"]
    end
  end

  it "keeps an entry whose move failed, with the reason" do
    tmpdir do |_, root|
      write(File.join(root, "a.pdf"), pdf("a"))
      write("#{root}-papierkorb", "a file where the folder belongs")
      intake, _, _, _ = setup(root)
      intake.run_once
      r = decide(intake, [entries(intake).first["id"].as_i64], "trash")
      wait(intake, r).errors.size.should eq 1
      e = entries(intake).first
      e["error"].as_s.should_not be_empty
      File.exists?(File.join(root, "a.pdf")).should be_true
    end
  end

  it "takes a filter across pages, only what it says" do
    tmpdir do |_, root|
      5.times { |i| write(File.join(root, "Jane Doe - Book #{i}.pdf"), pdf(i.to_s)) }
      write(File.join(root, "Frank Herbert - Dune.pdf"), pdf("dune"))
      write(File.join(root, "z.pdf"), pdf("z"))
      fake = FakeCalibre.new
      fake.add(1_i64, "Dune", ["Frank Herbert"])
      intake, _, db, _ = setup(root, fake)
      intake.run_once
      db.exec "update intake_entries set status = 'failed', proposal = null, confidence = null where path like '%z.pdf'"
      skipped = id_of(intake, "Jane Doe - Book 0.pdf")
      decide(intake, [skipped], "skip")
      list = intake.list(limit: 1)
      list["total"].should eq 7
      list["takeable"].should eq 4
      list["unsure"].should eq 0
      expect_raises(CalibreHub::Edit::Invalid, /expect/) do
        intake.decide(JSON.parse({target: {query: {} of String => String}, decision: "accept"}.to_json).as_h)
      end
      expect_raises(CalibreHub::Edit::Invalid, /only accept/) do
        intake.decide(JSON.parse({target: {query: {} of String => String, expect: 4, last: 99}, decision: "trash"}.to_json).as_h)
      end
      expect_raises(CalibreHub::Jobs::CountMismatch) do
        intake.decide(JSON.parse({target: {query: {} of String => String, expect: 5, last: list["last"]}, decision: "accept"}.to_json).as_h)
      end
      # what the analysis adds after the page was shown doesn't count
      db.exec "insert into intake_entries (path, kind, files, status, proposal, confidence, action, at) " \
              "select path || '.new', kind, files, status, proposal, 99, action, at from intake_entries where id = ?", skipped
      status, r = intake.decide(JSON.parse({target: {query: {} of String => String, expect: 4, last: list["last"]}, decision: "accept"}.to_json).as_h)
      status.should eq 202
      r["total"].should eq 4
      intake.list["pending"].should eq 4
      wait(intake, r).errors.should be_empty
      fake.added.size.should eq 4
      fake.added.should_not contain "Jane Doe - Book 0.pdf"
      intake.list["total"].should eq 4
    end
  end

  it "pages behind a path, also while entries leave" do
    tmpdir do |_, root|
      %w(a b c d).each { |n| write(File.join(root, "#{n}.pdf"), pdf(n)) }
      intake, _, _, _ = setup(root)
      intake.run_once
      one = intake.list(limit: 2)
      one["entries"].as_a.map(&.["name"].as_s).should eq ["a.pdf", "b.pdf"]
      decide(intake, [id_of(intake, "a.pdf")], "trash")
      two = intake.list(limit: 2, after: one["next"].as_s)
      two["entries"].as_a.map(&.["name"].as_s).should eq ["c.pdf", "d.pdf"]
      two["next"].raw.should be_nil
      settled(intake)
    end
  end

  it "gives entries back when calibre-server is down" do
    tmpdir do |_, root|
      write(File.join(root, "a.pdf"), pdf("a"))
      write(File.join(root, "b.pdf"), pdf("b"))
      intake, fake, _, _ = setup(root)
      intake.run_once
      fake.down = true
      r = decide(intake, entries(intake).map(&.["id"].as_i64), "accept")
      wait(intake, r).status.should eq "failed"
      fake.down = false
      list = entries(intake)
      list.size.should eq 2
      list.first["error"].as_s.should contain "unavailable"
    end
  end

  it "drops an entry whose file changed while it waited" do
    tmpdir do |_, root|
      write(File.join(root, "a.pdf"), pdf("a"))
      intake, fake, _, _ = setup(root)
      intake.run_once
      id = entries(intake).first["id"].as_i64
      write(File.join(root, "a.pdf"), pdf("changed a lot"))
      wait(intake, decide(intake, [id], "accept")).errors.should be_empty
      fake.added.should be_empty
      intake.run_once.should eq 1
      entries(intake).size.should eq 1
    end
  end
end

describe "the threshold" do
  it "is off by default and takes what is at or above it" do
    tmpdir do |_, root|
      write(File.join(root, "Frank Herbert - Dune.pdf"), pdf("dune"))
      write(File.join(root, "x.pdf"), pdf("x"))
      fake = FakeCalibre.new
      fake.add(1_i64, "Kinder", ["Wer Auch"])
      intake, _, db, _ = setup(root, fake)
      intake.run_once
      intake.threshold.should be_nil
      fake.added.should be_empty
      db.exec "update intake_entries set confidence = 99"
      db.exec "update intake_entries set action = 'duplicate' where path like '%x.pdf'"

      intake.set_threshold("backlog", 90)
      settled(intake)
      intake.threshold.should eq 90
      fake.added.should eq ["Frank Herbert - Dune.pdf"]
      entries(intake).size.should eq 1
    end
  end

  it "takes new entries after their analysis, not what was skipped or failed" do
    tmpdir do |_, root|
      write(File.join(root, "Frank Herbert - Dune.pdf"), pdf("dune"))
      intake, fake, _, _ = setup(root)
      intake.set_threshold("backlog", 60)
      intake.run_once
      settled(intake)
      fake.added.size.should eq 1

      write(File.join(root, "Jane Doe - Zwei.pdf"), pdf("zwei"))
      intake.set_threshold("backlog", nil)
      intake.run_once
      id = id_of(intake, "Jane Doe - Zwei.pdf")
      decide(intake, [id], "skip")
      intake.set_threshold("backlog", 60)
      settled(intake)
      fake.added.size.should eq 1
      entries(intake).size.should eq 1
    end
  end
end

describe "exact duplicates" do
  it "go to the trash folder when every byte is in the library" do
    tmpdir do |dir, root|
      write(File.join(root, "Fach/copy.pdf"), pdf("same"))
      shelf = library(dir, {1_i64 => {"Wer/Buch (1)", "Buch - Wer", "PDF", pdf("same")}})
      fake = FakeCalibre.new
      fake.add(1_i64, "Buch", ["Wer"])
      intake, _, _, _ = setup(root, fake, shelf)
      intake.run_once
      entries(intake).should be_empty
      fake.added.should be_empty
      File.exists?("#{root}-papierkorb/Fach/copy.pdf").should be_true
      File.exists?(File.join(shelf, "Wer/Buch (1)/Buch - Wer.pdf")).should be_true
    end
  end

  it "stay in the list when only size and partial MD5 are the same" do
    tmpdir do |dir, root|
      same = pdf("same")
      other = same.sub(3000, 'y')
      write(File.join(root, "copy.pdf"), other)
      CalibreHub::BookFiles.partial_md5(File.join(root, "copy.pdf")).should eq begin
        File.write(File.join(dir, "p"), same)
        CalibreHub::BookFiles.partial_md5(File.join(dir, "p"))
      end
      shelf = library(dir, {1_i64 => {"Wer/Buch (1)", "Buch - Wer", "PDF", same}})
      fake = FakeCalibre.new
      fake.add(1_i64, "Buch", ["Wer"])
      intake, _, _, _ = setup(root, fake, shelf)
      intake.run_once
      e = entries(intake).first
      e["action"].should eq "duplicate"
      e["match"].should eq "file"
      e["bookId"].should eq 1
      e["bookTitle"].should eq "Buch"
      File.exists?(File.join(root, "copy.pdf")).should be_true
      Dir.exists?("#{root}-papierkorb").should be_false
    end
  end

  it "stay in the list when one file of the unit is new" do
    tmpdir do |dir, root|
      write(File.join(root, "a.pdf"), pdf("same"))
      write(File.join(root, "a.epub"), "PK" + ("." * 4000))
      shelf = library(dir, {1_i64 => {"Wer/Buch (1)", "Buch - Wer", "PDF", pdf("same")}})
      fake = FakeCalibre.new
      fake.add(1_i64, "Buch", ["Wer"])
      intake, _, _, _ = setup(root, fake, shelf)
      intake.run_once
      entries(intake).size.should eq 1
      File.exists?(File.join(root, "a.pdf")).should be_true
    end
  end

  it "stay in the list when a calibre folder holds more than the book" do
    tmpdir do |dir, root|
      folder = File.join(root, "Buch (1)")
      write(File.join(folder, "a.pdf"), pdf("same"))
      write(File.join(folder, "metadata.opf"), opf("Buch", "Wer"))
      write(File.join(folder, "notes.txt"), "mine")
      shelf = library(dir, {1_i64 => {"Wer/Buch (1)", "Buch - Wer", "PDF", pdf("same")}})
      fake = FakeCalibre.new
      fake.add(1_i64, "Buch", ["Wer"])
      intake, _, _, _ = setup(root, fake, shelf)
      intake.run_once
      entries(intake).size.should eq 1
      Dir.exists?(folder).should be_true
    end
  end

  it "are found among entries analysed before, and a failed move leaves them" do
    tmpdir do |dir, root|
      write(File.join(root, "copy.pdf"), pdf("same"))
      fake = FakeCalibre.new
      db = state_db
      intake, _, _, _ = setup(root, fake, nil, db)
      intake.run_once
      entries(intake).size.should eq 1

      shelf = library(dir, {1_i64 => {"Wer/Buch (1)", "Buch - Wer", "PDF", pdf("same")}})
      fake.add(1_i64, "Buch", ["Wer"])
      write("#{root}-papierkorb", "in the way")
      later, _, _, _ = setup(root, fake, shelf, db)
      later.run_once
      entries(later).size.should eq 1

      File.delete("#{root}-papierkorb")
      later.run_once
      entries(later).should be_empty
      File.exists?("#{root}-papierkorb/copy.pdf").should be_true
    end
  end
end

private def repair_of(fake : FakeCalibre, db : DB::Database) : CalibreHub::ImportRepair
  calibre = fake.calibre
  CalibreHub::ImportRepair.new(db, calibre, CalibreHub::Writer.new(calibre, nil, nil, "kategorie"), CalibreHub::MetaLog.new(db))
end

private def proposal_row(db : DB::Database, id : Int64, changes : String, confidence = 80, status = "pending", file = "")
  db.exec "insert into import_repairs (book_id, file, decided, changes, status, at, confidence, level, source, notes) values (?, ?, 'name', ?, ?, 100, ?, 3, 'rules', '[]')",
    id, file, changes, status, confidence
end

private def title_change(old : String, new : String) : String
  [{field: "title", old: old, new: new, source: "rules"}].to_json
end

private def repair_settled(repair : CalibreHub::ImportRepair)
  500.times do
    return unless repair.running?
    sleep 10.milliseconds
  end
  raise "repair still running"
end

private def recheck_done(recheck : CalibreHub::RepairRecheck)
  500.times do
    return unless recheck.running?
    sleep 10.milliseconds
  end
  raise "recheck still running"
end

private def library_entries(intake : Intake, band = nil) : Array(JSON::Any)
  intake.library_list(band)["entries"].as_a
end

private def imported(db : DB::Database, path : String, id : Int64, run = "r")
  db.exec "insert into import_files (path, size, mtime, status, book_id, run_id, at) values (?, 1, 1, 'imported', ?, ?, 100)", path, id, run
end

describe "a chosen candidate" do
  it "writes what the candidate says, however low its confidence, and nothing of the proposal's book" do
    tmpdir do |_, root|
      write(File.join(root, "a.pdf"), pdf("a"))
      intake, fake, db, imports = setup(root)
      log = CalibreHub::MetaLog.new(db)
      imports.decisions = log
      intake.run_once
      a = id_of(intake, "a.pdf")
      proposal = Intake::Proposal.new("Falsches Buch", ["Falsche Autorin"], "Falscher Verlag", "1999", "Falsche Reihe", 1.0, "9780000000002", ["eng"])
      db.exec "update intake_entries set proposal = ?, level = 1, confidence = 20, title_confidence = 20, authors_confidence = 20, " \
              "changes = ?, notes = ? where id = ?", proposal.to_json,
        [{field: "tags", old: [] of String, new: ["auto-unsicher"], source: "rules"}].to_json,
        [{kind: "isbnConflict", isbn: "9780000000002", books: [] of Int64}].to_json, a
      db.exec "delete from intake_candidates where entry_id = ?", a
      db.exec "insert into intake_candidates (entry_id, idx, source, confidence, fields) values (?, 0, 'name', 10, ?)",
        a, Meta::Record.new(title: "Richtiges Buch", authors: ["Richtige Autorin"]).to_json
      wait(intake, decide(intake, [a], "accept", candidate: 0)).errors.should be_empty
      id = fake.books.keys.max
      fake.books[id]["title"].should eq "Richtiges Buch"
      fake.books[id]["authors"].as_a.map(&.as_s).should eq ["Richtige Autorin"]
      fake.books[id]["publisher"]?.try(&.raw).should be_nil
      fake.books[id]["tags"].as_a.should be_empty
      decided = log.decided(id).not_nil!
      {decided.title_confidence, decided.authors_confidence, decided.source}.should eq({100, 100, "name"})
      decided.binding?.should be_true
      decided.isbn.should be_nil
      decided.notes.should be_empty
    end
  end

  it "keeps the proposal's title and authors where the candidate has none" do
    p = Intake::Proposal.new("Titel", ["Autorin"], "Verlag", nil, nil, nil, nil, [] of String)
    v = Intake.candidate_values(p, Meta::Record.new(publisher: "Anderer"))
    {v["title"], v["authors"][0], v["publisher"]}.should eq({"Titel", "Autorin", "Anderer"})
  end

  it "survives accepting the whole filter" do
    tmpdir do |_, root|
      write(File.join(root, "a.pdf"), pdf("a"))
      write(File.join(root, "b.pdf"), pdf("b"))
      intake, fake, db, _ = setup(root)
      intake.run_once
      a = id_of(intake, "a.pdf")
      db.exec "delete from intake_candidates where entry_id = ?", a
      db.exec "insert into intake_candidates (entry_id, idx, source, confidence, fields) values (?, 0, 'dnb', 40, ?)",
        a, Meta::Record.new(title: "Gewählt", authors: ["Kat Alog"]).to_json
      list = intake.list
      body = JSON.parse({decision: "accept", picks: {a.to_s => 0},
                         target: {query: {} of String => String, last: list["last"], expect: list["takeable"]}}.to_json).as_h
      wait(intake, intake.decide(body)[1]).errors.should be_empty
      fake.books.values.map(&.["title"].as_s).should contain "Gewählt"
      bad = JSON.parse({decision: "file", picks: {a.to_s => 0}, target: {ids: [a]}}.to_json).as_h
      expect_raises(CalibreHub::Edit::Invalid) { intake.decide(bad) }
    end
  end
end

describe "the list's order" do
  it "goes by confidence, then path, failed files last, a page staying right while the list moves" do
    tmpdir do |_, root|
      %w(a b c d e).each { |n| write(File.join(root, "#{n}.pdf"), pdf(n)) }
      intake, _, db, _ = setup(root)
      intake.run_once
      id = %w(a b c d e).to_h { |n| {n, id_of(intake, "#{n}.pdf")} }
      {"a" => 50, "b" => 90, "c" => 70, "d" => 90}.each { |n, c| db.exec "update intake_entries set confidence = ? where id = ?", c, id[n] }
      db.exec "update intake_entries set confidence = null, status = 'failed', proposal = null where id = ?", id["e"]
      names = ->(page : JSON::Any) { page["entries"].as_a.map(&.["name"].as_s.rchop(".pdf")) }
      names.call(intake.list).should eq %w(b d c a e)
      first = intake.list(limit: 2)
      names.call(first).should eq %w(b d)
      first["next"].as_s.should eq "90:#{File.join(root, "d.pdf")}"
      # what the page ended on left, and a surer one came in above it
      db.exec "delete from intake_entries where id = ?", id["d"]
      db.exec "update intake_entries set confidence = 95 where id = ?", id["a"]
      second = intake.list(limit: 1, after: first["next"].as_s)
      names.call(second).should eq %w(c)
      names.call(intake.list(limit: 5, after: second["next"].as_s)).should eq %w(e)
      expect_raises(CalibreHub::Edit::Invalid) { intake.list(after: "nonsense") }
    end
  end

  it "goes the same way in a bulk and for the library's books" do
    tmpdir do |_, root|
      %w(a b).each { |n| write(File.join(root, "#{n}.pdf"), pdf(n)) }
      fake = FakeCalibre.new
      {1_i64, 2_i64, 3_i64}.each { |i| fake.add(i, "Alt", ["Jemand"]) }
      intake, _, db, _ = setup(root, fake)
      repair = repair_of(fake, db)
      intake.repair = repair
      intake.run_once
      a, b = id_of(intake, "a.pdf"), id_of(intake, "b.pdf")
      db.exec "update intake_entries set confidence = 50 where id = ?", a
      db.exec "update intake_entries set confidence = 90 where id = ?", b
      list = intake.list
      job = wait(intake, intake.decide(JSON.parse({decision: "accept", target: {query: {} of String => String, last: list["last"], expect: 2}}.to_json).as_h)[1])
      job.ids.should eq [b, a]
      proposal_row(db, 1, title_change("Alt", "Neu"), 40)
      proposal_row(db, 2, title_change("Alt", "Neu"), 95)
      proposal_row(db, 3, title_change("Alt", "Neu"), 95)
      library_entries(intake).map(&.["bookId"].as_i).should eq [2, 3, 1]
      page = intake.library_list(limit: 2)
      page["next"].should eq "95:3"
      intake.library_list(after: page["next"].as_s)["entries"].as_a.map(&.["bookId"].as_i).should eq [1]
    end
  end
end

describe "what a bulk leaves in the list" do
  it "adds up with the filter" do
    tmpdir do |_, root|
      %w(a b c d).each { |n| write(File.join(root, "#{n}.pdf"), pdf(n)) }
      intake, _, db, _ = setup(root)
      intake.run_once
      db.exec "update intake_entries set action = 'duplicate' where id = ?", id_of(intake, "a.pdf")
      db.exec "update intake_entries set status = 'failed', proposal = null where id = ?", id_of(intake, "b.pdf")
      db.exec "update intake_entries set skipped = 1 where id = ?", id_of(intake, "c.pdf")
      list = intake.list
      {list["left"]["duplicates"], list["left"]["failed"], list["left"]["skipped"]}.should eq({1, 1, 1})
      list["takeable"].should eq 1
      intake.list(skipped: true)["left"]["skipped"].should eq 0
    end
  end
end

describe "reading in" do
  it "hands out only the entry's file, unchanged, inside a root" do
    tmpdir do |dir, root|
      write(File.join(root, "a.pdf"), pdf("a"))
      write(File.join(root, "b.djvu"), "AT&TFORM" + "." * 4000)
      write(File.join(root, "c.pdf"), pdf("c"))
      write(File.join(root, "d.pdf"), pdf("d"))
      write(File.join(dir, "secret.pdf"), pdf("secret"))
      intake, _, db, _ = setup(root)
      intake.run_once
      a, b, c, d = id_of(intake, "a.pdf"), id_of(intake, "b.djvu"), id_of(intake, "c.pdf"), id_of(intake, "d.pdf")
      intake.readable(a).not_nil!.path.should eq File.join(root, "a.pdf")
      intake.readable(a, "pdf").not_nil!.format.should eq "PDF"
      intake.readable(a, "EPUB").should be_nil
      intake.readable(b).should be_nil
      intake.readable(b, "DJVU").should be_nil
      intake.readable(-a).should be_nil
      intake.readable(99_999_i64).should be_nil
      # changed since the analysis
      File.write(File.join(root, "c.pdf"), "other")
      intake.readable(c).should be_nil
      # a link that leads out of the root
      info = File.info(File.join(root, "d.pdf"))
      File.delete(File.join(root, "d.pdf"))
      File.symlink(File.join(dir, "secret.pdf"), File.join(root, "d.pdf"))
      db.exec "update intake_entries set files = ? where id = ?",
        [{path: File.join(root, "d.pdf"), format: "PDF", size: File.size(File.join(dir, "secret.pdf")), mtime: File.info(File.join(dir, "secret.pdf")).modification_time.to_unix}].to_json, d
      info.size.should be > 0
      intake.readable(d).should be_nil
      # gone
      File.delete(File.join(root, "a.pdf"))
      intake.readable(a).should be_nil
    end
  end
end

private FIXTURES = "#{__DIR__}/fixtures/metadata"

# a real PDF or DjVu of that many pages
private def book_of(path : String, pages : Int32)
  Dir.mkdir_p(File.dirname(path))
  if path.ends_with?(".pdf")
    Process.run("pdfunite", Array.new(pages, "#{FIXTURES}/scan.pdf") + [path]).success?.should be_true
  else
    Process.run("djvm", ["-c", path] + Array.new(pages, "#{FIXTURES}/scan.djvu")).success?.should be_true
  end
  time = Time.utc - 1.hour
  File.utime(time, time, path)
end

private def pages_of(path : String) : Int32
  info = IO::Memory.new
  Process.run("pdfinfo", [path], output: info)
  info.to_s[/^Pages:\s*(\d+)/m, 1].to_i
end

# the entry of one file, the first pages in their own folder, from any size on
private def peeking(root : String, dir : String, name : String)
  intake, _, db, _ = setup(root)
  intake.peeks = File.join(dir, "intake-peeks")
  intake.peek_from = 0_i64
  intake.run_once
  id = id_of(intake, name)
  {intake, id, intake.readable(id, nil, Intake::PEEKABLE).not_nil!, db}
end

describe "the first pages to read in" do
  it "makes a large PDF's first pages once and leaves the file alone" do
    tmpdir do |dir, root|
      source = File.join(root, "big.pdf")
      book_of(source, 100)
      before = File.read(source)
      intake, id, file, _ = peeking(root, dir, "big.pdf")
      made = 0
      real = intake.peek_reader
      intake.peek_reader = ->(path : String, format : String, target : String) do
        made += 1
        real.call(path, format, target)
      end
      peek = intake.peek(id, file)
      peek.excerpt.should be_true
      peek.path.should eq File.join(dir, "intake-peeks", "#{id}-PDF.pdf")
      pages_of(peek.path.not_nil!).should eq Intake::PEEK_PAGES
      File.size(peek.path.not_nil!).should be < File.size(source)
      Dir.children(File.join(dir, "intake-peeks")).should eq ["#{id}-PDF.pdf"]
      intake.peek(id, file).should eq peek
      made.should eq 1
      File.read(source).should eq before
    end
  end

  it "goes when the entry leaves the list, the file stays" do
    tmpdir do |dir, root|
      source = File.join(root, "big.pdf")
      book_of(source, 100)
      intake, id, file, _ = peeking(root, dir, "big.pdf")
      other = File.join(dir, "intake-peeks", "#{id}1-PDF.pdf")
      path = intake.peek(id, file).path.not_nil!
      File.touch(other)
      intake.finish(intake[id]?.not_nil!)
      File.exists?(path).should be_false
      File.exists?(other).should be_true
      File.exists?(source).should be_true
    end
  end

  it "doesn't keep what comes back after the entry left" do
    tmpdir do |dir, root|
      book_of(File.join(root, "big.pdf"), 100)
      intake, id, file, _ = peeking(root, dir, "big.pdf")
      intake.peek_reader = ->(_path : String, _format : String, target : String) do
        File.write(target, "x")
        intake.finish(intake[id]?.not_nil!)
        100.as(Int32?)
      end
      intake.peek(id, file).path.should eq file.path
      Dir.children(File.join(dir, "intake-peeks")).should be_empty
    end
  end

  it "makes it once for two asking at the same time" do
    tmpdir do |dir, root|
      book_of(File.join(root, "big.pdf"), 100)
      intake, id, file, _ = peeking(root, dir, "big.pdf")
      made = 0
      intake.peek_reader = ->(_path : String, _format : String, target : String) do
        made += 1
        sleep 50.milliseconds
        File.write(target, "x")
        100.as(Int32?)
      end
      done = Channel(Intake::Peek).new
      3.times { spawn { done.send(intake.peek(id, file)) } }
      3.times.map { done.receive }.to_a.map(&.excerpt).should eq [true, true, true]
      made.should eq 1
    end
  end

  it "sends the whole file below the size, and what isn't a PDF" do
    tmpdir do |dir, root|
      write(File.join(root, "a.epub"), "PK" + "." * 4000)
      book_of(File.join(root, "small.pdf"), 40)
      intake, _, _, _ = setup(root)
      intake.peeks = File.join(dir, "intake-peeks")
      intake.peek_reader = ->(_path : String, _format : String, _target : String) { raise "not to be asked" }
      intake.run_once
      {"a.epub", "small.pdf"}.each do |name|
        id = id_of(intake, name)
        file = intake.readable(id).not_nil!
        intake.peek_from = 0_i64 if name == "a.epub"
        intake.peek_from = File.size(file.path) if name == "small.pdf"
        intake.peek(id, file).should eq Intake::Peek.new(file.path)
      end
      Dir.exists?(File.join(dir, "intake-peeks")).should be_false
    end
  end

  it "falls back to the whole file, without trying again" do
    tmpdir do |dir, root|
      book_of(File.join(root, "short.pdf"), 30)
      book_of(File.join(root, "broken.pdf"), 40)
      book_of(File.join(root, "shared.pdf"), 40)
      intake, _, _, _ = setup(root)
      intake.peeks = File.join(dir, "intake-peeks")
      intake.peek_from = 0_i64
      intake.run_once
      # as many pages as it takes: nothing to make
      short = id_of(intake, "short.pdf")
      file = intake.readable(short).not_nil!
      intake.peek(short, file).should eq Intake::Peek.new(file.path)
      # the tools can't, encrypted or broken
      asked = 0
      intake.peek_reader = ->(_path : String, _format : String, _target : String) do
        asked += 1
        nil.as(Int32?)
      end
      broken = id_of(intake, "broken.pdf")
      file = intake.readable(broken).not_nil!
      2.times { intake.peek(broken, file).should eq Intake::Peek.new(file.path) }
      asked.should eq 1
      # each page with its copy of what they share: larger than two thirds
      asked = 0
      shared = id_of(intake, "shared.pdf")
      file = intake.readable(shared).not_nil!
      intake.peek_reader = ->(_path : String, _format : String, target : String) do
        asked += 1
        File.write(target, "x" * (file.size * 2 // 3 + 1))
        40.as(Int32?)
      end
      2.times { intake.peek(shared, file).should eq Intake::Peek.new(file.path) }
      asked.should eq 1
      Dir.children(File.join(dir, "intake-peeks")).sort!.should eq ["#{broken}-PDF.whole", "#{shared}-PDF.whole", "#{short}-PDF.whole"].sort!
    end
  end

  it "takes the first pages when they are two thirds at most" do
    tmpdir do |dir, root|
      book_of(File.join(root, "big.pdf"), 40)
      intake, id, file, _ = peeking(root, dir, "big.pdf")
      intake.peek_reader = ->(_path : String, _format : String, target : String) do
        File.write(target, "x" * (file.size * 2 // 3))
        40.as(Int32?)
      end
      intake.peek(id, file).excerpt.should be_true
    end
  end

  it "reads a DjVu as a PDF, only when asked for a look" do
    tmpdir do |dir, root|
      book_of(File.join(root, "scan.djvu"), 40)
      intake, id, file, _ = peeking(root, dir, "scan.djvu")
      file.format.should eq "DJVU"
      intake.readable(id).should be_nil
      peek = intake.peek(id, file)
      peek.excerpt.should be_true
      pages_of(peek.path.not_nil!).should eq Intake::PEEK_PAGES
    end
  end

  it "doesn't call a short DjVu an excerpt, however large the result" do
    tmpdir do |dir, root|
      book_of(File.join(root, "scan.djvu"), 2)
      intake, id, file, _ = peeking(root, dir, "scan.djvu")
      2.times do
        peek = intake.peek(id, file)
        peek.excerpt.should be_false
        peek.path.should eq File.join(dir, "intake-peeks", "#{id}-DJVU.all.pdf")
        pages_of(peek.path.not_nil!).should eq 2
      end
    end
  end

  it "has nothing to send of a DjVu the tools can't read" do
    tmpdir do |dir, root|
      write(File.join(root, "b.djvu"), "AT&TFORM" + "." * 4000)
      intake, id, file, _ = peeking(root, dir, "b.djvu")
      intake.peek(id, file).should eq Intake::Peek.new(nil)
    end
  end
end

describe "the filter Schon in der Bibliothek" do
  it "shows the proposals as entries, by the book's title where there is no file" do
    tmpdir do |_, root|
      fake = FakeCalibre.new
      fake.add(7, "Alt", ["Jemand"])
      fake.add(8, "Auch alt", ["Niemand"])
      intake, _, db, _ = setup(root, fake)
      intake.repair = repair_of(fake, db)
      proposal_row(db, 7, title_change("Alt", "Neu"), file: "/backlog/F/alt.pdf")
      proposal_row(db, 8, title_change("Auch alt", "Auch neu"), 40)
      list = intake.library_list
      list["total"].should eq 2
      list["takeable"].should eq 2
      list["unsure"].should eq 1
      e = list["entries"][0]
      {e["id"], e["name"], e["kind"], e["bookId"], e["bookTitle"]}.should eq({-7, "alt.pdf", "library", 7, "Alt"})
      e["proposal"]["title"].should eq "Neu"
      e["proposal"]["authors"][0].should eq "Jemand"
      list["entries"][1]["name"].should eq ""
      list["counts"]["unsure"].should eq 1
      library_entries(intake, "unsure").map(&.["bookId"].as_i).should eq [8]
      # pages by book id
      page = intake.library_list(limit: 1)
      page["next"].should eq "80:7"
      intake.library_list(after: page["next"].as_s)["entries"].as_a.map(&.["bookId"].as_i).should eq [8]
      # the file list stays what it was
      intake.list["total"].should eq 0
      d = intake.detail(-7).not_nil!
      d["changes"][0]["new"].should eq "Neu"
      d["candidates"].as_a.should be_empty
    end
  end

  it "accepts through the repair, once, and the Prüfliste no longer has it" do
    tmpdir do |_, root|
      fake = FakeCalibre.new
      fake.add(7, "Alt", ["Jemand"])
      intake, _, db, _ = setup(root, fake)
      repair = repair_of(fake, db)
      intake.repair = repair
      proposal_row(db, 7, title_change("Alt", "Neu"))
      r = decide(intake, [-7_i64], "accept")
      r["total"].should eq 1
      library_entries(intake).should be_empty
      repair_settled(repair)
      fake.books[7_i64]["title"].should eq "Neu"
      repair.proposals("pending").should be_empty
      # accepted a second time, from the other door
      fake.books[7_i64]["title"] = JSON::Any.new("Hand")
      repair.accept([7_i64])["books"].should eq 0
      decide(intake, [-7_i64], "accept")["total"].should eq 0
      repair_settled(repair)
      fake.books[7_i64]["title"].should eq "Hand"
    end
  end

  it "a decision in the Prüfliste takes it out of the filter" do
    tmpdir do |_, root|
      fake = FakeCalibre.new
      fake.add(7, "Alt", ["Jemand"])
      fake.add(8, "Alt", ["Jemand"])
      intake, _, db, _ = setup(root, fake)
      repair = repair_of(fake, db)
      intake.repair = repair
      proposal_row(db, 7, title_change("Alt", "Neu"))
      proposal_row(db, 8, title_change("Alt", "Neu"))
      repair.accept([7_i64])
      repair.reject([8_i64])
      library_entries(intake).should be_empty
      repair_settled(repair)
      library_entries(intake).should be_empty
    end
  end

  it "shows why an accept failed: a field changed, and rejecting still goes" do
    tmpdir do |_, root|
      fake = FakeCalibre.new
      fake.add(7, "Von Hand", ["Jemand"])
      intake, _, db, _ = setup(root, fake)
      repair = repair_of(fake, db)
      intake.repair = repair
      proposal_row(db, 7, title_change("Alt", "Neu"))
      decide(intake, [-7_i64], "accept")
      repair_settled(repair)
      fake.books[7_i64]["title"].should eq "Von Hand"
      e = library_entries(intake).first
      e["status"].should eq "failed"
      e["error"].should eq "title changed since the plan"
      list = intake.library_list
      list["takeable"].should eq 0
      list["left"]["failed"].should eq 1
      list["pending"].should eq 0
      decide(intake, [-7_i64], "accept")["total"].should eq 0
      intake.decide(JSON.parse({decision: "reject", target: {ids: [-7]}}.to_json).as_h)[1]["total"].should eq 1
      library_entries(intake).should be_empty
    end
  end

  it "comes back with the reason when the write fails" do
    tmpdir do |_, root|
      fake = FakeCalibre.new
      intake, _, db, _ = setup(root, fake)
      repair = repair_of(fake, db)
      intake.repair = repair
      # no such book any more
      proposal_row(db, 9, title_change("Alt", "Neu"))
      decide(intake, [-9_i64], "accept")
      repair_settled(repair)
      e = library_entries(intake).first
      e["status"].should eq "analysed"
      e["error"].as_s.should_not be_empty
      e["bookTitle"].raw.should be_nil
    end
  end

  it "has no way to the trash or as in the file, and no mix with files" do
    tmpdir do |_, root|
      write(File.join(root, "a.pdf"), pdf("a"))
      fake = FakeCalibre.new
      fake.add(7, "Alt", ["Jemand"])
      intake, _, db, _ = setup(root, fake)
      intake.repair = repair_of(fake, db)
      intake.run_once
      proposal_row(db, 7, title_change("Alt", "Neu"))
      expect_raises(CalibreHub::Edit::Invalid, /library book/) { decide(intake, [-7_i64], "trash") }
      expect_raises(CalibreHub::Edit::Invalid, /library book/) { decide(intake, [-7_i64], "file") }
      expect_raises(CalibreHub::Edit::Invalid, /library book/) { decide(intake, [-7_i64], "accept", title: "x") }
      expect_raises(CalibreHub::Edit::Invalid, /mix/) { decide(intake, [-7_i64, id_of(intake, "a.pdf")], "accept") }
      expect_raises(CalibreHub::Edit::Invalid, /library/) { decide(intake, [id_of(intake, "a.pdf")], "reject") }
      library_entries(intake).size.should eq 1
    end
  end

  it "skips, and a bulk leaves out what is skipped, failed or has nothing to write" do
    tmpdir do |_, root|
      fake = FakeCalibre.new
      (1_i64..5_i64).each { |i| fake.add(i, "Alt", ["Jemand"]) }
      intake, _, db, _ = setup(root, fake)
      repair = repair_of(fake, db)
      intake.repair = repair
      proposal_row(db, 1, title_change("Alt", "Neu"))
      proposal_row(db, 2, title_change("Alt", "Neu"))
      proposal_row(db, 3, title_change("Alt", "Neu"), status: "failed")
      proposal_row(db, 4, [{field: "candidate", old: nil, new: {title: "X", authors: ["Y"], source: "rules"}, source: "rules"}].to_json)
      proposal_row(db, 5, "[]")
      decide(intake, [-2_i64], "skip")
      list = intake.library_list
      list["entries"][1]["skipped"].should eq true
      list["takeable"].should eq 1
      {list["left"]["skipped"], list["left"]["failed"], list["left"]["unchanged"]}.should eq({1, 1, 2})
      list["total"].as_i.should eq list["takeable"].as_i + 4
      stale = JSON.parse({decision: "accept", target: {query: {library: true}, last: list["last"], expect: 5}}.to_json).as_h
      expect_raises(CalibreHub::Jobs::CountMismatch) { intake.decide(stale) }
      body = JSON.parse({decision: "accept", target: {query: {library: true}, last: list["last"], expect: 1}}.to_json).as_h
      intake.decide(body)[1]["total"].should eq 1
      repair_settled(repair)
      fake.books[1_i64]["title"].should eq "Neu"
      fake.books[2_i64]["title"].should eq "Alt"
      decide(intake, [-2_i64], "unskip")
      intake.library_list["takeable"].should eq 1
    end
  end
end

describe CalibreHub::RepairRecheck do
  it "plans the applied books and the last run again, protects hand edits, drops what changes nothing" do
    tmpdir do |_, root|
      fake = FakeCalibre.new
      fake.add(1, "Frank Herbert", ["Dune"])          # accepted before today's rules
      fake.add(2, "Hand", ["Ursula Le Guin"])         # title and authors by hand since
      fake.add(3, "Dune", ["Frank Herbert"])          # right already
      fake.add(4, "Isaac Asimov", ["Foundation"])     # of the last run, never planned
      fake.add(5, "Ray Bradbury", ["Fahrenheit 451"]) # rejected
      fake.add(6, "Stanislaw Lem", ["Solaris"])       # open
      fake.add(7, "Philip Dick", ["Ubik"])            # an older run
      fake.add(8, "Arkady Strugatsky", ["Picknick"])  # taken in the Eingang
      intake, _, db, _ = setup(root, fake)
      repair = repair_of(fake, db)
      intake.repair = repair
      recheck = CalibreHub::RepairRecheck.new(db, fake.calibre, CalibreHub::Writer.new(fake.calibre, nil, nil, "kategorie"), repair, 0.seconds, 5.milliseconds)
      imported(db, "/gone/Frank Herbert - Dune.pdf", 1)
      imported(db, "/gone/Ursula Le Guin - Earthsea.pdf", 2)
      imported(db, "/gone/Frank Herbert - Dune2.pdf", 3)
      imported(db, "/gone/Ray Bradbury - Fahrenheit 451.pdf", 5)
      imported(db, "/gone/Stanislaw Lem - Solaris.pdf", 6)
      imported(db, "/gone/Philip Dick - Ubik.pdf", 7, "older")
      db.exec "update import_files set at = 50 where run_id = 'older'"
      imported(db, "/gone/Isaac Asimov - Foundation.pdf", 4, "last")
      imported(db, "/gone/Arkady Strugatsky - Picknick.pdf", 8, Intake::RUN)
      db.exec "update import_files set at = 200 where run_id = 'last'"
      db.exec "update import_files set at = 300 where run_id = ?", Intake::RUN
      [1_i64, 2_i64, 3_i64].each { |i| proposal_row(db, i, "[]", status: "applied") }
      proposal_row(db, 5, title_change("x", "y"), status: "rejected")
      proposal_row(db, 6, title_change("Stanislaw Lem", "Solaris"), file: "/gone/Stanislaw Lem - Solaris.pdf")
      proposal_row(db, 8, "[]", status: "applied")
      log = CalibreHub::MetaLog.new(db)
      log.decide(8, Meta::Flow::Decision.new([] of Meta::Change, "dnb", 3, "dnb", 100, 100), CalibreHub::MetaLog::ACCEPTED)
      changed = {changes: {"title" => ["Earthsea", "Hand"], "authors" => [["Earthsea"], ["Ursula Le Guin"]]}}.to_json
      db.exec "insert into events (type, book_id, payload, created_at) values ('added', 2, ?, 100)", {book: {title: "Ursula Le Guin", authors: ["Earthsea"]}}.to_json
      db.exec "insert into events (type, book_id, payload, created_at) values ('changed', 2, ?, 100000)", changed
      {1, 3, 4}.each { |i| db.exec "insert into events (type, book_id, payload, created_at) values ('added', ?, ?, 100)", i, {book: JSON.parse(fake.books[i.to_i64].to_json)}.to_json }

      job = recheck.queue
      job.ids.should eq [1_i64, 2_i64, 3_i64, 4_i64]
      recheck_done(recheck)
      recheck[job.id]?.not_nil!.errors.should be_empty
      open = repair.proposals("pending").to_h { |p| {p.book_id, p} }
      open.keys.sort!.should eq [1_i64, 4_i64, 6_i64]
      open[1_i64].changes.map(&.field).should contain "title"
      open[1_i64].file.should eq "/gone/Frank Herbert - Dune.pdf"
      # the rows no plan changed are as they were
      repair.proposals("status = 'applied'", [] of DB::Any).map(&.book_id).sort!.should eq [2_i64, 3_i64, 8_i64]
      # the same book isn't checked twice
      recheck.queue.total.should eq 0
      library_entries(intake).map(&.["bookId"].as_i).should contain 4
    end
  end

  it "takes a run by name and a calibre folder's book by its folder's name" do
    tmpdir do |_, root|
      dir = File.join(root, "Allies (177)")
      write(File.join(dir, "Allies - Christie Golden.mobi"), "x")
      fake = FakeCalibre.new
      fake.add(1, "Christie Golden", ["Allies"], ["MOBI"])
      intake, _, db, _ = setup(root, fake)
      repair = repair_of(fake, db)
      recheck = CalibreHub::RepairRecheck.new(db, fake.calibre, CalibreHub::Writer.new(fake.calibre, nil, nil, "kategorie"), repair, 0.seconds, 5.milliseconds)
      imported(db, File.join(dir, "Allies - Christie Golden.mobi"), 1, "portion")
      db.exec "insert into events (type, book_id, payload, created_at) values ('added', 1, ?, 100)", {book: JSON.parse(fake.books[1_i64].to_json)}.to_json
      # no metadata.opf any more, the folder's name still says it
      repair.files.should be_empty
      repair.files(folders: true)[1_i64].should end_with ".mobi"
      recheck.queue("other").total.should eq 0
      recheck_done(recheck)
      recheck.queue("portion").total.should eq 1
      recheck_done(recheck)
      p = repair.proposals("pending").first
      p.changes.find! { |c| c.field == "title" }.new.should eq "Allies"
      p.changes.find! { |c| c.field == "authors" }.new[0].should eq "Christie Golden"
      intake.list["total"].should eq 0
    end
  end

  it "stands still while the analysis works, and the analysis doesn't wait for it" do
    tmpdir do |_, root|
      fake = FakeCalibre.new
      fake.add(1, "Frank Herbert", ["Dune"])
      intake, _, db, imports = setup(root, fake)
      repair = repair_of(fake, db)
      intake.repair = repair
      recheck = CalibreHub::RepairRecheck.new(db, fake.calibre, CalibreHub::Writer.new(fake.calibre, nil, nil, "kategorie"), repair, 0.seconds, 5.milliseconds)
      intake.recheck = recheck
      busy = true
      recheck.busy = -> { busy }
      imported(db, "/gone/Frank Herbert - Dune.pdf", 1)
      proposal_row(db, 1, "[]", status: "applied")
      recheck.queue
      sleep 30.milliseconds
      recheck.waiting?.should be_true
      intake.library_list["recheck"]["waiting"].should eq true
      # the queue the analysis waits for is another one
      repair.running?.should be_false
      db.query_one("select count(*) from import_rechecks", as: Int64).should eq 0
      busy = false
      recheck_done(recheck)
      recheck.waiting?.should be_false
      intake.library_list["recheck"].raw.should be_nil
      db.query_one("select count(*) from import_rechecks", as: Int64).should eq 1
    end
  end
end

# The Eingang with all its sources: folders below dir
private def sources(dir : String, fake = FakeCalibre.new, shelf : String? = nil, db = state_db)
  calibre = fake.calibre
  writer = CalibreHub::Writer.new(calibre, nil, nil, "kategorie")
  root = File.join(dir, "backlog")
  Dir.mkdir_p(root)
  Dir.mkdir_p(File.join(dir, "inbox"))
  Dir.mkdir_p(File.join(dir, "uploads"))
  imports = CalibreHub::Importer.new(db, calibre, writer, [root], shelf, retries: 0)
  intake = Intake.new(db, calibre, imports, shelf, File.join(dir, ".covers"), stable: 0.seconds, pause: 0.seconds, wait: 10.milliseconds,
    inbox: CalibreHub::Inbox.new(File.join(dir, "inbox"), 0.seconds), uploads: CalibreHub::Inbox.new(File.join(dir, "uploads"), 0.seconds))
  intake.category_column = "kategorie"
  intake.cover_reader = ->(_path : String, _format : String, _target : String) { false }
  intake.reader = ->(path : String, _format : String) do
    Meta::FileMeta::Info.new(Meta::Record.new, [] of String, front: "", format: "PDF").as(Meta::FileMeta::Info?)
  end
  {intake, fake, db, imports}
end

# what POST /api/books hands over
private def upload(intake : Intake, dir : String, name : String, content : String, tags = [] of String, kategorie : String? = nil, force = false) : String
  tmp = File.join(dir, "upload-tmp")
  File.write(tmp, content)
  intake.stage(CalibreHub::Writer::Upload.new(tmp, name, tags, kategorie, force, nil), "arthur")["id"].as_s
end

describe "the sources of the Eingang" do
  it "keeps the inbox's folders for later and writes nothing before a decision" do
    tmpdir do |dir, _|
      write(File.join(dir, "inbox/Roman/Krimi/Agatha Christie - Poirot.pdf"), pdf("poirot"))
      intake, fake, _, _ = sources(dir)
      intake.run_fast.should eq 1
      fake.added.should be_empty
      e = entries(intake).first
      e["origin"].should eq "inbox"
      e["folder"].should eq "Roman/Krimi"
      File.exists?(File.join(dir, "inbox/Roman/Krimi/Agatha Christie - Poirot.pdf")).should be_true
      # the same file isn't looked at twice
      intake.run_fast.should eq 0
    end
  end

  it "takes the inbox and uploads from 90 on and leaves the backlog alone until someone says so" do
    tmpdir do |dir, _|
      intake, _, _, _ = sources(dir)
      intake.thresholds.should eq({"backlog" => nil, "inbox" => 90, "upload" => 90})
      intake.set_threshold("inbox", nil)
      intake.set_threshold("upload", 70)
      intake.threshold("inbox").should be_nil
      intake.threshold("upload").should eq 70
      intake.set_threshold("backlog", 95)
      intake.thresholds.should eq({"backlog" => 95, "inbox" => nil, "upload" => 70})
      intake.set_threshold("backlog", nil)
      intake.threshold("backlog").should be_nil
    end
  end

  it "lets what is below the source's threshold wait, says so and moves on what is above" do
    tmpdir do |dir, _|
      name = "Agatha Christie - Poirot.pdf"
      write(File.join(dir, "inbox/Roman/Krimi", name), pdf("poirot"))
      intake, fake, _, _ = sources(dir)
      intake.run_fast
      # a clear name is 80: below the default
      settled(intake)
      entries(intake).first["confidence"].should eq 80
      fake.added.should be_empty

      intake.set_threshold("inbox", 80)
      settled(intake)
      fake.added.should eq [name]
      id = fake.books.keys.max
      fake.books[id]["tags"].as_a.map(&.as_s).sort!.should eq ["Krimi", "Roman"]
      fake.books[id]["#kategorie"].should eq "Roman.Krimi"
      entries(intake).should be_empty
      today = Time.local.to_s("%F")
      File.exists?(File.join(dir, "inbox/_imported", today, "Roman/Krimi", name)).should be_true
      File.exists?(File.join(dir, "inbox/Roman/Krimi", name)).should be_false
      # dropped again it is looked at again: nothing remembers the old path
      write(File.join(dir, "inbox/Roman/Krimi", name), pdf("poirot"))
      intake.set_threshold("inbox", nil)
      intake.run_fast.should eq 1
    end
  end

  it "leaves the sources' thresholds to themselves" do
    tmpdir do |dir, root|
      write(File.join(root, "Frank Herbert - Dune (Chilton, 1965).pdf"), pdf("dune"))
      write(File.join(dir, "inbox/Agatha Christie - Poirot.pdf"), pdf("poirot"))
      intake, fake, _, _ = sources(dir)
      intake.set_threshold("inbox", 60)
      intake.run_once
      intake.run_fast
      settled(intake)
      fake.added.should eq ["Agatha Christie - Poirot.pdf"]
      entries(intake).map(&.["origin"]).should eq ["backlog"]
    end
  end

  it "goes on with the inbox and uploads while the analysis is off or a repair runs" do
    tmpdir do |dir, _|
      write(File.join(dir, "inbox/Agatha Christie - Poirot.pdf"), pdf("poirot"))
      intake, _, _, _ = sources(dir)
      intake.analysis = false
      intake.busy = -> { true }
      upload(intake, dir, "Frank Herbert - Dune.pdf", pdf("dune"))
      intake.run_fast.should eq 2
      entries(intake).map(&.["origin"].as_s).sort!.should eq ["inbox", "upload"]
    end
  end

  it "skips a folder it couldn't move a file out of, and a file still being copied" do
    tmpdir do |dir, _|
      write(File.join(dir, "inbox/Privat/Agatha Christie - Poirot.pdf"), pdf("poirot"))
      File.chmod(File.join(dir, "inbox/Privat"), 0o555)
      intake, _, _, _ = sources(dir)
      begin
        intake.run_fast.should eq 0
      ensure
        File.chmod(File.join(dir, "inbox/Privat"), 0o755)
      end
      box = CalibreHub::Inbox.new(File.join(dir, "inbox"), 1.hour)
      box.settled?(Time.utc.to_unix).should be_false
      box.settled?((Time.utc - 2.hours).to_unix).should be_true
    end
  end

  it "doesn't look into the inbox's own folders, at any depth" do
    tmpdir do |dir, _|
      write(File.join(dir, "inbox/_imported/2026-11-01/Agatha Christie - Poirot.pdf"), pdf("a"))
      write(File.join(dir, "inbox/Roman/_alt/Frank Herbert - Dune.pdf"), pdf("b"))
      write(File.join(dir, "inbox/.tmp/Isaac Asimov - Foundation.pdf"), pdf("c"))
      intake, _, _, _ = sources(dir)
      intake.run_fast.should eq 0
    end
  end

  it "takes a short file somebody put in the inbox, the backlog's sizes are for its noise" do
    tmpdir do |dir, _|
      write(File.join(dir, "inbox/Agatha Christie - Kurz.txt"), "ein kurzer Text")
      write(File.join(dir, "inbox/Frank Herbert - Klein.epub"), "PK" + "x" * 100)
      intake, _, _, _ = sources(dir)
      intake.run_fast.should eq 2
      entries(intake).map(&.["name"].as_s).sort!.should eq ["Agatha Christie - Kurz.txt", "Frank Herbert - Klein.epub"]
    end
  end

  it "moves what is no book out of the inbox, with a word in the log" do
    tmpdir do |dir, _|
      write(File.join(dir, "inbox/Roman/kaputt.pdf"), "no pdf at all" * 400)
      write(File.join(dir, "inbox/notes.mp3"), "x")
      intake, _, _, _ = sources(dir)
      intake.run_fast.should eq 0
      File.exists?(File.join(dir, "inbox/_failed", Time.local.to_s("%F"), "Roman/kaputt.pdf")).should be_true
      # not a book format: stays what and where it is
      File.exists?(File.join(dir, "inbox/notes.mp3")).should be_true
    end
  end

  it "moves an exact copy to _duplicates by the inbox's rules, not to the trash folder" do
    tmpdir do |dir, _|
      content = pdf("dune")
      shelf = library(dir, {1_i64 => {"Dune (1)", "Dune", "PDF", content}})
      write(File.join(dir, "inbox/Roman/kopie.pdf"), content)
      fake = FakeCalibre.new
      fake.add(1_i64, "Dune", ["Frank Herbert"])
      intake, _, _, _ = sources(dir, fake, shelf)
      intake.run_fast
      entries(intake).should be_empty
      File.exists?(File.join(dir, "inbox/_duplicates", Time.local.to_s("%F"), "Roman/kopie.pdf")).should be_true
      Dir.exists?(File.join(dir, "inbox-papierkorb")).should be_false
    end
  end

  it "throws an inbox file and an upload into the trash folder next to their root" do
    tmpdir do |dir, _|
      write(File.join(dir, "inbox/Roman/Agatha Christie - Poirot.pdf"), pdf("poirot"))
      intake, _, _, _ = sources(dir)
      up = upload(intake, dir, "Frank Herbert - Dune.pdf", pdf("dune"))
      intake.run_fast
      wait(intake, decide(intake, entries(intake).map(&.["id"].as_i64), "trash"))
      File.exists?(File.join(dir, "inbox-papierkorb/Roman/Agatha Christie - Poirot.pdf")).should be_true
      File.exists?(File.join(dir, "uploads-papierkorb", up, "Frank Herbert - Dune.pdf")).should be_true
      intake.upload_state(up).not_nil!["status"].should eq "trashed"
    end
  end

  it "filters by source and takes only that source's books" do
    tmpdir do |dir, root|
      write(File.join(root, "Frank Herbert - Dune (Chilton, 1965).pdf"), pdf("dune"))
      write(File.join(dir, "inbox/Agatha Christie - Poirot.pdf"), pdf("poirot"))
      intake, fake, _, _ = sources(dir)
      intake.run_once
      intake.run_fast
      all = intake.list
      all["origins"].as_h.transform_values(&.as_i).should eq({"backlog" => 1, "inbox" => 1})
      only = intake.list(origin: "inbox")
      only["total"].should eq 1
      only["takeable"].should eq 1
      only["entries"].as_a.first["origin"].should eq "inbox"
      # the numbers of the whole list stay, for the filter to stay
      only["origins"].as_h.size.should eq 2
      expect_raises(CalibreHub::Edit::Invalid) { intake.list(origin: "nowhere") }

      target = {query: {origin: "inbox"}, last: all["last"].as_i64, expect: 1}
      r = intake.decide(JSON.parse({decision: "accept", target: target}.to_json).as_h)[1]
      wait(intake, r)
      fake.added.should eq ["Agatha Christie - Poirot.pdf"]
      entries(intake).map(&.["origin"]).should eq ["backlog"]
    end
  end
end

describe "an upload" do
  it "waits in the Eingang below the threshold and says so, with what the form said" do
    tmpdir do |dir, _|
      intake, fake, _, _ = sources(dir)
      up = upload(intake, dir, "Frank Herbert - Dune.pdf", pdf("dune"), ["Neu"], "Roman.SF")
      state = intake.upload_state(up).not_nil!
      state["status"].should eq "checking"
      state["name"].should eq "Frank Herbert - Dune.pdf"
      intake.run_fast.should eq 1
      fake.added.should be_empty

      state = intake.upload_state(up).not_nil!
      state["status"].should eq "waiting"
      state["confidence"].should eq 80
      state["threshold"].should eq 90
      e = entries(intake).first
      e["origin"].should eq "upload"
      e["folder"].raw.should be_nil
      state["entryId"].should eq e["id"]

      wait(intake, decide(intake, [e["id"].as_i64], "accept"))
      id = fake.books.keys.max
      fake.books[id]["tags"].as_a.map(&.as_s).should eq ["Neu"]
      fake.books[id]["#kategorie"].should eq "Roman.SF"
      state = intake.upload_state(up).not_nil!
      state["status"].should eq "imported"
      state["book"]["id"].should eq id
      # never deleted, also not by being taken
      File.exists?(File.join(dir, "uploads/_imported", Time.local.to_s("%F"), up, "Frank Herbert - Dune.pdf")).should be_true
    end
  end

  it "reaches the library by itself at or above the threshold" do
    tmpdir do |dir, _|
      intake, fake, _, _ = sources(dir)
      intake.set_threshold("upload", 80)
      up = upload(intake, dir, "Frank Herbert - Dune.pdf", pdf("dune"))
      intake.run_fast
      settled(intake)
      fake.added.should eq ["Frank Herbert - Dune.pdf"]
      intake.upload_state(up).not_nil!["status"].should eq "imported"
    end
  end

  it "takes file types the backlog's scan wouldn't, the proposal from the name" do
    tmpdir do |dir, _|
      intake, _, _, _ = sources(dir)
      up = upload(intake, dir, "Frank Herbert - Dune.html", "<html>short</html>")
      intake.run_fast
      intake.upload_state(up).not_nil!["status"].should eq "waiting"
    end
  end

  it "refuses what no book can be, before anything is kept" do
    tmpdir do |dir, _|
      intake, _, _, _ = sources(dir)
      expect_raises(CalibreHub::Writer::Unsupported) { upload(intake, dir, "evil.exe", "x") }
      Dir.children(File.join(dir, "uploads")).should be_empty
    end
  end

  it "looks like a book of the library: it asks, whoever sent it can answer" do
    tmpdir do |dir, _|
      fake = FakeCalibre.new
      fake.add(1_i64, "Dune", ["Frank Herbert"], ["EPUB"])
      intake, _, _, _ = sources(dir, fake)
      up = upload(intake, dir, "Frank Herbert - Dune.pdf", pdf("dune"))
      intake.set_threshold("upload", 60)
      intake.run_fast
      settled(intake)
      fake.added.should be_empty
      state = intake.upload_state(up).not_nil!
      state["status"].should eq "duplicate"
      state["duplicates"].as_a.first["id"].should eq 1
      entry = state["entryId"].as_i64

      # as another format of that book
      body = JSON.parse({target: {ids: [entry]}, decision: "format", book: 1}.to_json).as_h
      wait(intake, intake.decide(body)[1])
      fake.books[1_i64]["formats"].as_a.map(&.as_s).sort!.should eq ["EPUB", "PDF"]
      state = intake.upload_state(up).not_nil!
      state["status"].should eq "formatAdded"
      state["book"]["id"].should eq 1
      entries(intake).should be_empty
    end
  end

  it "wants a format's book to exist and only one entry" do
    tmpdir do |dir, _|
      intake, _, _, _ = sources(dir)
      upload(intake, dir, "Frank Herbert - Dune.pdf", pdf("dune"))
      upload(intake, dir, "Isaac Asimov - Foundation.pdf", pdf("found"))
      intake.run_fast
      ids = entries(intake).map(&.["id"].as_i64)
      format = ->(list : Array(Int64), book : Int64) { intake.decide(JSON.parse({target: {ids: list}, decision: "format", book: book}.to_json).as_h) }
      expect_raises(CalibreHub::Edit::Invalid) { format.call(ids, 1_i64) }
      expect_raises(CalibreHub::Writer::NotFound) { format.call(ids[0, 1], 999_i64) }
      entries(intake).size.should eq 2
    end
  end

  it "sent on purpose goes in as a book of its own, also next to the same file" do
    tmpdir do |dir, _|
      content = pdf("dune")
      shelf = library(dir, {1_i64 => {"Dune (1)", "Dune", "PDF", content}})
      fake = FakeCalibre.new
      fake.add(1_i64, "Dune", ["Frank Herbert"])
      fake.duplicate_names["Frank Herbert - Dune.pdf"] = 1_i64
      intake, _, _, _ = sources(dir, fake, shelf)
      intake.set_threshold("upload", 60)
      up = upload(intake, dir, "Frank Herbert - Dune.pdf", content, force: true)
      intake.run_fast
      settled(intake)
      fake.added.should eq ["Frank Herbert - Dune.pdf"]
      state = intake.upload_state(up).not_nil!
      state["status"].should eq "imported"
      state["book"]["id"].should_not eq 1
    end
  end

  it "is the same file as a book's: it says so and nothing stays in the list" do
    tmpdir do |dir, _|
      content = pdf("dune")
      shelf = library(dir, {1_i64 => {"Dune (1)", "Dune", "PDF", content}})
      fake = FakeCalibre.new
      fake.add(1_i64, "Dune", ["Frank Herbert"])
      intake, _, _, _ = sources(dir, fake, shelf)
      up = upload(intake, dir, "kopie.pdf", content)
      intake.run_fast
      entries(intake).should be_empty
      state = intake.upload_state(up).not_nil!
      state["status"].should eq "copy"
      state["duplicates"].as_a.first["id"].should eq 1
      File.exists?(File.join(dir, "uploads/_duplicates", Time.local.to_s("%F"), up, "kopie.pdf")).should be_true
    end
  end

  it "that was staged when the hub stopped is analysed after the restart" do
    tmpdir do |dir, _|
      db = state_db
      first, _, _, _ = sources(dir, db: db)
      up = upload(first, dir, "Frank Herbert - Dune.pdf", pdf("dune"))
      second, _, _, _ = sources(dir, db: db)
      second.run_fast.should eq 1
      second.upload_state(up).not_nil!["status"].should eq "waiting"
    end
  end

  it "is gone when its file is" do
    tmpdir do |dir, _|
      intake, _, _, _ = sources(dir)
      up = upload(intake, dir, "Frank Herbert - Dune.pdf", pdf("dune"))
      File.delete(File.join(dir, "uploads", up, "Frank Herbert - Dune.pdf"))
      intake.run_fast
      intake.upload_state(up).not_nil!["status"].should eq "gone"
      intake.upload_state("nothing").should be_nil
    end
  end
end

describe "reading in an inbox file or an upload" do
  it "gives the first pages of both, and they go when the entries do" do
    tmpdir do |dir, _|
      write(File.join(dir, "inbox/Agatha Christie - Poirot.pdf"), pdf("poirot"))
      intake, _, _, _ = sources(dir)
      intake.peeks = File.join(dir, "intake-peeks")
      intake.peek_from = 0_i64
      intake.peek_reader = ->(_path : String, _format : String, target : String) do
        File.write(target, "pages")
        40.as(Int32?)
      end
      upload(intake, dir, "Frank Herbert - Dune.djvu", "AT&TFORM" + "x" * 3000)
      intake.run_fast
      list = entries(intake)
      list.map(&.["origin"].as_s).sort!.should eq ["inbox", "upload"]
      list.each do |e|
        id = e["id"].as_i64
        file = intake.readable(id, nil, Intake::PEEKABLE).not_nil!
        peek = intake.peek(id, file)
        peek.excerpt.should be_true
        File.read(peek.path.not_nil!).should eq "pages"
      end
      Dir.children(File.join(dir, "intake-peeks")).size.should eq 2

      taken = list.find! { |e| e["origin"] == "inbox" }["id"].as_i64
      wait(intake, decide(intake, [taken], "accept"))
      Dir.children(File.join(dir, "intake-peeks")).map(&.split('-').first.to_i64).should_not contain taken
      thrown = list.find! { |e| e["origin"] == "upload" }["id"].as_i64
      wait(intake, decide(intake, [thrown], "trash"))
      Dir.children(File.join(dir, "intake-peeks")).should be_empty
    end
  end

  it "leaves nothing of the old entry when an inbox file changes" do
    tmpdir do |dir, _|
      path = File.join(dir, "inbox/Agatha Christie - Poirot.pdf")
      write(path, pdf("poirot"))
      intake, _, db, _ = sources(dir)
      intake.peeks = File.join(dir, "intake-peeks")
      intake.peek_from = 0_i64
      intake.peek_reader = ->(_path : String, _format : String, target : String) do
        File.write(target, "pages")
        40.as(Int32?)
      end
      intake.run_fast
      old = entries(intake).first["id"].as_i64
      intake.peek(old, intake.readable(old).not_nil!)
      Dir.children(File.join(dir, "intake-peeks")).size.should eq 1

      write(path, pdf("poirot, zweite Fassung"))
      intake.run_fast.should eq 1
      now = entries(intake).first["id"].as_i64
      now.should_not eq old
      Dir.children(File.join(dir, "intake-peeks")).should be_empty
      db.query_one("select count(*) from intake_candidates where entry_id = ?", old, as: Int64).should eq 0
    end
  end
end
