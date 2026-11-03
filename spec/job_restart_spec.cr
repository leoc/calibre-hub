require "spec"
require "../src/calibre_hub/api"

# A job the hub was running when it stopped: the book it was at gets one
# more try, and when the hub dies on that book again (a file that crashes
# it, review #8411 M4) the next start skips it instead of looping.

private class RecordingWriter < CalibreHub::Writer
  getter calls = [] of Int64
  # errors of the job as stored while a book is applied
  getter stored = {} of Int64 => String
  property db : DB::Database? = nil

  def initialize
    super(CalibreHub::Calibre.new("http://127.0.0.1:1", "x", "x"), nil, nil, "kategorie")
  end

  def book(id : Int64) : CalibreHub::Book?
    CalibreHub::Jobs.blank
  end

  def update(id : Int64, body : Hash(String, JSON::Any)) : CalibreHub::Book
    @db.try { |d| @stored[id] = d.query_one("select errors from jobs where id = 'cut'", as: String) }
    @calls << id
    CalibreHub::Jobs.blank
  end
end

private def wait(jobs, id) : CalibreHub::Jobs::Job
  200.times do
    job = jobs[id]?.not_nil!
    return job if job.status != "running"
    sleep 10.milliseconds
  end
  raise "job #{id} still running"
end

private def with_cut_job(done : Int32, errors : String, &)
  path = File.tempname("hub-state", ".sqlite")
  db = DB.open("sqlite3://#{path}?max_pool_size=1")
  # as left behind by the hub that stopped
  db.exec "create table jobs (id text primary key, status text not null, done integer not null default 0, ids text not null, changes text not null, errors text not null default '[]', created_at integer not null)"
  db.exec %(insert into jobs (id, status, done, ids, changes, errors, created_at)
    values ('cut', 'running', ?, '[5, 6, 7]', '{"addTags": ["y"]}', ?, 0)), done, errors
  db.close
  # the next start of the hub
  db = DB.open("sqlite3://#{path}?max_pool_size=1")
  writer = RecordingWriter.new
  writer.db = db
  jobs = CalibreHub::Jobs.new(db, writer.calibre, writer, nil)
  yield wait(jobs, "cut"), writer
ensure
  sleep 20.milliseconds
  db.try &.close
  File.delete?(path) if path
end

describe CalibreHub::Jobs do
  it "tries the book an interrupted job was at once more, marked while it runs" do
    with_cut_job(0, "[]") do |job, writer|
      writer.calls.should eq([5_i64, 6_i64, 7_i64])
      writer.stored[5].should contain(CalibreHub::Jobs::INTERRUPTED)
      writer.stored[6].should_not contain(CalibreHub::Jobs::INTERRUPTED)
      job.status.should eq("done")
      job.errors.should be_empty
    end
  end

  it "skips the book when the hub stopped on it again" do
    with_cut_job(1, %([{"bookId": 6, "error": "#{CalibreHub::Jobs::INTERRUPTED}"}])) do |job, writer|
      writer.calls.should eq([7_i64])
      job.done.should eq(3)
      job.status.should eq("done")
      job.errors.should eq([{bookId: 6_i64, error: CalibreHub::Jobs::INTERRUPTED}])
    end
  end
end
