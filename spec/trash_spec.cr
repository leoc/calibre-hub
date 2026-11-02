require "spec"
require "file_utils"
require "kemal"
require "../src/calibre_hub/api"

# Records the requests calibre-server gets and answers like it would
private class FakeCalibre
  getter requests = [] of {String, JSON::Any}
  getter books = {} of Int64 => String
  property next_id = 42_i64
  property fail_set_fields = false
  getter url : String

  def initialize
    @server = HTTP::Server.new do |ctx|
      path = ctx.request.path
      body = JSON.parse(ctx.request.body.try(&.gets_to_end).presence || "null")
      @requests << {path, body}
      ctx.response.content_type = "application/json"
      case path
      when "/cdb/cmd/list/0"
        # search is "id:1 or id:2"
        ids = body[3].as_s.scan(/id:(\d+)/).map(&.[1].to_i64).select { |id| @books.has_key?(id) }
        data = {"title" => ids.to_h { |id| {id.to_s, @books[id]} }, "last_modified" => ids.to_h { |id| {id.to_s, "2026-11-02T10:00:00+00:00"} }}
        ctx.response.print({result: {book_ids: ids, data: data}}.to_json)
      when "/cdb/cmd/remove/0"
        body[0].as_a.each { |id| @books.delete(id.as_i64) }
        ctx.response.print %({"result":null})
      when "/cdb/cmd/add/0"
        id = @next_id
        @books[id] = body[1]["v"]["title"].as_s
        ctx.response.print({result: [[id], false]}.to_json)
      when .starts_with?("/cdb/set-fields/")
        if @fail_set_fields
          ctx.response.status_code = 500
        else
          ctx.response.print "{}"
        end
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

OPF = <<-XML
  <?xml version='1.0' encoding='utf-8'?>
  <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
    <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
      <dc:title>Testbuch</dc:title>
      <dc:creator opf:file-as="Lovelace, Ada" opf:role="aut">Ada Lovelace</dc:creator>
      <dc:creator opf:role="edt">Herausgeber</dc:creator>
    </metadata>
  </package>
  XML

JPEG = Bytes[0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10]

private def library(&)
  dir = File.tempname("trash-spec")
  b = File.join(dir, ".caltrash", "b")
  {7, 8}.each do |id|
    book = File.join(b, id.to_s)
    Dir.mkdir_p(book)
    File.write(File.join(book, "metadata.opf"), OPF)
    File.write(File.join(book, "Testbuch - Ada Lovelace.epub"), "epub")
    File.write(File.join(book, "Testbuch - Ada Lovelace.pdf"), "pdf")
    File.write(File.join(book, "cover.jpg"), JPEG)
  end
  File.touch(File.join(b, "7"), Time.utc(2026, 11, 1))
  File.touch(File.join(b, "8"), Time.utc(2026, 11, 2))
  Dir.mkdir_p(File.join(dir, ".caltrash", "f", "9"))
  Dir.mkdir_p(File.join(b, "junk"))
  yield dir
ensure
  dir.try { |d| FileUtils.rm_rf(d) }
end

private def setup(dir, reader = ->(_d : String) { JSON.parse(%({"jPoAv3zOyHvQ5JFNYg4hJ9": 2, "v": {"title": "Testbuch"}})) })
  fake = FakeCalibre.new
  writer = CalibreHub::Writer.new(fake.calibre, nil, nil, "kategorie")
  trash = CalibreHub::Trash.new(fake.calibre, writer, dir, DB.open("sqlite3::memory:"), reader)
  {fake, writer, trash}
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

