require "spec"
require "file_utils"
require "kemal"
require "../src/calibre_hub/duplicates"

private def book(id : Int64, title : String, authors = ["Daniel Chidiac"], formats = ["EPUB"], isbn : String? = nil,
                 tags = [] of String, series : String? = nil, series_index : Float64? = nil, publisher : String? = nil,
                 comments : String? = nil, pubdate : Time? = nil, identifiers : Hash(String, String)? = nil,
                 languages = [] of String) : CalibreHub::Book
  ids = identifiers || (isbn ? {"isbn" => isbn} : {} of String => String)
  CalibreHub::Book.new(id: id, title: title, authors: authors, author_sort: nil, tags: tags, series: series,
    series_index: series ? (series_index || 1.0) : nil, formats: formats, last_modified: Time::UNIX_EPOCH,
    timestamp: nil, pubdate: pubdate, rating: nil, publisher: publisher, identifiers: ids,
    languages: languages, comments: comments, custom: {} of String => JSON::Any)
end

private def item(b : CalibreHub::Book, sizes : Hash(String, Int64)? = nil)
  CalibreHub::Dedup::Item.new(b, sizes.try(&.map { |f, s| CalibreHub::Dedup::FileInfo.new(f, s, "/lib/#{b.id}/x.#{f.downcase}") }))
end

private def kinds(pairs, a : Int64, b : Int64) : Array(String)
  (pairs[{a, b}]? || [] of CalibreHub::Dedup::Reason).map(&.kind).sort
end

