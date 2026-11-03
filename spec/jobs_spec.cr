require "spec"
require "file_utils"
require "../src/calibre_hub/writer"

# Records the per-book changes instead of writing to calibre-server
private class FakeWriter < CalibreHub::Writer
  getter calls = [] of {Int64, Hash(String, JSON::Any)}
  # what book(id) answers; others get a blank book
  getter books = {} of Int64 => CalibreHub::Book

  def initialize
    super(CalibreHub::Calibre.new("http://127.0.0.1:1", "x", "x"), nil, nil, "kategorie")
  end

  def book(id : Int64) : CalibreHub::Book?
    return nil if id == 999
    @books[id]? || CalibreHub::Jobs.blank
  end

  # applies the fields a bulk job writes, as calibre would
  def update(id : Int64, body : Hash(String, JSON::Any)) : CalibreHub::Book
    raise NotFound.new if id == 999
    @calls << {id, body}
    b = book(id).not_nil!
    tags = b.tags.dup
    body["tags"]?.try { |t| tags = t.as_a.map(&.as_s) }
    body["addTags"]?.try { |t| tags = (tags + t.as_a.map(&.as_s)).uniq }
    body["removeTags"]?.try { |t| tags -= t.as_a.map(&.as_s) }
    series = body.has_key?("series") ? body["series"].as_s? : b.series
    index = body["seriesIndex"]?.try(&.as_f?) || (series ? b.series_index : nil)
    custom = b.custom.dup
    custom["kategorie"] = body["kategorie"] if body.has_key?("kategorie")
    publisher = body.has_key?("publisher") ? body["publisher"].as_s? : b.publisher
    @books[id] = CalibreHub::Book.new(id: id, title: b.title, authors: b.authors, author_sort: nil, tags: tags,
      series: series, series_index: index, formats: b.formats, last_modified: b.last_modified, timestamp: nil,
      pubdate: b.pubdate, rating: b.rating, publisher: publisher, identifiers: b.identifiers,
      languages: b.languages, comments: nil, custom: custom)
  end
end

private def book(id, tags = [] of String, series : String? = nil, series_index : Float64? = nil,
                 kategorie : String? = nil, pubdate : Time? = nil) : CalibreHub::Book
  CalibreHub::Book.new(id: id.to_i64, title: "B#{id}", authors: ["X"], author_sort: nil, tags: tags,
    series: series, series_index: series_index, formats: [] of String, last_modified: Time::UNIX_EPOCH,
    timestamp: nil, pubdate: pubdate, rating: nil, publisher: nil, identifiers: {} of String => String,
    languages: [] of String, comments: nil, custom: {"kategorie" => JSON::Any.new(kategorie)})
end

private def jobs(db, writer = FakeWriter.new)
  CalibreHub::Jobs.new(db, writer.calibre, writer, "kategorie")
end

# Answers searches without a calibre-server: "" matches the whole library
private class SearchingCalibre < CalibreHub::Calibre
  getter queries = [] of String

  def initialize(@all_ids : Array(Int64), @matches : Hash(String, Array(Int64)))
    super("http://127.0.0.1:1", "x", "x")
  end

  def search(query : String, sort : String, ascending : Bool, offset : Int32, limit : Int32) : SearchResult
    @queries << query
    ids = query.empty? ? @all_ids : (@matches[query]? || [] of Int64)
    SearchResult.new(ids.size, ids)
  end
end

private def searching_jobs(db, writer = FakeWriter.new, column : String? = "kategorie")
  calibre = SearchingCalibre.new([1_i64, 2_i64, 3_i64, 4_i64], {"tags:\"=a\"" => [2_i64, 3_i64]})
  {CalibreHub::Jobs.new(db, calibre, writer, column), calibre}
end

private def body(json : String) : Hash(String, JSON::Any)
  JSON.parse(json).as_h
end

private def wait(jobs, id) : CalibreHub::Jobs::Job
  200.times do
    job = jobs[id]?.not_nil!
    return job if job.status != "running"
    sleep 10.milliseconds
  end
  raise "job #{id} still running"
end

private def with_state(&)
  path = File.tempname("hub-state", ".sqlite")
  db = DB.open("sqlite3://#{path}?max_pool_size=1")
  yield db, path
ensure
  # let the workers of this example reach their wait before the DB goes away
  sleep 20.milliseconds
  db.try &.close
  File.delete?(path) if path
