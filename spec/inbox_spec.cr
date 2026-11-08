require "spec"
require "file_utils"
require "../src/calibre_hub/inbox"

private def tmpdir(&)
  dir = File.tempname("inbox-spec")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe CalibreHub::Inbox do
  it "turns folders into a category and tags" do
    CalibreHub::Inbox.classify("Fachbuch/Software/x.epub").should eq({"Fachbuch.Software", ["Fachbuch", "Software"]})
    CalibreHub::Inbox.classify("x.epub").should eq({nil, [] of String})
  end

  it "moves a file below a dated folder, keeping its subfolders and what is there" do
    tmpdir do |dir|
      now = Time.local(2026, 11, 6, 12, 30, 5)
      box = CalibreHub::Inbox.new(dir)
      Dir.mkdir_p(File.join(dir, "Roman"))
      File.write(File.join(dir, "Roman/x.epub"), "new")
      Dir.mkdir_p(File.join(dir, "_imported/2026-11-06/Roman"))
      File.write(File.join(dir, "_imported/2026-11-06/Roman/x.epub"), "old")
      moved = box.move(File.join(dir, "Roman/x.epub"), "_imported", now)
      moved.should eq File.join(dir, "_imported/2026-11-06/Roman/123005-x.epub")
      File.read(moved).should eq "new"
      File.read(File.join(dir, "_imported/2026-11-06/Roman/x.epub")).should eq "old"
    end
  end

  it "takes away empty sorting folders once they are old enough, nothing else" do
    tmpdir do |dir|
      box = CalibreHub::Inbox.new(dir, 1.minute)
      Dir.mkdir_p(File.join(dir, "Leer/Tief"))
      Dir.mkdir_p(File.join(dir, "Voll"))
      Dir.mkdir_p(File.join(dir, "_imported/leer"))
      File.write(File.join(dir, "Voll/x.epub"), "x")
      box.cleanup(Time.local)
      Dir.exists?(File.join(dir, "Leer/Tief")).should be_true
      box.cleanup(Time.local + 2.minutes)
      Dir.exists?(File.join(dir, "Leer")).should be_false
      File.exists?(File.join(dir, "Voll/x.epub")).should be_true
      Dir.exists?(File.join(dir, "_imported/leer")).should be_true
    end
  end

  it "says when a folder isn't the hub's to move files out of" do
    tmpdir do |dir|
      box = CalibreHub::Inbox.new(dir)
      Dir.mkdir_p(File.join(dir, "Privat"))
      File.write(File.join(dir, "Privat/x.epub"), "x")
      box.movable?(File.join(dir, "Privat/x.epub")).should be_true
      File.chmod(File.join(dir, "Privat"), 0o555)
      begin
        box.movable?(File.join(dir, "Privat/x.epub")).should be_false
      ensure
        File.chmod(File.join(dir, "Privat"), 0o755)
      end
    end
  end

  it "counts what it may not move by folder, the fullest first, once per pass" do
    tmpdir do |dir|
      # the folders the hub may not write to, also when the spec runs as root
      locked = [File.join(dir, "Networks"), File.join(dir, "Roman/Alt"), dir]
      box = CalibreHub::Inbox.new(dir, writable: ->(d : String) { !locked.includes?(d) })
      paths = ["Networks/a.pdf", "Networks/b.pdf", "Networks/c.pdf", "Roman/Alt/x.epub", "Roman/Alt/y.epub", "Roman/Neu/z.epub", "lose.pdf"]
      paths.each { |p| box.movable?(File.join(dir, p)) }
      # asked twice in a pass, counted once
      box.movable?(File.join(dir, "Networks/a.pdf"))
      box.unwritable.files.should eq 0
      got = box.passed
      got.files.should eq 6
      got.folders.map { |f| {f.path, f.files} }.should eq [{"Networks", 3}, {"Roman/Alt", 2}, {"", 1}]
      box.unwritable.should eq got
      JSON.parse(got.to_json).should eq JSON.parse(%({"files":6,"folders":[{"path":"Networks","files":3},{"path":"Roman/Alt","files":2},{"path":"","files":1}]}))
      # the next pass starts over: once the rights are fixed it is empty
      locked.clear
      paths.each { |p| box.movable?(File.join(dir, p)).should be_true }
      box.passed.files.should eq 0
      box.unwritable.folders.should be_empty
    end
  end
end
