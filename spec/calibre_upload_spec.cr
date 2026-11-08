require "spec"
require "socket"
require "http/server"
require "../src/calibre_hub/calibre"

private alias Calibre = CalibreHub::Calibre

# calibre-server taking book files: what reached it, with the length it was told
private class UploadCalibre
  getter url : String
  getter bodies = [] of {String, Int64, String?}

  def initialize
    @server = HTTP::Server.new do |ctx|
      body = ctx.request.body.try(&.gets_to_end) || ""
      @bodies << {ctx.request.path, body.bytesize.to_i64, ctx.request.headers["Content-Length"]?}
      ctx.response.content_type = "application/json"
      ctx.response.print(ctx.request.path.starts_with?("/cdb/add-book/") ? %({"book_id": 7}) : "{}")
    end
    @url = "http://127.0.0.1:#{@server.bind_tcp("127.0.0.1", 0).port}"
    spawn { @server.listen }
    # listening before a test may close it unused
    Fiber.yield
  end

  def close
    @server.close
  end
end

# calibre-server over its limit: it reads the head, then closes
private class CuttingCalibre
  getter url : String

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @url = "http://127.0.0.1:#{@server.local_address.port}"
    spawn do
      while client = @server.accept?
        sock = client
        spawn do
          while (line = sock.gets) && !line.chomp.empty?
          end
          sock.close
        end
      end
    end
  end

  def close
    @server.close
  end
end

private def with_file(size : Int64, &)
  path = File.tempname("upload", ".pdf")
  File.write(path, "x" * size)
  begin
    yield path
  ensure
    File.delete?(path)
  end
end

describe "Calibre uploads" do
  it "sends a book file as large as the limit, with its length" do
    fake = UploadCalibre.new
    begin
      calibre = Calibre.new(fake.url, "u", "p")
      calibre.max_body = Calibre::MB
      with_file(Calibre::MB) do |path|
        calibre.add_book(path, "a.pdf").book_id.should eq 7
      end
      fake.bodies.size.should eq 1
      fake.bodies[0][1].should eq Calibre::MB
      fake.bodies[0][2].should eq Calibre::MB.to_s
    ensure
      fake.close
    end
  end

  it "doesn't send a book file over the limit, and says why" do
    fake = UploadCalibre.new
    begin
      calibre = Calibre.new(fake.url, "u", "p")
      calibre.max_body = Calibre::MB
      with_file(Calibre::MB + 1) do |path|
        ex = expect_raises(Calibre::TooLarge) { calibre.add_book(path, "a.pdf") }
        ex.message.should eq "file is 1.1 MB, calibre-server takes at most 1.0 MB (calibre-server max request body size)"
      end
      fake.bodies.should be_empty
    ensure
      fake.close
    end
  end

  it "counts a format's body as base64, its share of the limit is three quarters" do
    fake = UploadCalibre.new
    begin
      calibre = Calibre.new(fake.url, "u", "p")
      calibre.max_body = Calibre::MB
      with_file(Calibre::MB // 2) do |path|
        calibre.add_format(3, path, "pdf")
      end
      fake.bodies.size.should eq 1
      with_file(Calibre::MB * 3 // 4) do |path|
        ex = expect_raises(Calibre::TooLarge) { calibre.add_format(3, path, "pdf") }
        ex.message.should eq "file is 0.8 MB, calibre-server takes at most 0.7 MB (calibre-server max request body size)"
      end
      fake.bodies.size.should eq 1
    ensure
      fake.close
    end
  end

  it "checks nothing without a limit" do
    fake = UploadCalibre.new
    begin
      with_file(Calibre::MB + 1) do |path|
        Calibre.new(fake.url, "u", "p").add_book(path, "a.pdf").book_id.should eq 7
      end
    ensure
      fake.close
    end
  end

  it "names the size limit when calibre-server cuts an upload off" do
    fake = CuttingCalibre.new
    begin
      calibre = Calibre.new(fake.url, "u", "p")
      with_file(32 * Calibre::MB) do |path|
        ex = expect_raises(Calibre::Unavailable) { calibre.add_book(path, "a.pdf") }
        ex.message.not_nil!.should start_with "calibre-server closed the connection during a 32 MB upload, " \
                                              "the file may be over calibre-server's max request body size ("
      end
    ensure
      fake.close
    end
  end

  it "reads the limit in MB as calibre-server takes it" do
    Calibre.max_body("2048").should eq 2048_i64 * Calibre::MB
    Calibre.max_body("0.5").should eq Calibre::MB // 2
    Calibre.max_body("").should be_nil
    Calibre.max_body(nil).should be_nil
  end

  it "writes sizes rounded up and limits down" do
    Calibre.mb(915_i64 * Calibre::MB + 1, up: true).should eq "916"
    Calibre.mb(2048_i64 * Calibre::MB, up: false).should eq "2048"
    Calibre.mb(Calibre::MB * 3 // 4, up: false).should eq "0.7"
  end
end
