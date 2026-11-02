require "spec"
require "file_utils"
require "../src/calibre_hub/writer"

# Records the per-book changes instead of writing to calibre-server
private class FakeWriter < CalibreHub::Writer
  getter calls = [] of {Int64, Hash(String, JSON::Any)}

  def initialize
    super(CalibreHub::Calibre.new("http://127.0.0.1:1", "x", "x"), nil, nil, "kategorie")
  end

  def update(id : Int64, body : Hash(String, JSON::Any)) : CalibreHub::Book
    raise NotFound.new if id == 999
    @calls << {id, body}
    CalibreHub::Jobs.blank
  end
end

private def jobs(db, writer = FakeWriter.new)
  CalibreHub::Jobs.new(db, writer.calibre, writer, "kategorie")
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

  it "treats numberSeries false as a plain series change" do
    with_state do |db, _|
      writer = FakeWriter.new
      j = jobs(db, writer)
      wait(j, j.submit(body(%({"target": {"ids": [1]}, "changes": {"series": "S", "numberSeries": false}}))).id)
      writer.calls.should eq([{1_i64, body(%({"series": "S"}))}])
    end
  end
end
