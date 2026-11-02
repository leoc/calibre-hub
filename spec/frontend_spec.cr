require "spec"
require "file_utils"
require "../src/calibre_hub/frontend"

private def with_dist(&)
  root = File.tempname("hub-dist")
  Dir.mkdir_p(File.join(root, "assets"))
  File.write(File.join(root, "index.html"), "<html>app</html>")
  File.write(File.join(root, "assets", "app-abc123.js"), "js")
  File.write(File.join(root, "manifest.webmanifest"), "{}")
  yield root
ensure
  FileUtils.rm_rf(root) if root
end

private def content_type(handler, path)
  io = IO::Memory.new
  ctx = HTTP::Server::Context.new(HTTP::Request.new("GET", path), HTTP::Server::Response.new(io))
  handler.call(ctx)
  ctx.response.headers["Content-Type"]?
end

private def get(handler, path, method = "GET")
  io = IO::Memory.new
  ctx = HTTP::Server::Context.new(HTTP::Request.new(method, path), HTTP::Server::Response.new(io))
  handler.next = ->(c : HTTP::Server::Context) { c.response.status_code = 299; c.response.print "next" }
  handler.call(ctx)
  ctx.response.close
  {ctx.response.status_code, ctx.response.headers["Cache-Control"]?, io.to_s}
end

describe CalibreHub::FrontendHandler do
  it "serves files, hashed assets immutable, and index.html for app routes" do
    with_dist do |root|
      h = CalibreHub::FrontendHandler.new(root)
      status, cache, body = get(h, "/assets/app-abc123.js")
      cache.should eq("public, max-age=31536000, immutable")
      body.should contain("js")
      _, cache, body = get(h, "/books/123")
      cache.should eq("no-cache")
      body.should contain("<html>app</html>")
      get(h, "/")[2].should contain("<html>app</html>")
      content_type(h, "/manifest.webmanifest").should eq("application/manifest+json")
    end
  end

  it "passes API, OPDS and files on, and does not escape the root" do
    with_dist do |root|
      h = CalibreHub::FrontendHandler.new(root)
      get(h, "/api/books")[0].should eq(299)
      get(h, "/opds")[0].should eq(299)
      get(h, "/get/epub/1")[0].should eq(299)
      get(h, "/api/session", "POST")[0].should eq(299)
      h.resolve("/../../etc/passwd").should be_nil
      h.resolve("/%2e%2e/%2e%2e/etc/passwd").should be_nil
    end
  end
end
