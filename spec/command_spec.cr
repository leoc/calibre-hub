require "spec"
require "../src/calibre_hub/command"

describe CalibreHub::Command do
  it "returns the status and output of a command" do
    io = IO::Memory.new
    status = CalibreHub::Command.run("sh", ["-c", "echo hi; exit 3"], 5.seconds, output: io)
    status.exit_code.should eq(3)
    io.to_s.should eq("hi\n")
  end

  it "kills a command that takes longer than the timeout" do
    started = Time.instant
    expect_raises(CalibreHub::Command::Timeout, "sleep: timeout after 0 s") do
      CalibreHub::Command.run("sleep", ["30"], 200.milliseconds)
    end
    (Time.instant - started).should be < 5.seconds
  end
end
