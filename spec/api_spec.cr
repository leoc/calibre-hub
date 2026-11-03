require "spec"
require "../src/calibre_hub/api"

describe CalibreHub::Api do
  it "reads a JSON object body, an empty one as {} unless required" do
    body = ->(text : String?, required : Bool) do
      req = HTTP::Request.new("POST", "/api/x", body: text)
      ctx = HTTP::Server::Context.new(req, HTTP::Server::Response.new(IO::Memory.new))
      CalibreHub.json_body(ctx, required)
    end
    body.call(%({"a":1}), true)["a"].should eq(1)
    body.call("", false).should be_empty
    body.call(nil, false).should be_empty
    expect_raises(CalibreHub::Edit::Invalid, "JSON object expected") { body.call("", true) }
    # an array or a string is a 400, not a 500 from Hash access on JSON::Any
    expect_raises(CalibreHub::Edit::Invalid, "JSON object expected") { body.call("[]", false) }
    expect_raises(CalibreHub::Edit::Invalid, "JSON object expected") { body.call(%("x"), true) }
  end

  it "builds a calibre query from filters" do
    params = HTTP::Params.parse("q=title:x&kategorie=Fachbuch.Software&tag=a&tag=b%22c&author=Douglas%20Adams")
    CalibreHub::Api.query(params, "kategorie").should eq(
      %q{(title:x) and #kategorie:"=.Fachbuch.Software" and tags:"=a" and tags:"=b\"c" and authors:"=Douglas Adams"})
  end

  it "ignores the category filter without a category column" do
    CalibreHub::Api.query(HTTP::Params.parse("kategorie=X"), nil).should eq("")
  end

  it "builds a counted tree from dotted names" do
    tree = CalibreHub::Api.tree([{name: "A.B", count: 2}, {name: "A", count: 1}, {name: "C", count: 3}])
    tree.map(&.["name"].as_s).should eq(["A", "C"])
    tree[0]["count"].as_i.should eq(3)
    tree[0]["children"][0]["path"].as_s.should eq("A.B")
    tree[0]["children"][0]["count"].as_i.should eq(2)
  end
end
