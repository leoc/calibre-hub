require "spec"
require "../src/calibre_hub/inbox"
require "../src/calibre_hub/handlers/leseliste"

describe CalibreHub::Inbox do
  it "turns folders into a category and tags" do
    CalibreHub::Inbox.classify("Fachbuch/Software/x.epub").should eq({"Fachbuch.Software", ["Fachbuch", "Software"]})
    CalibreHub::Inbox.classify("x.epub").should eq({nil, [] of String})
  end
end

describe CalibreHub::Leseliste do
  it "only reacts to relevant changes of tagged books" do
    tagged = JSON.parse(%({"type":"changed","changes":{"rating":[1,2]},"book":{"tags":["leseliste"]}}))
    CalibreHub::Leseliste.relevant?(tagged, "leseliste", "kategorie").should be_false
    title = JSON.parse(%({"type":"changed","changes":{"title":["a","b"]},"book":{"tags":["Leseliste"]}}))
    CalibreHub::Leseliste.relevant?(title, "leseliste", nil).should be_true
    untag = JSON.parse(%({"type":"changed","changes":{"tags":[["leseliste"],[]]},"book":{"tags":[]}}))
    CalibreHub::Leseliste.relevant?(untag, "leseliste", nil).should be_true
    other = JSON.parse(%({"type":"changed","changes":{"title":["a","b"]},"book":{"tags":["x"]}}))
    CalibreHub::Leseliste.relevant?(other, "leseliste", nil).should be_false
    CalibreHub::Leseliste.relevant?(nil, "leseliste", nil).should be_true
  end

  it "names files like the old export" do
    CalibreHub::Leseliste.series_number(2.0).should eq("02")
    CalibreHub::Leseliste.series_number(2.5).should eq("2.5")
    CalibreHub::Leseliste.clean(%(a/b: "c"?.)).should eq("a_b_ _c__")
  end
end
