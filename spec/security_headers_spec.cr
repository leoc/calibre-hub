require "spec"
require "../src/calibre_hub/security_headers"

private def headers_for(path, method = "GET")
  io = IO::Memory.new
  ctx = HTTP::Server::Context.new(HTTP::Request.new(method, path), HTTP::Server::Response.new(io))
  h = CalibreHub::SecurityHeadersHandler.new
  h.next = ->(c : HTTP::Server::Context) { c.response.print "ok" }
  h.call(ctx)
  ctx.response.close
  ctx.response.headers
end

private def directives(csp : String)
  csp.split(';').map(&.strip).to_h { |d| {d.split(' ', 2)[0], d.split(' ', 2)[1]? || ""} }
end

describe CalibreHub::SecurityHeadersHandler do
  it "gives the web app a CSP with only its own scripts and no framing from elsewhere" do
    {"/", "/books/12", "/read/3", "/assets/app-abc.js", "/sw.js"}.each do |path|
      h = headers_for(path)
      csp = directives(h["Content-Security-Policy"])
      csp["script-src"].should eq("'self'")
      csp["default-src"].should eq("'self'")
      # not 'none': blob: documents inherit this policy, and WebKit then refuses
      # the reader's book pages, on every book (#8607)
      csp["frame-ancestors"].should eq("'self'")
      csp["object-src"].should eq("'none'")
      csp["base-uri"].should eq("'none'")
      # the reader's book pages (blob: iframes) and pdf.js' worker
      csp["frame-src"].should contain("blob:")
      csp["worker-src"].should contain("'self'")
      csp["connect-src"].should start_with("'self'")
      csp["style-src"].should contain("blob:")
      csp["img-src"].should contain("data:")
      csp["img-src"].should contain("blob:")
      h["Referrer-Policy"].should eq("same-origin")
      h["X-Content-Type-Options"].should eq("nosniff")
      h["X-Frame-Options"].should eq("DENY")
      h["Permissions-Policy"].should contain("camera=()")
    end
  end

  it "allows nothing for API, OPDS and file responses" do
    {"/api/books", "/api/session", "/opds", "/opds/search", "/get/epub/1", "/healthz"}.each do |path|
      h = headers_for(path, path == "/api/session" ? "POST" : "GET")
      csp = directives(h["Content-Security-Policy"])
      csp["default-src"].should eq("'none'")
      csp["frame-ancestors"].should eq("'none'")
      h["Referrer-Policy"].should eq("same-origin")
      h["X-Content-Type-Options"].should eq("nosniff")
    end
  end
end
