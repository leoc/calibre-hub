require "spec"
require "../src/calibre_hub/api"

private TOKEN = "t0ken-0123456789abcdef"
private AUTH  = CalibreHub::Auth.new("arthur", "geheim", ("k" * 32).to_slice, tokens: [TOKEN])

# status and whether the request reached the route
private def call(method, headers = HTTP::Headers.new, path = "/api/books/1")
  h = CalibreHub::AuthHandler.new(AUTH, [] of String)
  reached = false
  h.next = ->(c : HTTP::Server::Context) { reached = true; c.response.status_code = 200; nil }
  ctx = HTTP::Server::Context.new(HTTP::Request.new(method, path, headers), HTTP::Server::Response.new(IO::Memory.new))
  h.call(ctx)
  {ctx.response.status_code, reached}
end

private def bearer(token = TOKEN)
  HTTP::Headers{"Authorization" => "Bearer #{token}"}
end

private def cookie
  "#{CalibreHub::Auth::COOKIE}=#{AUTH.cookie.value}"
end

describe CalibreHub::AuthHandler do
  it "accepts a valid token for reads and writes without the CSRF header" do
    call("GET", bearer).should eq({200, true})
    call("PATCH", bearer).should eq({200, true})
    call("POST", bearer, "/api/books/bulk").should eq({200, true})
  end

  it "rejects invalid or missing tokens" do
    call("GET", bearer("wrong-token-0123456789")).should eq({401, false})
    call("PATCH", bearer("wrong-token-0123456789")).should eq({401, false})
    call("GET").should eq({401, false})
    call("PATCH", HTTP::Headers{"X-Calibre-Hub" => "1"}).should eq({401, false})
  end

  it "doesn't fall back to the session when the token is wrong" do
    h = bearer("wrong-token-0123456789")
    h["Cookie"] = cookie
    h["X-Calibre-Hub"] = "1"
    call("PATCH", h).should eq({401, false})
  end

  it "still needs the CSRF header when a cookie comes along" do
    h = bearer
    h["Cookie"] = cookie
    call("PATCH", h).should eq({403, false})
    h["X-Calibre-Hub"] = "1"
    call("PATCH", h).should eq({200, true})
    call("PATCH", HTTP::Headers{"Cookie" => cookie}).should eq({403, false})
    call("PATCH", HTTP::Headers{"Cookie" => cookie, "X-Calibre-Hub" => "1"}).should eq({200, true})
  end
end
