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
end