describe CalibreHub::Dedup do
  it "pairs the same title and author, ignoring case, despite different editions (#5/#26)" do
    a = item(book(5, "Stop Letting Everything Affect You: How to Break Free From Overthinking, Emotional Chaos, and Self-Sabotage", isbn: "9781764110822"))
    b = item(book(26, "Stop Letting Everything Affect You: How to break free from overthinking, emotional chaos, and self-sabotage", isbn: "9781764110808"))
    pairs = CalibreHub::Dedup.pairs([a, b])
    kinds(pairs, 5, 26).should eq(["title"])
    pairs[{5_i64, 26_i64}][0].detail.should eq("1.0")
    CalibreHub::Dedup.groups(pairs).should eq([[5_i64, 26_i64]])
  end

  it "pairs an Anna's Archive leftover with the good copy by its ISBN and title (#14/#25)" do
    good = item(book(14, "Implementing ISO 9001:2015", ["Jan Gillett", "Paul Simpson"], ["PDF"], isbn: "9781908984500"), {"PDF" => 3_000_000_i64})
    leftover = item(book(25, "Implementing ISO 9001 2015 thrill your customers and -- Gillett, Jan -- BusinessPro collection, Oxford, United Kingdom, 2015 -- Infinite Ideas -- 9781908984500 -- -- Anna’s Archive",
      ["Unknown"], ["PDF"]), {"PDF" => 80_i64})
    leftover.author_keys.should eq(Set{CalibreHub::Meta::Authors.key("Jan Gillett")})
    leftover.isbns.should eq(Set{"9781908984500"})
    leftover.broken?.should be_true
    good.broken?.should be_false
    pairs = CalibreHub::Dedup.pairs([good, leftover])
    kinds(pairs, 14, 25).should eq(["broken", "isbn", "title"])
    CalibreHub::Dedup.keep([good, leftover], {} of Int64 => Bool).should eq(14)
    # the same without the ISBN in the title: the title and the broken file
    bare = item(book(25, "Implementing ISO 9001 2015 thrill your customers", ["Unknown"], ["PDF"]), {"PDF" => 80_i64})
    kinds(CalibreHub::Dedup.pairs([good, bare]), 14, 25).should eq(["broken", "title"])
  end

  it "keeps volumes, series numbers and other books of an author apart" do
    list = [
      item(book(1, "Das Lied von Eis und Feuer, Band 1")),
      item(book(2, "Das Lied von Eis und Feuer, Band 2")),
      item(book(3, "Dune", ["Frank Herbert"], series: "Dune", series_index: 1.0)),
      item(book(4, "Dune", ["Frank Herbert"], series: "Dune", series_index: 2.0)),
      item(book(5, "The Lord of the Rings: The Two Towers", ["J. R. R. Tolkien"])),
      item(book(6, "The Lord of the Rings: The Return of the King", ["J. R. R. Tolkien"])),
      item(book(7, "Ganz anderes Buch")),
      item(book(8, "Dune", ["Brian Herbert"])),
      # two editions of a standard, a draft and the final one
      item(book(9, "DIN EN ISO 11073-10102:2013-07 (Entwurf) – Mit Annotationen versehenes EKG", ["DIN"])),
      item(book(10, "DIN EN ISO 11073-10102:2014-06 – Mit Annotationen versehenes EKG", ["DIN"])),
    ]
    CalibreHub::Dedup.pairs(list).should be_empty
    CalibreHub::Dedup.pairs(list[8, 2], threshold: 0.5).should be_empty
    # the same edition twice is a pair
    norm = item(book(11, "DIN EN ISO 11073-10102:2014-06 – Mit Annotationen versehenes EKG", ["DIN"]))
    CalibreHub::Dedup.pairs([list[9], norm]).keys.should eq([{10_i64, 11_i64}])
  end

  it "matches authors written differently and takes the threshold" do
    a = item(book(1, "Thinking, Fast and Slow", ["Daniel Kahneman"]))
    b = item(book(2, "Thinking Fast & Slow", ["Kahneman, Daniel"]))
    kinds(CalibreHub::Dedup.pairs([a, b]), 1, 2).should eq(["title"])
    c = item(book(3, "Schnelles Denken langsames Denken heute", ["Daniel Kahneman"]))
    d = item(book(4, "Schnelles Denken langsames Denken", ["Daniel Kahneman"]))
    CalibreHub::Dedup.similarity(c, d).should eq(0.9)
    CalibreHub::Dedup.pairs([c, d], threshold: 0.95).should be_empty
    CalibreHub::Dedup.pairs([c, d], threshold: 0.85).size.should eq(1)
    # without a known author it takes 0.9 at least
    e = item(book(5, "Schnelles Denken langsames Denken", ["Unbekannt"]))
    f = item(book(6, "Schnelles Denken, langsames Denken aus der Praxis", ["Daniel Kahneman"]))
    CalibreHub::Dedup.pairs([e, f], threshold: 0.6).size.should eq(1)
    g = item(book(7, "Schnelles Denken kurz erklärt", ["Unbekannt"]))
    CalibreHub::Dedup.pairs([g, f], threshold: 0.6).should be_empty
  end

  it "pairs the same file by size and checksum, not tiny ones" do
    a = item(book(1, "Eins", ["A"]), {"EPUB" => 50_000_i64})
    b = item(book(2, "Zwei", ["B"]), {"EPUB" => 50_000_i64})
    c = item(book(3, "Drei", ["C"]), {"EPUB" => 50_000_i64})
    d = item(book(4, "Vier", ["D"]), {"EPUB" => 100_i64})
    e = item(book(5, "Fünf", ["E"]), {"EPUB" => 100_i64})
    asked = [] of String
    sums = ->(f : CalibreHub::Dedup::FileInfo) { asked << f.path.not_nil!; (f.path.not_nil!.includes?("/3/") ? "other" : "same").as(String?) }
    pairs = CalibreHub::Dedup.pairs([a, b, c, d, e], checksum: sums)
    pairs.keys.should eq([{1_i64, 2_i64}])
    pairs[{1_i64, 2_i64}][0].kind.should eq("file")
    asked.size.should eq(3)
  end

  it "leaves out ignored pairs and joins groups over shared books" do
    a = item(book(1, "Buch", isbn: "9783161484100"))
    b = item(book(2, "Buch", isbn: "9783161484100"))
    c = item(book(3, "Anderes", ["X"], isbn: "9783161484100"))
    pairs = CalibreHub::Dedup.pairs([a, b, c])
    CalibreHub::Dedup.groups(pairs).should eq([[1_i64, 2_i64, 3_i64]])
    pairs = CalibreHub::Dedup.pairs([a, b, c], ignored: Set{ {1_i64, 3_i64}, {2_i64, 3_i64} })
    CalibreHub::Dedup.groups(pairs).should eq([[1_i64, 2_i64]])
  end

  it "keeps the most complete good copy" do
    plain = item(book(1, "Buch"))
    full = item(book(2, "Buch", isbn: "9783161484100", publisher: "Verlag", tags: ["Roman"]))
    CalibreHub::Dedup.keep([plain, full], {} of Int64 => Bool).should eq(2)
    # a cover counts
    CalibreHub::Dedup.keep([plain, item(book(3, "Buch"))], {3_i64 => true}).should eq(3)
    # the oldest on a tie
    CalibreHub::Dedup.keep([item(book(9, "Buch")), item(book(4, "Buch"))], {} of Int64 => Bool).should eq(4)
    # EPUB before PDF
    CalibreHub::Dedup.keep([item(book(1, "Buch", formats: ["PDF"])), item(book(5, "Buch", formats: ["EPUB"]))], {} of Int64 => Bool).should eq(5)
  end

  it "fills empty fields and joins tags and identifiers" do
    keep = book(1, "Buch", ["Unknown"], tags: ["Roman", "auto-metadaten"], identifiers: {"isbn" => "9783161484100"})
    a = book(2, "Buch", ["Ada Lovelace"], tags: ["roman", "Neu", "auto-metadaten"], publisher: "Verlag",
      pubdate: Time.utc(2025, 6, 30, 23, 0, 0), identifiers: {"isbn" => "9780000000002", "goodreads" => "7"},
      series: "Reihe", series_index: 3.0)
    b = book(3, "Buch", ["Grace Hopper"], publisher: "Anderer", comments: "<p>Text</p>", languages: ["deu"])
    body = CalibreHub::Dedup.fill(keep, [a, b])
    body["authors"].should eq(JSON.parse(%(["Ada Lovelace"])))
    body["publisher"].should eq("Verlag")
    body["pubdate"].should eq("2025-07-01")
    body["series"].should eq("Reihe")
    body["seriesIndex"].should eq(3.0)
    body["comments"].should eq("<p>Text</p>")
    body["languages"].should eq(JSON.parse(%(["deu"])))
    body["identifiers"].should eq(JSON.parse(%({"isbn": "9783161484100", "goodreads": "7"})))
    body["tags"].should eq(JSON.parse(%(["Roman", "auto-metadaten", "Neu"])))
    CalibreHub::Dedup.fill(book(1, "Buch", tags: ["x"]), [book(2, "Buch", tags: ["X"])]).should be_empty
  end

  it "reads calibre's midnight dates as that day" do
    CalibreHub::Dedup.day(Time.utc(2025, 6, 30, 23, 0, 0)).should eq("2025-07-01")
    CalibreHub::Dedup.day(Time.utc(2025, 7, 1, 12, 0, 0)).should eq("2025-07-01")
    CalibreHub::Dedup.day(Time.utc(2015, 10, 8, 11, 16, 50)).should eq("2015-10-08")
  end
