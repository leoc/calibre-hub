require "spec"
require "sqlite3"
require "../src/calibre_hub/private_tags"

private def with_tags(&)
  path = File.tempname("hub-ptags", ".sqlite")
  db = DB.open("sqlite3://#{path}?max_pool_size=1")
  yield CalibreHub::PrivateTags.new(db), db
ensure
  db.try &.close
  File.delete?(path) if path
end

describe CalibreHub::PrivateTags do
  it "keeps each user's tags to that user" do
    with_tags do |tags|
      tags.change("arthur", [1_i64, 2_i64], ["Krimi", "Urlaub"], [] of String).should eq([1_i64, 2_i64])
      tags.change("lea", [2_i64], ["Geheim"], [] of String).should eq([2_i64])

      tags.of("arthur", [1_i64, 2_i64, 3_i64]).should eq({1_i64 => ["Krimi", "Urlaub"], 2_i64 => ["Krimi", "Urlaub"], 3_i64 => [] of String})
      tags.of("lea", [1_i64, 2_i64]).should eq({1_i64 => [] of String, 2_i64 => ["Geheim"]})
      tags.counts("arthur").map { |c| {c.name, c.count} }.should eq([{"Krimi", 2_i64}, {"Urlaub", 2_i64}])
      tags.counts("lea").map(&.name).should eq(["Geheim"])
      tags.counts("tilli").should be_empty

      # a filter finds only the user's own tags
      tags.books("arthur", ["Krimi"]).should eq(Set{1_i64, 2_i64})
      tags.books("lea", ["Krimi"]).should eq(Set(Int64).new)
      tags.books("arthur", ["Geheim"]).should eq(Set(Int64).new)
      tags.books("arthur", [" "]).should be_nil
    end
  end

  it "filters by all tags, ignoring case, and keeps the spelling there is" do
    with_tags do |tags|
      tags.change("arthur", [1_i64, 2_i64], ["Krimi"], [] of String)
      tags.change("arthur", [2_i64, 3_i64], ["krimi", "noir"], [] of String).should eq([3_i64, 2_i64].sort)
      tags.of("arthur", [3_i64])[3_i64].should eq(["Krimi", "noir"])
      tags.books("arthur", ["KRIMI", "Noir"]).should eq(Set{2_i64, 3_i64})
      tags.counts("arthur").map { |c| {c.name, c.count} }.should eq([{"Krimi", 3_i64}, {"noir", 2_i64}])

      # removing what isn't there changes nothing
      tags.change("arthur", [1_i64, 2_i64], [] of String, ["NOIR"]).should eq([2_i64])
      tags.books("arthur", ["noir"]).should eq(Set{3_i64})
    end
  end

  it "sets a book's tags" do
    with_tags do |tags|
      tags.change("arthur", [1_i64], ["Krimi"], [] of String)
      tags.change("arthur", [2_i64], ["Alt", "Krimi"], [] of String)
      tags.set("arthur", 2_i64, ["krimi", "Neu", " "]).should eq(["Krimi", "Neu"])
      tags.set("lea", 2_i64, ["Ihr"]).should eq(["Ihr"])
      tags.of("arthur", [2_i64])[2_i64].should eq(["Krimi", "Neu"])
      tags.set("arthur", 2_i64, [] of String).should be_empty
      tags.of("lea", [2_i64])[2_i64].should eq(["Ihr"])
    end
  end

  it "checks what it is given" do
    with_tags do |tags|
      expect_raises(CalibreHub::Edit::Invalid, "nothing to change") { tags.change("a", [1_i64], [] of String, [" "]) }
      expect_raises(CalibreHub::Edit::Invalid, "both added and removed") { tags.change("a", [1_i64], ["x"], ["X"]) }
      expect_raises(CalibreHub::Edit::Invalid, "commas") { tags.change("a", [1_i64], ["a,b"], [] of String) }
      expect_raises(CalibreHub::Edit::Invalid, "characters") { tags.set("a", 1_i64, ["x" * 101]) }
      expect_raises(CalibreHub::Edit::Invalid, "control") { tags.set("a", 1_i64, ["a\tb"]) }
      expect_raises(CalibreHub::Edit::Invalid, "list of tags") { CalibreHub::PrivateTags.list(JSON.parse(%("x")), "add") }
      expect_raises(CalibreHub::Edit::Invalid, "list of tags") { CalibreHub::PrivateTags.list(JSON.parse(%([1])), "add") }
      CalibreHub::PrivateTags.list(nil, "add").should be_empty
      CalibreHub::PrivateTags.list(JSON.parse(%(["a"])), "add").should eq(["a"])
    end
  end

  it "puts a deleted book's tags aside and gives them back on restore" do
    with_tags do |tags, db|
      tags.change("arthur", [1_i64, 2_i64], ["Krimi"], [] of String)
      tags.change("lea", [1_i64], ["Ihr"], [] of String)
      db.exec "insert into meta (key, value) values ('private_tags_event_seq', '0')"
      db.exec "insert into events (type, book_id, payload, created_at) values ('deleted', 1, '{}', 0)"
      tags.follow_events
      tags.of("arthur", [1_i64])[1_i64].should be_empty
      tags.counts("arthur").map(&.count).should eq([1_i64])
      tags.counts("lea").should be_empty

      tags.book_restored(1_i64, 9_i64)
      tags.of("arthur", [9_i64])[9_i64].should eq(["Krimi"])
      tags.of("lea", [9_i64])[9_i64].should eq(["Ihr"])
    end
  end

  it "gives the keeper of a merge the tags of the others" do
    with_tags do |tags|
      tags.change("arthur", [1_i64], ["Krimi"], [] of String)
      tags.change("arthur", [2_i64], ["krimi", "Noir"], [] of String)
      tags.change("lea", [2_i64], ["Ihr"], [] of String)
      tags.merge_book(2_i64, 1_i64)
      tags.of("arthur", [1_i64])[1_i64].should eq(["Krimi", "Noir"])
      tags.of("lea", [1_i64])[1_i64].should eq(["Ihr"])
    end
  end
end
