require "spec"
require "../src/calibre_hub/edit"
require "../src/calibre_hub/writer"

private def book(tags = ["Leseliste", "SF"])
  CalibreHub::Book.new(id: 1_i64, title: "T", authors: ["A"], author_sort: "A", tags: tags,
    series: nil, series_index: nil, formats: ["EPUB"], last_modified: Time.utc(2026, 11, 2, 6, 0, 0, nanosecond: 123_456_000),
    timestamp: nil, pubdate: nil, rating: nil, publisher: nil, identifiers: {} of String => String,
    languages: [] of String, comments: nil, custom: {} of String => JSON::Any)
end

private def changes(json, current = book)
  CalibreHub::Edit.changes(JSON.parse(json).as_h, current, "kategorie")
end

describe CalibreHub::Edit do
  it "maps fields to calibre names" do
    c = changes(%({"title":" New ","series":"S","seriesIndex":2,"kategorie":"A.B","pubdate":"2020-05-01","rating":8,"identifiers":{"isbn":"123","x":""}}))
    c["title"].should eq("New")
    c["series"].should eq("S")
    c["series_index"].should eq(2.0)
    c["#kategorie"].should eq("A.B")
    c["pubdate"].should eq("2020-05-01T12:00:00+00:00")
    c["rating"].should eq(8)
    c["identifiers"].as_h.should eq({"isbn" => JSON::Any.new("123")})
  end

  it "clears with null" do
    c = changes(%({"series":null,"kategorie":null,"rating":0,"pubdate":null,"comments":""}))
    c.values.all?(&.raw.nil?).should be_true
  end

  it "adds and removes tags against the current ones, case-insensitively" do
    changes(%({"addTags":["neu","sf"],"removeTags":["leseliste"]}))["tags"].as_a.map(&.as_s).should eq(["SF", "neu"])
  end

  it "rejects invalid input with the field" do
    expect_raises(CalibreHub::Edit::Invalid, "unknown field") { changes(%({"bogus":1})) }
    expect_raises(CalibreHub::Edit::Invalid, "combined") { changes(%({"tags":[],"addTags":["x"]})) }
    expect_raises(CalibreHub::Edit::Invalid, "empty") { changes(%({"title":"  "})) }
    expect_raises(CalibreHub::Edit::Invalid, "author") { changes(%({"authors":[]})) }
    expect_raises(CalibreHub::Edit::Invalid, "0-10") { changes(%({"rating":11})) }
    expect_raises(CalibreHub::Edit::Invalid, "YYYY") { changes(%({"pubdate":"1.5.2020"})) }
  end

  it "sanitizes comments" do
    changes(%({"comments":"<p onclick=\\"x()\\">Hi <script>alert(1)</script><font>du</font> <a href=\\"javascript:x\\">j</a> <a href=\\"https://e.org\\">e</a></p>"}))["comments"]
      .should eq(%(<p>Hi du <a>j</a> <a href="https://e.org" rel="noopener noreferrer">e</a></p>))
  end

  it "detects conflicts only when lastModified is given and differs" do
    current = book
    read = current.version
    CalibreHub::Edit.conflict?({} of String => JSON::Any, current).should be_false
    CalibreHub::Edit.conflict?({"lastModified" => JSON::Any.new(read)}, current).should be_false
    CalibreHub::Edit.conflict?({"lastModified" => JSON::Any.new("2020-01-01T00:00:00Z")}, current).should be_true
  end
end

describe CalibreHub::Sanitizer do
  it "keeps allowed markup, unwraps unknown tags and drops dangerous ones" do
    CalibreHub::Sanitizer.clean("<h2 style='x'>T</h2><ul><li>a<br>b</li></ul><style>p{}</style><iframe src=x></iframe>&lt;x&gt;")
      .should eq("<h2>T</h2><ul><li>a<br>b</li></ul>&lt;x&gt;")
    CalibreHub::Sanitizer.clean("plain & simple").should eq("plain &amp; simple")
  end
end

describe CalibreHub::Writer do
  it "reads a multipart upload" do
    io = IO::Memory.new
    builder = HTTP::FormData::Builder.new(io, "BOUNDARY")
    builder.file("file", IO::Memory.new("data"), HTTP::FormData::FileMetadata.new(filename: "../x/Buch.epub"))
    builder.field("tags", "a")
    builder.field("tags", "b")
    builder.field("kategorie", "Fachbuch")
    builder.field("force", "1")
    builder.finish
    request = HTTP::Request.new("POST", "/api/books",
      HTTP::Headers{"Content-Type" => builder.content_type}, io.to_s)
    u = CalibreHub::Writer.read_upload(request)
    u.filename.should eq("Buch.epub")
    File.read(u.file).should eq("data")
    u.tags.should eq(["a", "b"])
    u.kategorie.should eq("Fachbuch")
    u.force.should be_true
    File.delete(u.file)
  end

  it "rejects unknown formats" do
    CalibreHub::Writer.extension("x.EPUB").should eq("epub")
    expect_raises(CalibreHub::Writer::Unsupported) { CalibreHub::Writer.extension("x.exe") }
    expect_raises(CalibreHub::Writer::Unsupported) { CalibreHub::Writer.extension("x.recipe") }
  end
end
