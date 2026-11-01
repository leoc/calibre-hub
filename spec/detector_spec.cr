require "spec"
require "../src/calibre_hub/calibre"
require "../src/calibre_hub/detector"

private def detector
  CalibreHub::Detector.new(CalibreHub::Calibre.new("http://127.0.0.1:1", "x", "x"), DB.open("sqlite3::memory:"))
end

private def book(**fields)
  JSON.parse({title: "T", tags: [] of String, lastModified: "2026-01-01T00:00:00Z", custom: {kategorie: nil}}
    .merge(fields).to_json)
end

describe CalibreHub::Detector do
  it "reports changed fields with old and new value" do
    detector.diff(book, book(tags: ["leseliste"])).should eq({"tags" => [JSON.parse("[]"), JSON.parse(%(["leseliste"]))]})
  end

  it "ignores lastModified" do
    detector.diff(book, book(lastModified: "2026-02-01T00:00:00Z")).should be_empty
  end

  it "reports custom columns with a # prefix" do
    changes = detector.diff(book, book(custom: {kategorie: "Roman.SciFi"}))
    changes.keys.should eq(["#kategorie"])
  end
end