describe CalibreHub::Trash do
  it "lists deleted books newest first, without format folders and junk" do
    library do |dir|
      _, _, trash = setup(dir)
      list = trash.list
      list.map(&.id).should eq([8, 7])
      e = list[0]
      e.title.should eq("Testbuch")
      e.authors.should eq(["Ada Lovelace"])
      e.formats.should eq(["EPUB", "PDF"])
      JSON.parse(e.to_json).should eq(JSON.parse(%({"id":8,"title":"Testbuch","authors":["Ada Lovelace"],"formats":["EPUB","PDF"],"deletedAt":"2026-11-02T00:00:00Z"})))
    end
  end

  it "is empty without a library" do
    _, _, trash = setup(nil)
    trash.list.should be_empty
  end

  it "restores a book through calibre-server and hides the entry" do
    library do |dir|
      read = [] of String
      fake, _, trash = setup(dir, ->(d : String) { read << d; JSON.parse(%({"jPoAv3zOyHvQ5JFNYg4hJ9": 2, "v": {"title": "Testbuch"}})) })
      book = trash.restore(7)
      book.id.should eq(42)
      read.should eq([File.join(dir, ".caltrash", "b", "7")])
      add = fake.requests.find! { |r| r[0] == "/cdb/cmd/add/0" }
      add[1][0].should eq("empty")
      add[1][1]["v"]["title"].should eq("Testbuch")
      sets = fake.requests.select { |r| r[0] == "/cdb/set-fields/42" }.map { |r| r[1]["changes"] }
      sets.compact_map { |c| c["added_formats"]?.try(&.[0]["ext"].as_s) }.should eq(["epub", "pdf"])
      sets.any? { |c| c["cover"]?.try(&.as_s.starts_with?("data:image/jpeg;base64,")) }.should be_true
      trash.list.map(&.id).should eq([8])
      expect_raises(CalibreHub::Writer::NotFound) { trash.restore(7) }
    end
  end

  it "removes a half restored book and keeps the entry" do
    library do |dir|
      fake, _, trash = setup(dir)
      fake.fail_set_fields = true
      expect_raises(CalibreHub::Calibre::Unavailable) { trash.restore(8) }
      remove = fake.requests.find! { |r| r[0] == "/cdb/cmd/remove/0" }
      remove[1].should eq(JSON.parse("[[42], true]"))
      trash.list.map(&.id).should eq([8, 7])
    end
  end
end

describe "delete and trash routes" do
  it "deletes into the trash and restores" do
    library do |dir|
      fake, writer, trash = setup(dir)
      fake.books[5] = "Weg"
      jobs = CalibreHub::Jobs.new(state_db, fake.calibre, writer, "kategorie")
      CalibreHub.write_routes(writer, jobs)
      CalibreHub.trash_routes(trash)

      status, body = call("DELETE", "/api/books/5")
      status.should eq(200)
      body["book"]["title"].should eq("Weg")
      fake.requests.find! { |r| r[0] == "/cdb/cmd/remove/0" }[1].should eq(JSON.parse("[[5], false]"))
      call("DELETE", "/api/books/5")[0].should eq(404)

      status, body = call("GET", "/api/trash")
      status.should eq(200)
      body.as_a.map(&.["id"].as_i).should eq([8, 7])

      status, body = call("POST", "/api/trash/7/restore")
      status.should eq(200)
      body["book"]["id"].should eq(42)
      call("POST", "/api/trash/7/restore")[0].should eq(404)
      call("POST", "/api/trash/x/restore")[0].should eq(404)
    end
  end

  it "accepts delete as the only bulk change" do
    fake = FakeCalibre.new
    writer = CalibreHub::Writer.new(fake.calibre, nil, nil, nil)
    fake.books[1] = "A"
    fake.books[2] = "B"
    jobs = CalibreHub::Jobs.new(state_db, fake.calibre, writer, nil)
    expect_raises(CalibreHub::Edit::Invalid, "only change") do
      jobs.submit(JSON.parse(%({"target":{"ids":[1]},"changes":{"delete":true,"addTags":["x"]}})).as_h)
    end
    expect_raises(CalibreHub::Edit::Invalid, "only change") do
      jobs.submit(JSON.parse(%({"target":{"ids":[1]},"changes":{"delete":false}})).as_h)
    end
    id = jobs.submit(JSON.parse(%({"target":{"ids":[1,2,3]},"changes":{"delete":true}})).as_h).id
    job = wait_job(jobs, id)
    job.done.should eq(3)
    job.errors.map(&.[:bookId]).should eq([3])
    fake.books.should be_empty
  end

  it "counts a book deleted just before a restart as done when resuming" do
    fake = FakeCalibre.new
    writer = CalibreHub::Writer.new(fake.calibre, nil, nil, nil)
    fake.books[2] = "B"
    db = state_db
    db.exec "create table jobs (id text primary key, status text not null, done integer not null default 0, ids text not null, changes text not null, errors text not null default '[]', created_at integer not null)"
    # stopped after deleting 1 but before saving that progress
    db.exec %(insert into jobs (id, status, done, ids, changes, errors, created_at)
      values ('cut', 'running', 1, '[7, 1, 2, 3]', '{"delete": true}', '[]', 0))
    jobs = CalibreHub::Jobs.new(db, fake.calibre, writer, nil)
    job = wait_job(jobs, "cut")
    job.status.should eq("done")
    job.errors.map(&.[:bookId]).should eq([3])
    fake.books.should be_empty
  end
end

private def state_db : DB::Database
  DB.open("sqlite3://#{File.tempname("hub-state", ".sqlite")}?max_pool_size=1")
end

private def wait_job(jobs, id) : CalibreHub::Jobs::Job
  100.times do
    job = jobs[id]?.not_nil!
    return job if job.status != "running"
    sleep 20.milliseconds
  end
  raise "job #{id} still running"
end
