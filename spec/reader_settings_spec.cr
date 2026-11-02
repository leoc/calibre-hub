require "spec"
require "kemal"
require "../src/calibre_hub/api"

private def body(json : String) : Hash(String, JSON::Any)
  JSON.parse(json).as_h
end

private def with_settings(&)
  path = File.tempname("hub-reader-settings", ".sqlite")
  db = DB.open("sqlite3://#{path}?max_pool_size=1")
  yield CalibreHub::ReaderSettings.new(db), db
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

describe CalibreHub::ReaderSettings do
  it "starts with the defaults and keeps changes per user" do
    with_settings do |settings|
      defaults = settings.of("arthur")
      defaults["fontFamily"].should eq("original")
      defaults["fontSize"].should eq(100)
      defaults["lineHeight"].should eq(1.5)
      defaults["columns"].should eq("auto")
      defaults["theme"].should eq("light")
      defaults["override"].should eq(false)

      saved = settings.save("arthur", body(%({"fontSize": 135, "theme": "sepia", "lineHeight": 1.8, "override": true})))
      saved["fontSize"].should eq(135)
      saved["theme"].should eq("sepia")
      # the rest stays
      saved["flow"].should eq("paginated")

      # a second change keeps the first
      settings.save("arthur", body(%({"columns": "1", "fontFamily": "literata", "maxWidth": 900.0})))
      now = settings.of("arthur")
      now["fontSize"].should eq(135)
      now["columns"].should eq("1")
      now["fontFamily"].should eq("literata")
      now["maxWidth"].should eq(900)
      now["lineHeight"].should eq(1.8)
      now.keys.should eq(CalibreHub::ReaderSettings::DEFAULTS.keys)

      settings.of("tilli")["fontSize"].should eq(100)
    end
  end

  it "rejects bad values" do
    with_settings do |settings|
      expect_raises(CalibreHub::Edit::Invalid, "unknown field") { settings.save("arthur", body(%({"zoom": 2}))) }
      expect_raises(CalibreHub::Edit::Invalid, "whole number from 50 to 300") { settings.save("arthur", body(%({"fontSize": 20}))) }
      expect_raises(CalibreHub::Edit::Invalid, "whole number") { settings.save("arthur", body(%({"fontSize": 110.5}))) }
      expect_raises(CalibreHub::Edit::Invalid, "whole number") { settings.save("arthur", body(%({"fontSize": "120"}))) }
      expect_raises(CalibreHub::Edit::Invalid, "number from 1.0 to 2.5") { settings.save("arthur", body(%({"lineHeight": 3}))) }
      expect_raises(CalibreHub::Edit::Invalid, "one of") { settings.save("arthur", body(%({"fontFamily": "Comic Sans"}))) }
      expect_raises(CalibreHub::Edit::Invalid, "one of") { settings.save("arthur", body(%({"columns": 2}))) }
      expect_raises(CalibreHub::Edit::Invalid, "one of") { settings.save("arthur", body(%({"theme": "night"}))) }
      expect_raises(CalibreHub::Edit::Invalid, "true or false") { settings.save("arthur", body(%({"justify": "yes"}))) }
      expect_raises(CalibreHub::Edit::Invalid, "whole number from 0 to 20") { settings.save("arthur", body(%({"margin": -1}))) }
      expect_raises(CalibreHub::Edit::Invalid, "whole number from 400 to 2000") { settings.save("arthur", body(%({"maxWidth": 10000}))) }
      # nothing of a rejected change is stored
      expect_raises(CalibreHub::Edit::Invalid) { settings.save("arthur", body(%({"fontSize": 120, "theme": "night"}))) }
      settings.of("arthur")["fontSize"].should eq(100)
    end
  end

  it "falls back to the default for stored values that are no longer valid" do
    with_settings do |settings, db|
      db.exec "insert into reader_settings (user, settings, updated_at) values ('arthur', ?, 0)", %({"fontSize": 999, "theme": "dark", "old": 1})
      now = settings.of("arthur")
      now["fontSize"].should eq(100)
      now["theme"].should eq("dark")
      now.has_key?("old").should be_false
    end
  end
end

describe "reader settings routes" do
  it "serves GET and PUT /api/reader/settings" do
    with_settings do |settings|
      auth = CalibreHub::Auth.new("arthur", "pw", Bytes.new(32))
      CalibreHub.reader_settings_routes(settings, auth)

      status, r = call("GET", "/api/reader/settings")
      status.should eq(200)
      r.not_nil!["fontSize"].should eq(100)

      status, r = call("PUT", "/api/reader/settings", %({"fontSize": 150, "flow": "scrolled"}))
      status.should eq(200)
      r.not_nil!["fontSize"].should eq(150)
      r.not_nil!["flow"].should eq("scrolled")

      status, r = call("PUT", "/api/reader/settings", %({"fontSize": 1000}))
      status.should eq(400)
      r.not_nil!["field"].should eq("fontSize")
      call("PUT", "/api/reader/settings", "nope")[0].should eq(400)
      call("PUT", "/api/reader/settings", "[1]")[0].should eq(400)

      status, r = call("GET", "/api/reader/settings")
      status.should eq(200)
      r.not_nil!["fontSize"].should eq(150)
    end
  end
end