end

private def invalid_field(&) : String
  yield
  raise "expected Edit::Invalid"
rescue ex : CalibreHub::Edit::Invalid
  ex.field
end

describe CalibreHub::Jobs do
  it "takes the books of a reading list for a list query" do
    with_state do |db, _|
      j = jobs(db)
      expect_raises(CalibreHub::Edit::Invalid, "unknown list") { j.ids(JSON.parse(%({"query": {"list": "3"}}))) }
      j.list_members = ->(p : HTTP::Params) do
        case {p["list"]?, p["listPath"]?}
        when {"3", nil}      then [6_i64, 5_i64]
        when {nil, "Urlaub"} then [7_i64]
        else                      raise CalibreHub::Lists::NotFound.new
        end
      end
      j.ids(JSON.parse(%({"query": {"list": "3"}}))).should eq([6_i64, 5_i64])
      j.ids(JSON.parse(%({"query": {"listPath": "Urlaub", "direct": true}}))).should eq([7_i64])
      expect_raises(CalibreHub::Lists::NotFound) { j.ids(JSON.parse(%({"query": {"list": 4}}))) }
    end
  end

  it "never lets an empty or unknown query filter stand for the whole library" do
    with_state do |db, _|
      j, calibre = searching_jobs(db)
      j.ids(JSON.parse(%({"query": {"tag": "a"}}))).should eq([2_i64, 3_i64])
      # unknown filters, typos included, are refused instead of ignored
      invalid_field { j.ids(JSON.parse(%({"query": {"tags": "a"}}))) }.should eq("target")
      invalid_field { j.ids(JSON.parse(%({"query": {"lang": "deu"}}))) }.should eq("target")
      # nothing to filter by: only with all: true
      invalid_field { j.ids(JSON.parse(%({"query": {}}))) }.should eq("target")
      invalid_field { j.ids(JSON.parse(%({"query": {"q": "  "}}))) }.should eq("target")
      invalid_field { j.ids(JSON.parse(%({"query": {"tag": [], "author": ""}}))) }.should eq("target")
      invalid_field { j.ids(JSON.parse(%({"query": {"q": null}}))) }.should eq("target")
      calibre.queries.should eq(["tags:\"=a\""])
      j.ids(JSON.parse(%({"query": {}, "all": true}))).should eq([1_i64, 2_i64, 3_i64, 4_i64])
      invalid_field { j.ids(JSON.parse(%({"query": {}, "all": "yes"}))) }.should eq("target")
      # a list stays the list, also without further filters
      j.list_members = ->(p : HTTP::Params) { [7_i64] }
      j.ids(JSON.parse(%({"query": {"list": 3}}))).should eq([7_i64])
    end
  end

  it "refuses a kategorie filter where no category column is configured" do
    with_state do |db, _|
      j, _ = searching_jobs(db, column: nil)
      invalid_field { j.ids(JSON.parse(%({"query": {"kategorie": "Roman"}}))) }.should eq("target")
    end
  end

  it "checks the count the client expects and requires it to delete by query" do
    with_state do |db, _|
      writer = FakeWriter.new
      j, _ = searching_jobs(db, writer)
      j.ids(JSON.parse(%({"query": {"tag": "a"}, "expect": 2}))).should eq([2_i64, 3_i64])
      expect_raises(CalibreHub::Jobs::CountMismatch) { j.ids(JSON.parse(%({"query": {"tag": "a"}, "expect": 1}))) }
      expect_raises(CalibreHub::Jobs::CountMismatch) { j.ids(JSON.parse(%({"query": {}, "all": true, "expect": 3}))) }
      invalid_field { j.submit(body(%({"target": {"query": {"tag": "a"}}, "changes": {"delete": true}}))) }.should eq("target")
      expect_raises(CalibreHub::Jobs::CountMismatch) do
        j.submit(body(%({"target": {"query": {"tag": "a"}, "expect": 3}, "changes": {"delete": true}})))
      end
      j.submit(body(%({"target": {"query": {"tag": "a"}, "expect": 2}, "changes": {"delete": true}}))).total.should eq(2)
      # ids name the books themselves
      j.submit(body(%({"target": {"ids": [1]}, "changes": {"delete": true}}))).total.should eq(1)
    end
  end

  it "runs a job, records errors per book and keeps the API shape" do
    with_state do |db, _|
      writer = FakeWriter.new
      j = jobs(db, writer)
      job = j.submit(body(%({"target": {"ids": [3, 999, 4, 3]}, "changes": {"addTags": ["x"]}})))
      job.total.should eq(3)
      done = wait(j, job.id)
      JSON.parse(done.to_json).should eq(JSON.parse(
        %({"id": "#{job.id}", "status": "done", "done": 3, "total": 3, "errors": [{"bookId": 999, "error": "not found"}]})))
      writer.calls.map(&.[0]).should eq([3_i64, 4_i64])
      j["unknown"]?.should be_nil
    end
  end

  it "fails a job when every book failed" do
    with_state do |db, _|
      j = jobs(db)
      wait(j, j.submit(body(%({"target": {"ids": [999]}, "changes": {"series": "S"}}))).id).status.should eq("failed")
    end
  end

  it "keeps jobs across restarts and resumes a running one where it stopped" do
    with_state do |db, path|
      j = jobs(db)
      finished = wait(j, j.submit(body(%({"target": {"ids": [1]}, "changes": {"series": "S"}}))).id)
      # as left behind by a hub that stopped after the second book
      db.exec %(insert into jobs (id, status, done, ids, changes, errors, created_at)
        values ('cut', 'running', 2, '[5, 999, 6, 7]', '{"addTags": ["y"]}', '[{"bookId": 999, "error": "not found"}]', 0))
      db.close

      db2 = DB.open("sqlite3://#{path}?max_pool_size=1")
      begin
        writer = FakeWriter.new
        j2 = jobs(db2, writer)
        j2[finished.id]?.not_nil!.status.should eq("done")
        resumed = wait(j2, "cut")
        resumed.done.should eq(4)
        resumed.status.should eq("done")
        resumed.errors.should eq([{bookId: 999_i64, error: "not found"}])
        writer.calls.map(&.[0]).should eq([6_i64, 7_i64])
      ensure
        db2.close
      end
    end
  end

  it "numbers a series in the order of the ids" do
    with_state do |db, _|
      writer = FakeWriter.new
      j = jobs(db, writer)
      job = j.submit(body(%({"target": {"ids": [9, 2, 5]}, "changes": {"series": "Reihe", "numberSeries": true}})))
      wait(j, job.id).errors.should be_empty
      writer.calls.should eq([
        {9_i64, body(%({"series": "Reihe", "seriesIndex": 1}))},
        {2_i64, body(%({"series": "Reihe", "seriesIndex": 2}))},
        {5_i64, body(%({"series": "Reihe", "seriesIndex": 3}))},
      ])
    end
  end

  it "validates bulk changes up front" do
    with_state do |db, _|
      j = jobs(db)
      invalid_field { j.submit(body(%({"target": {"ids": [1]}, "changes": {"title": "x"}}))) }.should eq("title")
      invalid_field { j.submit(body(%({"target": {"ids": [1]}, "changes": {}}))) }.should eq("changes")
      invalid_field { j.submit(body(%({"target": {"ids": [1]}, "changes": {"series": 3}}))) }.should eq("series")
      invalid_field { j.submit(body(%({"target": {"query": {"tag": "a"}}, "changes": {"series": "S", "numberSeries": true}}))) }.should eq("numberSeries")
      invalid_field { j.submit(body(%({"target": {"ids": [1]}, "changes": {"numberSeries": true}}))) }.should eq("numberSeries")
      invalid_field { j.submit(body(%({"target": {"ids": [1]}, "changes": {"series": null, "numberSeries": true}}))) }.should eq("numberSeries")
      invalid_field { j.submit(body(%({"target": {"ids": [1]}, "changes": {"series": "S", "numberSeries": "yes"}}))) }.should eq("numberSeries")
      invalid_field { j.submit(body(%({"target": {"ids": [1]}, "changes": {"numberSeries": false}}))) }.should eq("changes")
    end
  end

  it "sets authors, publisher, language, rating and the year in bulk" do
    with_state do |db, _|
      writer = FakeWriter.new
      writer.books[2_i64] = book(2, pubdate: Time.utc(1999, 5, 7, 12))
      j = jobs(db, writer)
      wait(j, j.submit(body(%({"target": {"ids": [1, 2]}, "changes": {"authors": ["A"], "publisher": "V", "languages": ["deu"], "rating": 8, "pubYear": 2001}}))).id)
      writer.calls.should eq([
        {1_i64, body(%({"authors": ["A"], "publisher": "V", "languages": ["deu"], "rating": 8, "pubdate": "2001-01-01"}))},
        {2_i64, body(%({"authors": ["A"], "publisher": "V", "languages": ["deu"], "rating": 8, "pubdate": "2001-05-07"}))},
      ])
      invalid_field { j.submit(body(%({"target": {"ids": [1]}, "changes": {"pubYear": "x"}}))) }.should eq("pubYear")
      invalid_field { j.submit(body(%({"target": {"ids": [1]}, "changes": {"pubYear": 2001, "pubdate": "2001-01-01"}}))) }.should eq("pubYear")
      invalid_field { j.submit(body(%({"target": {"ids": [1]}, "changes": {"rating": 11}}))) }.should eq("rating")
    end
  end

  it "undoes a field change with each book's own values, once" do
    with_state do |db, _|
      writer = FakeWriter.new
      writer.books[1_i64] = book(1, tags: ["a"], series: "Alt", series_index: 3.0, kategorie: "Sachbuch.Geschichte")
      writer.books[2_i64] = book(2)
      j = jobs(db, writer)
      first = wait(j, j.submit(body(%({"target": {"ids": [1, 2, 999]}, "changes": {"addTags": ["x"], "series": "Neu", "kategorie": "Roman"}}))).id)
      first.before.keys.should eq(["1", "2"])
      writer.calls.clear
      undo = wait(j, j.undo(first.id).id)
      undo.total.should eq(2)
      # tags as a difference: the ones added go again
      writer.calls.should eq([
        {1_i64, body(%({"removeTags": ["x"], "series": "Alt", "seriesIndex": 3.0, "kategorie": "Sachbuch.Geschichte"}))},
        {2_i64, body(%({"removeTags": ["x"], "series": null, "kategorie": null}))},
      ])
      undo.errors.should be_empty
      expect_raises(CalibreHub::Jobs::NotUndoable) { j.undo(first.id) }
      deleted = wait(j, j.submit(body(%({"target": {"ids": [1]}, "changes": {"delete": true}}))).id)
      expect_raises(CalibreHub::Jobs::NotUndoable) { j.undo(deleted.id) }
    end
  end

  it "leaves what changed after the job when undoing it" do
    with_state do |db, _|
      writer = FakeWriter.new
      writer.books[1_i64] = book(1, tags: ["a"], series: "Alt", series_index: 3.0, kategorie: "Sachbuch")
      writer.books[2_i64] = book(2, tags: ["a"], series: "Alt", series_index: 1.0)
      j = jobs(db, writer)
      first = wait(j, j.submit(body(%({"target": {"ids": [1, 2]}, "changes": {"addTags": ["x"], "series": "Neu", "kategorie": "Roman"}}))).id)
      # by hand afterwards: another tag and series on #1, the category of #2
      writer.update(1, body(%({"addTags": ["y"], "series": "Hand"})))
      writer.update(2, body(%({"kategorie": "Krimi"})))
      writer.calls.clear
      undo = wait(j, j.undo(first.id).id)
      writer.calls.should eq([
        {1_i64, body(%({"removeTags": ["x"], "kategorie": "Sachbuch"}))},
        {2_i64, body(%({"removeTags": ["x"], "series": "Alt", "seriesIndex": 1.0}))},
      ])
      writer.books[1_i64].tags.should eq(["a", "y"])
      writer.books[1_i64].series.should eq("Hand")
      writer.books[2_i64].custom["kategorie"].should eq("Krimi")
      undo.errors.should eq([
        {bookId: 1_i64, error: "changed since, left as it is: series"},
        {bookId: 2_i64, error: "changed since, left as it is: kategorie"},
      ])
      undo.status.should eq("done")
    end
  end

  it "treats numberSeries false as a plain series change" do
    with_state do |db, _|
      writer = FakeWriter.new
      j = jobs(db, writer)
      wait(j, j.submit(body(%({"target": {"ids": [1]}, "changes": {"series": "S", "numberSeries": false}}))).id)
      writer.calls.should eq([{1_i64, body(%({"series": "S"}))}])
    end
  end
end
