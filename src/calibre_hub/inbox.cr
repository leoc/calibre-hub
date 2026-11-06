require "json"
require "./backlog"

module CalibreHub
  # A folder a file comes in by, as the Eingang (Intake) sees it. Nothing here
  # reaches the library: the Eingang analyses what lies here and a decision
  # takes it in. inbox/Fachbuch/Software/x.epub becomes a book with #<category
  # column> "Fachbuch.Software" and the tags "Fachbuch" and "Software"; tags
  # embedded in the file are dropped. Originals move to _imported/<date>/
  # (taken) or _duplicates/<date>/ (byte for byte in the library), a file that
  # is no book to _failed/<date>/, keeping the subfolders. What Arthur throws
  # away goes to <root>-papierkorb (IntakeTrash). Directories starting with
  # "_" or "." are not looked at. The uploads' staging folder goes the same way.
  class Inbox
    IMPORTED   = "_imported"
    DUPLICATES = "_duplicates"
    FAILED     = "_failed"

    getter dir : String
    getter stable : Time::Span

    def initialize(dir : String, @stable : Time::Span = 2.minutes)
      @dir = File.expand_path(dir)
      # said once per file, not on every pass
      @unwritable = Set(String).new
    end

    # Category and tags from the folders between the inbox and the file
    def self.classify(rel : String) : {String?, Array(String)}
      folders = File.dirname(rel).split('/').reject { |p| p.empty? || p == "." }.map(&.strip).reject(&.empty?)
      {folders.empty? ? nil : folders.join('.'), folders}
    end

    def rel(path : String) : String
      path.lchop(@dir).lchop('/')
    end

    # The file can be moved away once it is decided: taking it in without
    # that would take it in again on the next pass
    def movable?(path : String) : Bool
      return true if File::Info.writable?(File.dirname(path))
      if @unwritable.add?(path)
        STDERR.puts "inbox: #{rel(path)} skipped, #{File.dirname(rel(path))} is not writable for the hub (group write missing?)"
      end
      false
    end

    # A file still being written isn't looked at
    def settled?(mtime : Int64, now = Time.local) : Bool
      now.to_unix - mtime >= @stable.total_seconds
    end

    # What the scanner found to be no book of its format goes to _failed,
    # so nothing lies around without a word; other kinds of files stay
    def fail_broken(skipped : Array(Backlog::Skipped), now = Time.local)
      skipped.each do |s|
        next unless s.reason.starts_with?("too small") || s.reason.starts_with?("broken")
        info = File.info?(s.path) || next
        next unless settled?(info.modification_time.to_unix, now) && movable?(s.path)
        move(s.path, FAILED, now)
        STDERR.puts "inbox: #{rel(s.path)} failed: #{s.reason}"
      end
    end

    # below target/<date>/, keeping the subfolders; a name taken gets the
    # time in front
    def move(path : String, target : String, now = Time.local) : String
      dest = File.join(@dir, target, now.to_s("%F"), rel(path))
      Dir.mkdir_p(File.dirname(dest))
      dest = File.join(File.dirname(dest), "#{now.to_s("%H%M%S")}-#{File.basename(dest)}") if File.exists?(dest)
      File.rename(path, dest)
      dest
    end

    # empty sorting folders go away once they are older than the stable time
    # (not the inbox itself, not _*), so a folder just created over Samba stays
    def cleanup(now = Time.local)
      cleanup(@dir, now)
    end

    private def cleanup(dir : String, now : Time)
      Dir.each_child(dir) do |name|
        next if name.starts_with?('_') || name.starts_with?('.')
        path = File.join(dir, name)
        next unless File.directory?(path)
        cleanup(path, now)
        info = File.info?(path) || next
        Dir.delete(path) if Dir.empty?(path) && now - info.modification_time >= @stable rescue nil
      end
    end
  end
end