end

# calibre-server for merges: list, set-fields (fields, formats, cover),
# remove (into <library>/.caltrash), add (restore), remove_format, /get
private class FakeServer
  getter books = {} of Int64 => Hash(String, JSON::Any)
  getter files = {} of {Int64, String} => String
  getter covers = {} of Int64 => Bytes
  getter requests = [] of {String, JSON::Any}
  property next_id = 100_i64
  getter url : String
  getter library : String

  def initialize(@library : String)
    @server = HTTP::Server.new do |ctx|
      path = ctx.request.path
      raw = ctx.request.body.try(&.gets_to_end).presence
      body = raw ? JSON.parse(raw) : JSON::Any.new(nil)
      @requests << {path, body}
      ctx.response.content_type = "application/json"
      case path
      when "/cdb/cmd/list/0"
        search = body[3].as_s
        ids = search.empty? ? @books.keys.sort : search.scan(/id:(\d+)/).map(&.[1].to_i64).select { |id| @books.has_key?(id) }
        fields = body[0].as_a.map(&.as_s.sub('*', '#'))
        data = fields.to_h do |f|
          {f, ids.to_h { |id| {id.to_s, f == "cover" ? JSON::Any.new(@covers.has_key?(id) ? "/c" : nil) : (@books[id][f]? || JSON::Any.new(nil))} }}
        end
        ctx.response.print({result: {book_ids: ids, data: data}}.to_json)
      when .starts_with?("/cdb/set-fields/")
        id = path.split('/')[3].to_i64
        body["changes"].as_h.each do |k, v|
          case k
          when "cover"
            if s = v.as_s?
              @covers[id] = Base64.decode(s.split(",", 2)[1])
            else
              @covers.delete(id)
            end
          when "added_formats"
            v.as_a.each do |f|
              ext = f["ext"].as_s.upcase
              @files[{id, ext}] = String.new(Base64.decode(f["data_url"].as_s))
              formats = @books[id]["formats"].as_a.map(&.as_s)
              @books[id]["formats"] = JSON.parse((formats + [ext]).uniq.to_json)
            end
          when "last_modified" then nil
          else                      @books[id][k] = v
          end
        end
        touch(id)
        ctx.response.print "{}"
      when "/cdb/cmd/remove/0"
        body[0].as_a.each do |v|
          id = v.as_i64
          b = @books.delete(id) || next
          dir = File.join(@library, ".caltrash", "b", id.to_s)
          Dir.mkdir_p(dir)
          File.write(File.join(dir, "metadata.opf"), %(<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>#{b["title"]}</dc:title><dc:creator>#{b["authors"][0]}</dc:creator></metadata></package>))
          b["formats"].as_a.each { |f| File.write(File.join(dir, "book.#{f.as_s.downcase}"), @files[{id, f.as_s}]? || "") }
          @covers[id]?.try { |c| File.write(File.join(dir, "cover.jpg"), c) }
        end
        ctx.response.print %({"result":null})
      when "/cdb/cmd/add/0"
        id = @next_id
        @next_id += 1
        add(id, body[1]["v"]["title"].as_s, formats: [] of String)
        ctx.response.print({result: [[id], false]}.to_json)
      when "/cdb/cmd/remove_format/0"
        id, fmt = body[0].as_i64, body[1].as_s
        @books[id]["formats"] = JSON.parse((@books[id]["formats"].as_a.map(&.as_s) - [fmt]).to_json)
        touch(id)
        ctx.response.print %({"result":null})
      when %r{\A/get/cover/(\d+)}
        id = $1.to_i64
        if c = @covers[id]?
          ctx.response.write(c)
        else
          ctx.response.status_code = 404
        end
      when %r{\A/get/(\w+)/(\d+)}
        fmt, id = $1.upcase, $2.to_i64
        if f = @files[{id, fmt}]?
          ctx.response.print f
        else
          ctx.response.status_code = 404
        end
      else
        ctx.response.status_code = 404
      end
    end
    address = @server.bind_tcp("127.0.0.1", 0)
    @url = "http://127.0.0.1:#{address.port}"
    spawn { @server.listen }
  end

  def touch(id)
    @books[id]["last_modified"] = JSON::Any.new(Time.utc.to_rfc3339(fraction_digits: 6))
    sleep 1.millisecond
  end

  def add(id : Int64, title : String, authors = ["Ada Lovelace"], formats = ["EPUB"], **fields)
    b = {
      "title"         => JSON::Any.new(title),
      "authors"       => JSON.parse(authors.to_json),
      "tags"          => JSON.parse("[]"),
      "identifiers"   => JSON.parse("{}"),
      "languages"     => JSON.parse("[]"),
      "formats"       => JSON.parse(formats.to_json),
      "last_modified" => JSON::Any.new("2026-11-02T10:00:00+00:00"),
    }
    fields.each { |k, v| b[k.to_s] = JSON.parse(v.to_json) }
    @books[id] = b
    formats.each { |f| @files[{id, f}] = "#{f} of #{id} " * 200 }
  end

  def calibre : CalibreHub::Calibre
    CalibreHub::Calibre.new(url, "hub", "pw", nil, ["kategorie"])
  end
end

private PNG = Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0]

private def merge_setup(&)
  dir = File.tempname("dedup-spec")
  Dir.mkdir_p(dir)
  fake = FakeServer.new(dir)
  db = DB.open("sqlite3://#{File.join(dir, "state.sqlite")}?max_pool_size=1")
  writer = CalibreHub::Writer.new(fake.calibre, nil, nil, "kategorie")
  lists = CalibreHub::Lists.new(db)
  trash = CalibreHub::Trash.new(fake.calibre, writer, dir, db, ->(d : String) {
    title = File.read(File.join(d, "metadata.opf"))[/<dc:title>([^<]*)/, 1]
    JSON.parse({"jPoAv3zOyHvQ5JFNYg4hJ9" => 2, "v" => {"title" => title}}.to_json)
  })
  trash.on_restore = ->(old_id : Int64, new_id : Int64) { lists.book_restored(old_id, new_id) }
  dups = CalibreHub::Duplicates.new(fake.calibre, writer, db, dir, "kategorie", lists, trash)
  progress = CalibreHub::Progress.new(db)
  yield fake, dups, lists, progress, db
ensure
  dir.try { |d| FileUtils.rm_rf(d) }
end

private def body(json : String) : Hash(String, JSON::Any)
  JSON.parse(json).as_h
end

describe CalibreHub::Duplicates do
  it "finds groups in the library with the suggested keeper" do
    merge_setup do |fake, dups, _, _, _|
      fake.add(1, "Testbuch", tags: ["Roman"], identifiers: {"isbn" => "9783161484100"})
      fake.add(2, "testbuch")
      fake.add(3, "Ganz anders", ["Grace Hopper"])
      groups = dups.groups
      groups.map(&.ids).should eq([[1_i64, 2_i64]])
      groups[0].keep_id.should eq(1)
      groups[0].sure.should be_true
      json = JSON.parse(JSON.build { |j| dups.group_json(j, groups[0], nil) })
      json["id"].should eq("1-2")
      json["books"].as_a.map(&.["book"]["id"].as_i).should eq([1, 2])
      json["reasons"][0]["kind"].should eq("title")
      dups.similar(2).map(&.id).should eq([1])
      dups.ignore([1_i64, 2_i64]).should eq(1)
      dups.groups.should be_empty
      dups.ignore([1_i64, 2_i64], undo: true).should eq(1)
      dups.groups.size.should eq(1)
    end
  end

  it "merges into the keeper, trashes the other and undoes it" do
    merge_setup do |fake, dups, lists, progress, db|
      fake.add(1, "Testbuch", formats: ["EPUB"], tags: ["Roman"], identifiers: {"isbn" => "9783161484100"})
      fake.add(2, "Testbuch", formats: ["PDF", "EPUB"], tags: ["Neu", "auto-metadaten"], publisher: "Verlag",
        identifiers: {"goodreads" => "7"})
      fake.covers[2] = PNG
      l1 = lists.create("arthur", body(%({"name": "Leseliste"})))
      l2 = lists.create("arthur", body(%({"name": "Urlaub"})))
      lists.add(l1.id, "arthur", [1_i64, 2_i64])
      lists.add(l2.id, "arthur", [2_i64])
      progress.save("arthur", 2, body(%({"format": "pdf", "position": "12", "fraction": 0.4, "device": "boox"})))

      plan = JSON.parse(dups.plan_json(dups.plan(1, [2_i64])))
      plan["formats"].should eq(JSON.parse(%([{"format": "PDF", "from": 2, "replace": false}])))
      plan["fields"].as_a.map(&.["field"].as_s).sort.should eq(["identifiers", "publisher", "tags"])
      plan["coverFrom"].should eq(2)
      plan["lists"].should eq(1)
      plan["progress"].should eq(1)
      plan["trash"].should eq(JSON.parse("[2]"))

      m, book = dups.merge(1, [2_i64])
      m.status.should eq("done")
      book.formats.sort.should eq(["EPUB", "PDF"])
      book.publisher.should eq("Verlag")
      book.tags.should eq(["Roman", "Neu"])
      book.identifiers.should eq({"isbn" => "9783161484100", "goodreads" => "7"})
      fake.files[{1_i64, "PDF"}].should start_with("PDF of 2")
      fake.covers[1]?.should eq(PNG)
      fake.books.has_key?(2_i64).should be_false
      dups.merges.map(&.id).should eq([m.id])
      lists.memberships([1_i64], "arthur")[1].sort.should eq([l1.id, l2.id].sort)
      progress.of("arthur", 1).map(&.position).should eq(["12"])
      fake.requests.none? { |r| r[0] == "/cdb/cmd/remove/0" && r[1][1] == JSON::Any.new(true) }.should be_true
      # the other left its lists (its deleted event)
      lists.book_deleted(2)

      # the keeper changed meanwhile: that field stays
      fake.books[1]["publisher"] = JSON::Any.new("Selbst")
      undone, books = dups.undo(m.id)
      undone.status.should eq("undone")
      new_id = undone.restored["2"]
      books.map(&.id).should eq([1, new_id])
      keep = books[0]
      keep.formats.should eq(["EPUB"])
      keep.tags.should eq(["Roman"])
      keep.identifiers.should eq({"isbn" => "9783161484100"})
      keep.publisher.should eq("Selbst")
      undone.errors.should eq(["publisher of #1 changed since, left as it is"])
      fake.covers.has_key?(1_i64).should be_false
      fake.books[new_id]["title"].should eq("Testbuch")
      fake.books[new_id]["formats"].as_a.map(&.as_s).sort.should eq(["EPUB", "PDF"])
      lists.memberships([1_i64, new_id], "arthur").should eq({1_i64 => [l1.id], new_id => [l1.id, l2.id].sort})
      progress.of("arthur", 1).should be_empty
      progress.of("arthur", new_id).map(&.position).should eq(["12"])
      expect_raises(CalibreHub::Duplicates::Undone) { dups.undo(m.id) }
    end
  end

  it "keeps the moved formats and cover on the keeper when the other can't come back" do
    merge_setup do |fake, dups, _, _, _|
      fake.add(1, "Testbuch", formats: ["EPUB"], identifiers: {"isbn" => "9783161484100"})
      fake.add(2, "Testbuch", formats: ["PDF", "EPUB"], publisher: "Verlag")
      fake.covers[2] = PNG
      m, _ = dups.merge(1, [2_i64])
      m.formats.map(&.format).should eq(["PDF"])
      m.cover_from.should eq(2)
      # calibre's trash emptied before the undo
      Dir.glob(File.join(fake.library, ".caltrash", "b", "*")).each { |d| FileUtils.rm_rf(d) }
      undone, books = dups.undo(m.id)
      undone.restored.should be_empty
      keep = books[0]
      # the only copy of the PDF and the cover stay; the field the merge filled goes back
      keep.formats.sort.should eq(["EPUB", "PDF"])
      fake.files[{1_i64, "PDF"}].should start_with("PDF of 2")
      fake.covers[1]?.should eq(PNG)
      keep.publisher.should be_nil
      fake.requests.none? { |r| r[0] == "/cdb/cmd/remove_format/0" }.should be_true
      undone.errors.should eq([
        "#2 is not in the trash any more",
        "PDF of #1 stays: #2 did not come back with it",
        "the cover of #1 stays: #2 did not come back",
      ])
    end
  end

  it "replaces a tiny file of the keeper and refuses a changed keeper" do
    merge_setup do |fake, dups, _, _, _|
      fake.add(1, "Testbuch", formats: ["PDF"], identifiers: {"isbn" => "9783161484100"})
      fake.add(2, "Testbuch", formats: ["PDF"])
      expect_raises(CalibreHub::Writer::Conflict) { dups.merge(1, [2_i64], "2020-01-01T00:00:00.000000Z") }
      expect_raises(CalibreHub::Edit::Invalid) { dups.merge(1, [1_i64]) }
      expect_raises(CalibreHub::Writer::NotFound) { dups.merge(1, [9_i64]) }
      # no file sizes without metadata.db: same format, nothing moves
      plan = dups.plan(1, [2_i64])
      plan.formats.should be_empty
    end
  end
end

describe "duplicate routes" do
  it "lists, plans, merges and undoes over the API" do
    merge_setup do |fake, dups, _, _, _|
      fake.add(1, "Routenbuch", tags: ["A"])
      fake.add(2, "Routenbuch", formats: ["PDF"], tags: ["B"])
      auth = CalibreHub::Auth.new("arthur", "pw", Random::Secure.random_bytes(32), secure: false)
      CalibreHub.duplicate_routes(dups, auth)

      status, r = call("GET", "/api/duplicates")
      status.should eq(200)
      r["groups"].as_a.map(&.["bookIds"]).should eq([JSON.parse("[1, 2]")])
      call("GET", "/api/duplicates?threshold=2")[0].should eq(400)

      status, r = call("POST", "/api/duplicates/merge", %({"keepId": 1, "bookIds": [2], "dryRun": true}))
      status.should eq(200)
      r["plan"]["formats"][0]["format"].should eq("PDF")
      fake.books.has_key?(2_i64).should be_true

      call("POST", "/api/duplicates/merge", %({"keepId": 1, "bookIds": []}))[0].should eq(400)
      status, r = call("POST", "/api/duplicates/merge", %({"keepId": 1, "bookIds": [2]}))
      status.should eq(200)
      r["book"]["formats"].as_a.map(&.as_s).sort.should eq(["EPUB", "PDF"])
      id = r["merge"]["id"].as_i

      status, r = call("GET", "/api/duplicates/merges")
      r.as_a.map(&.["id"].as_i).should eq([id])
      status, r = call("POST", "/api/duplicates/merges/#{id}/undo")
      status.should eq(200)
      r["merge"]["status"].should eq("undone")
      r["books"].size.should eq(2)
      call("POST", "/api/duplicates/merges/#{id}/undo")[0].should eq(409)
      call("POST", "/api/duplicates/merges/999/undo")[0].should eq(404)

      status, r = call("POST", "/api/duplicates/ignore", %({"bookIds": [1, #{r["books"][1]["id"]}]}))
      status.should eq(200)
      r["ignored"].should eq(1)
    end
  end
end

private def call(method, path, body = nil)
  io = IO::Memory.new
  request = HTTP::Request.new(method, path, HTTP::Headers{"X-Calibre-Hub" => "1"}, body)
  ctx = HTTP::Server::Context.new(request, HTTP::Server::Response.new(io))
  Kemal::RouteHandler::INSTANCE.call(ctx)
  ctx.response.close
  response = HTTP::Client::Response.from_io(IO::Memory.new(io.to_s))
  {response.status_code, JSON.parse(response.body)}
end
