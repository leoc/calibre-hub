require "spec"
require "../src/calibre_hub/inbox"

describe CalibreHub::Inbox do
  it "turns folders into a category and tags" do
    CalibreHub::Inbox.classify("Fachbuch/Software/x.epub").should eq({"Fachbuch.Software", ["Fachbuch", "Software"]})
    CalibreHub::Inbox.classify("x.epub").should eq({nil, [] of String})
  end
end
