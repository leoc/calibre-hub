require "spec"
require "http/server"
require "../src/calibre_hub/calibre"

# calibre-server for one book whose comments come from a file (upload,
# inbox, calibre's own import): what the hub serves and writes is cleaned
# (review #8411 H1).
private class CommentsCalibre
  getter url : String
  getter set_fields = [] of JSON::Any

  def initialize(@comments : String)
    @server = HTTP::Server.new do |ctx|
      path = ctx.request.path
      body = ctx.request.body.try(&.gets_to_end) || ""
      ctx.response.content_type = "application/json"
      if path.starts_with?("/cdb/cmd/list/")
        ctx.response.print({result: {book_ids: [1], data: {
          "title" => {"1" => "T"}, "authors" => {"1" => ["A"]}, "comments" => {"1" => @comments},
        }}}.to_json)
      elsif path.starts_with?("/cdb/set-fields/")
        @set_fields << JSON.parse(body)
        ctx.response.print("{}")
      else
        ctx.response.status_code = 404
      end
    end
    @url = "http://127.0.0.1:#{@server.bind_tcp("127.0.0.1", 0).port}"
    spawn { @server.listen }
  end

  def close
    @server.close
  end
end

EVIL = %(<p>Gut</p><script>alert(1)</script><a href="java&#9;script:alert(1)">x</a><svg><a xlink:href="javascript:alert(1)">y</a></svg><img src=x onerror="alert(1)"><base href="https://evil.example/">)

private def no_script(html : String)
  html.should_not match(/script|onerror|<svg|<img|<base|evil/i)
end

describe CalibreHub::Calibre do
  it "serves comments from files cleaned" do
    fake = CommentsCalibre.new(EVIL)
    begin
      book = CalibreHub::Calibre.new(fake.url, "u", "p").book(1).not_nil!
      no_script(book.comments.not_nil!)
      book.comments.not_nil!.should contain("<p>Gut</p>")
    ensure
      fake.close
    end
  end

  it "writes comments cleaned, from any source" do
    fake = CommentsCalibre.new("")
    begin
      CalibreHub::Calibre.new(fake.url, "u", "p").set_fields(1, {"comments" => JSON::Any.new(EVIL), "title" => JSON::Any.new("<b>T</b>")})
      changes = fake.set_fields.first["changes"]
      no_script(changes["comments"].as_s)
      changes["comments"].as_s.should contain("<p>Gut</p>")
      changes["title"].as_s.should eq("<b>T</b>")
    ensure
      fake.close
    end
  end
end
