require "spec"
require "../src/calibre_hub/api"

describe CalibreHub::Api do
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
