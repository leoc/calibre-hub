require "spec"
require "file_utils"
require "../src/calibre_hub/dispatcher"
require "../src/calibre_hub/detector"

private def setup(scripts : Hash(String, String), &)
  dir = File.tempname("hub-handlers")
  Dir.mkdir(dir)
  scripts.each do |name, body|
    File.write(File.join(dir, name), "#!/bin/sh\n#{body}\n")
    File.chmod(File.join(dir, name), 0o755)
  end
  db = DB.open("sqlite3::memory:?max_pool_size=1")
  # the detector owns the schema
  CalibreHub::Detector.new(CalibreHub::Calibre.new("http://127.0.0.1:1", "x", "x"), db)
  yield db, dir
ensure
  FileUtils.rm_rf(dir) if dir
end

private def event(db, id)
  db.exec "insert into events (type, book_id, payload, created_at) values ('changed', ?, ?, 0)", id, %({"bookId":#{id}})
end

describe CalibreHub::Dispatcher do
  it "delivers to every handler and marks events done" do
    setup({"10-a" => "cat >> \"$OUT\"", "20-b" => "true"}) do |db, dir|
      outfile = File.tempname("hub-out")
      d = CalibreHub::Dispatcher.new(db, dir, {"OUT" => outfile})
      event(db, 1)
      event(db, 2)
      d.run_once.should eq(4)
      File.read(outfile).should eq(%({"bookId":1}{"bookId":2}))
      db.query_one("select count(*) from events where done_at is null", as: Int64).should eq(0)
      File.delete(outfile)
    end
  end

  it "retries with backoff, keeps order per handler, and parks" do
    setup({"10-fail" => "exit 3", "20-ok" => "true"}) do |db, dir|
      d = CalibreHub::Dispatcher.new(db, dir, max_attempts: 2)
      event(db, 1)
      event(db, 2)
      now = Time.utc
      d.run_once(now)
      # 10-fail waits on event 1, so it gets no event 2 yet; 20-ok got both
      db.query_one("select count(*) from deliveries where handler = '20-ok' and done_at is not null", as: Int64).should eq(2)
      db.query_one("select count(*) from deliveries where handler = '10-fail' and attempts > 0", as: Int64).should eq(1)
      d.run_once(now + 1.second).should eq(0) # backoff
      d.run_once(now + 1.minute)               # 2nd attempt on event 1 -> parked, then event 2
      d.failed.map(&.[:event_id]).should contain(1_i64)
      d.failed.first[:error].not_nil!.should contain("exit 3")
    end
  end

  it "caps the backoff" do
    setup({} of String => String) do |db, dir|
      d = CalibreHub::Dispatcher.new(db, dir)
      d.delay(1).should eq(10.seconds)
      d.delay(3).should eq(40.seconds)
      d.delay(20).should eq(1.hour)
    end
  end
end
