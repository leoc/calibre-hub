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

private READER_TOKEN = "lea-token-0123456789abc"
private USERS        = CalibreHub::Auth.new([
  CalibreHub::Auth.account("arthur", "geheim", tokens: [TOKEN]),
  CalibreHub::Auth.account("lea", "lesen", CalibreHub::Auth::Role::Reader, [READER_TOKEN]),
], ("k" * 32).to_slice)

# status, the user the route saw (nil: not reached) and the body it read
private def as_user(token, method, path, body : String? = nil)
  h = CalibreHub::AuthHandler.new(USERS, [] of String)
  seen = nil
  read = nil
  h.next = ->(c : HTTP::Server::Context) do
    seen = USERS.user
    read = c.request.body.try(&.gets_to_end)
    c.response.status_code = 200
    nil
  end
  req = HTTP::Request.new(method, path, HTTP::Headers{"Authorization" => "Bearer #{token}"}, body)
  ctx = HTTP::Server::Context.new(req, HTTP::Server::Response.new(IO::Memory.new))
  h.call(ctx)
  {ctx.response.status_code, seen, read}
end

describe "AuthHandler with several users" do
  it "runs the request as its user" do
    as_user(TOKEN, "GET", "/api/books")[0..1].should eq({200, "arthur"})
    as_user(READER_TOKEN, "GET", "/api/books")[0..1].should eq({200, "lea"})
    expect_raises(CalibreHub::Auth::NoUser) { USERS.user }
  end

  it "lets a reader read and change only their own things" do
    as_user(READER_TOKEN, "GET", "/api/trash")[0].should eq(200)
    as_user(READER_TOKEN, "PUT", "/api/books/1/progress", "{}")[0].should eq(200)
    as_user(READER_TOKEN, "PUT", "/api/reader/settings", "{}")[0].should eq(200)
    as_user(READER_TOKEN, "POST", "/api/lists", %({"name":"Meine"}))[0].should eq(200)
    as_user(READER_TOKEN, "PUT", "/api/lists/3/books/1")[0].should eq(200)
    as_user(READER_TOKEN, "DELETE", "/api/session")[0].should eq(200)
  end

  it "keeps a reader from changing the library" do
    as_user(READER_TOKEN, "PATCH", "/api/books/1", "{}").should eq({403, nil, nil})
    as_user(READER_TOKEN, "POST", "/api/books/bulk", "{}")[0].should eq(403)
    as_user(READER_TOKEN, "POST", "/api/books")[0].should eq(403)
    as_user(READER_TOKEN, "DELETE", "/api/books/1")[0].should eq(403)
    as_user(READER_TOKEN, "POST", "/api/trash/1/restore")[0].should eq(403)
    as_user(READER_TOKEN, "POST", "/api/some/route/added/later")[0].should eq(403)
    as_user(TOKEN, "PATCH", "/api/books/1", "{}").should eq({200, "arthur", "{}"})
  end

  it "keeps a reader's lists off the reader folder, with the body intact for the route" do
    as_user(READER_TOKEN, "PATCH", "/api/lists/3", %({"sync":true}))[0].should eq(403)
    as_user(READER_TOKEN, "POST", "/api/lists", %({"name":"x","sync":true}))[0].should eq(403)
    as_user(READER_TOKEN, "PATCH", "/api/lists/3", %({"sync":false,"name":"y"})).should eq({200, "lea", %({"sync":false,"name":"y"})})
    as_user(TOKEN, "PATCH", "/api/lists/3", %({"sync":true}))[0].should eq(200)
  end
end
