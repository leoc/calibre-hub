require "spec"
require "kemal"
require "../src/calibre_hub/api"

private def body(json : String) : Hash(String, JSON::Any)
  JSON.parse(json).as_h
end

private def with_progress(&)
  path = File.tempname("hub-progress", ".sqlite")
  db = DB.open("sqlite3://#{path}?max_pool_size=1")
  yield CalibreHub::Progress.new(db)
ensure
  db.try &.close
  File.delete?(path) if path
end

private def call(method, path, body = nil)
  io = IO::Memory.new
  request = HTTP::Request.new(method, path, HTTP::Headers{"X-Calibre-Hub" => "1"}, body)
  ctx = HTTP::Server::Context.new(request, HTTP::Server::Response.new(io))
  Kemal::RouteHandler::INSTANCE.call(ctx)
  ctx.response.close
  response = HTTP::Client::Response.from_io(IO::Memory.new(io.to_s))
  {response.status_code, response.body.presence.try { |b| JSON.parse(b) }}
end

describe CalibreHub::Progress do
  it "keeps one position per user, book and device, newest first" do
    with_progress do |progress|
      t = Time.utc(2026, 11, 2, 10, 0, 0)
      progress.save("arthur", 1, body(%({"format": "EPUB", "position": "epubcfi(/6/4!/4/2)", "fraction": 0.2, "device": "a", "deviceName": "Firefox auf Linux"})), t)
      progress.save("arthur", 1, body(%({"format": "pdf", "position": "12", "fraction": 0.71, "device": "b", "deviceName": "Boox"})), t + 1.minute)
      progress.save("arthur", 2, body(%({"format": "epub", "position": "x", "fraction": 1, "device": "a"})), t + 2.minutes)
      progress.save("tilli", 1, body(%({"format": "epub", "position": "y", "fraction": 0.9, "device": "c"})), t + 3.minutes)

      list = progress.of("arthur", 1)
      list.map(&.device).should eq(%w(b a))
      list[0].format.should eq("pdf")
      list[0].position.should eq("12")
      list[0].fraction.should eq(0.71)
      list[0].source.should eq("web")
      list[1].format.should eq("epub")
      list[1].device_name.should eq("Firefox auf Linux")

      # the same device moves on: replaced, now the newest
      progress.save("arthur", 1, body(%({"format": "epub", "position": "epubcfi(/6/8!/4/2)", "fraction": 0.3, "device": "a", "deviceName": "Firefox auf Linux"})), t + 4.minutes)
      progress.of("arthur", 1).map { |e| {e.device, e.fraction} }.should eq([{"a", 0.3}, {"b", 0.71}])

      # a device without a name is called by its id
      progress.of("arthur", 2)[0].device_name.should eq("a")
      progress.latest("arthur").map { |e| {e.book_id, e.fraction} }.should eq([{1_i64, 0.3}, {2_i64, 1.0}])
      progress.latest("tilli").map(&.book_id).should eq([1_i64])
      progress.of("nobody", 1).should be_empty
    end
  end

  it "rejects broken positions" do
    with_progress do |progress|
      ok = %("format": "epub", "position": "x", "device": "a")
      expect_raises(CalibreHub::Edit::Invalid, "number from 0 to 1") { progress.save("arthur", 1, body(%({#{ok}, "fraction": 1.5}))) }
      expect_raises(CalibreHub::Edit::Invalid, "number from 0 to 1") { progress.save("arthur", 1, body(%({#{ok}}))) }
      expect_raises(CalibreHub::Edit::Invalid, "device id") { progress.save("arthur", 1, body(%({"format": "epub", "position": "x", "device": " ", "fraction": 0}))) }
      expect_raises(CalibreHub::Edit::Invalid, "format") { progress.save("arthur", 1, body(%({"format": "../x", "position": "x", "device": "a", "fraction": 0}))) }
      expect_raises(CalibreHub::Edit::Invalid, "unknown field") { progress.save("arthur", 1, body(%({#{ok}, "fraction": 0, "page": 3}))) }
      expect_raises(CalibreHub::Edit::Invalid, "one of") { progress.save("arthur", 1, body(%({#{ok}, "fraction": 0, "source": "kindle"}))) }
      expect_raises(CalibreHub::Edit::Invalid, "at most") { progress.save("arthur", 1, body(%({"format": "epub", "position": "#{"x" * 5000}", "device": "a", "fraction": 0}))) }
      progress.save("arthur", 1, body(%({#{ok}, "fraction": 0, "source": "koreader"}))).source.should eq("koreader")
    end
  end
end

describe "progress routes" do
  it "serves the progress API" do
    with_progress do |progress|
      auth = CalibreHub::Auth.new("arthur", "pw", Bytes.new(32))
      CalibreHub.progress_routes(progress, auth)

      status, r = call("GET", "/api/books/5/progress")
      status.should eq(200)
      r.not_nil!["latest"].raw.should be_nil
      r.not_nil!["devices"].as_a.should be_empty

      status, r = call("PUT", "/api/books/5/progress", %({"format": "epub", "position": "epubcfi(/6/4!/4/2)", "fraction": 0.63, "device": "d1", "deviceName": "Chrome auf Android"}))
      status.should eq(200)
      r.not_nil!["bookId"].should eq(5)
      r.not_nil!["deviceName"].should eq("Chrome auf Android")
      r.not_nil!["updatedAt"].as_s.should_not be_empty
      call("PUT", "/api/books/5/progress", %({"format": "epub"}))[0].should eq(400)
      call("PUT", "/api/books/5/progress", "nope")[0].should eq(400)
      call("PUT", "/api/books/x/progress", "{}")[0].should eq(404)

      status, r = call("GET", "/api/books/5/progress")
      status.should eq(200)
      r.not_nil!["latest"]["fraction"].should eq(0.63)
      r.not_nil!["latest"]["position"].should eq("epubcfi(/6/4!/4/2)")
      r.not_nil!["devices"].as_a.size.should eq(1)

      status, r = call("GET", "/api/progress")
      status.should eq(200)
      r.not_nil!.as_a.map { |e| {e["bookId"].as_i64, e["fraction"].as_f} }.should eq([{5_i64, 0.63}])
    end
  end
end
