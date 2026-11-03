require "spec"
require "file_utils"
require "http/server"
require "../src/calibre_hub/inbox"

describe CalibreHub::Inbox do
  it "turns folders into a category and tags" do
    CalibreHub::Inbox.classify("Fachbuch/Software/x.epub").should eq({"Fachbuch.Software", ["Fachbuch", "Software"]})
    CalibreHub::Inbox.classify("x.epub").should eq({nil, [] of String})
  end

  it "removes a book again when setting its fields fails" do
    removed = [] of JSON::Any
    server = HTTP::Server.new do |ctx|
      path = ctx.request.path
      body = ctx.request.body.try(&.gets_to_end) || ""
      ctx.response.content_type = "application/json"
      case path
      when .starts_with?("/cdb/add-book/")
        ctx.response.print %({"book_id": 7})
      when "/cdb/set-fields/7"
        ctx.response.status_code = 400
      when "/cdb/cmd/remove/0"
        removed << JSON.parse(body)
        ctx.response.print %({"result": null})
      else
        ctx.response.status_code = 404
      end
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    dir = File.tempname("inbox-spec")
    begin
      Dir.mkdir_p(File.join(dir, "Roman"))
      File.write(File.join(dir, "Roman", "x.epub"), "epub")
      calibre = CalibreHub::Calibre.new("http://127.0.0.1:#{address.port}", "u", "p")
      detector = CalibreHub::Detector.new(calibre, DB.open("sqlite3://%3Amemory%3A"))
      inbox = CalibreHub::Inbox.new(dir, calibre, detector, "kategorie", stable: 0.seconds)
      inbox.run_once(Time.local + 1.minute).should eq(1)
      removed.should eq([JSON.parse("[[7], true]")])
      # still in the inbox for the next pass
      File.exists?(File.join(dir, "Roman", "x.epub")).should be_true
    ensure
      server.close
      FileUtils.rm_rf(dir)
    end
  end
end
