require "spec"
require "../src/calibre_hub/body_limit"
require "../src/calibre_hub/api"

# A body the client sends without Content-Length (chunked) and that never ends
private class EndlessIO < IO
  getter read_bytes = 0_i64

  def read(slice : Bytes)
    slice.fill('a'.ord.to_u8)
    @read_bytes += slice.size
    slice.size
  end

  def write(slice : Bytes) : Nil
    raise "read only"
  end
end

private def run(method, path, body : IO | String | Nil, length : Int64? = nil)
  headers = HTTP::Headers.new
  length.try { |l| headers["Content-Length"] = l.to_s }
  req = HTTP::Request.new(method, path, headers, body)
  io = IO::Memory.new
  ctx = HTTP::Server::Context.new(req, HTTP::Server::Response.new(io))
  seen = nil
  h = CalibreHub::BodyLimitHandler.new
  h.next = ->(c : HTTP::Server::Context) { seen = c.request.body.try(&.gets_to_end); c.response.print "ok"; nil }
  h.call(ctx)
  ctx.response.close
  {ctx.response.status_code, seen}
end

describe CalibreHub::BodyLimitHandler do
  it "hands small JSON bodies on unchanged" do
    run("POST", "/api/session", %({"user":"a","password":"b"})).should eq({200, %({"user":"a","password":"b"})})
    run("PATCH", "/api/books/1", %({"title":"T"})).should eq({200, %({"title":"T"})})
  end

  it "refuses an announced body over the limit before reading it" do
    endless = EndlessIO.new
    run("POST", "/api/session", endless, 10_i64 * 1024 * 1024 * 1024)[0].should eq(413)
    endless.read_bytes.should eq(0)
    run("POST", "/api/books/bulk", EndlessIO.new, 2_i64 * 1024 * 1024)[0].should eq(413)
  end

  it "stops reading a body without length at the limit" do
    endless = EndlessIO.new
    status, seen = run("POST", "/api/session", endless)
    status.should eq(413)
    seen.should be_nil
    endless.read_bytes.should be <= CalibreHub::BodyLimitHandler::LOGIN_MAX + 64 * 1024
    endless = EndlessIO.new
    run("PUT", "/api/lists/1", endless)[0].should eq(413)
    endless.read_bytes.should be <= CalibreHub::BodyLimitHandler::JSON_MAX + 64 * 1024
  end

  it "the login is smaller than other JSON" do
    run("POST", "/api/session", "x" * (100 * 1024))[0].should eq(413)
    run("POST", "/api/books/bulk", "x" * (100 * 1024))[0].should eq(200)
  end

  it "leaves book and cover uploads to the routes, which stream with their own limit" do
    CalibreHub::BodyLimitHandler::UPLOAD_MAX.should be >= CalibreHub::Writer::MAX_UPLOAD
    CalibreHub::BodyLimitHandler::COVER_MAX.should be >= CalibreHub::Covers::MAX_BYTES
    run("POST", "/api/books", "x" * (2 * 1024 * 1024), 2_i64 * 1024 * 1024)[0].should eq(200)
    run("PUT", "/api/books/3/cover", "x" * (2 * 1024 * 1024), 2_i64 * 1024 * 1024)[0].should eq(200)
    run("POST", "/api/books", EndlessIO.new, 300_i64 * 1024 * 1024)[0].should eq(413)
  end
end
