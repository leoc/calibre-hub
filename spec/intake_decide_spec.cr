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
  imports = CalibreHub::ImportJobs.new(db, calibre, writer, [root], shelf, retries: 0)
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

      intake.threshold = 90
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
      intake.threshold = 60
      intake.run_once
      settled(intake)
      fake.added.size.should eq 1

      write(File.join(root, "Jane Doe - Zwei.pdf"), pdf("zwei"))
      intake.threshold = nil
      intake.run_once
      id = id_of(intake, "Jane Doe - Zwei.pdf")
      decide(intake, [id], "skip")
      intake.threshold = 60
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
