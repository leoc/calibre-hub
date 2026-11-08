require "json"
require "./incoming"

module CalibreHub
  # A folder a file comes in by, as the Eingang (Intake) sees it. Nothing here
  # reaches the library: the Eingang analyses what lies here and a decision
  # takes it in. inbox/Fachbuch/Software/x.epub becomes a book with #<category
  # column> "Fachbuch.Software" and the tags "Fachbuch" and "Software"; tags
  # embedded in the file are dropped. Originals move to _imported/<date>/
  # (taken) or _duplicates/<date>/ (byte for byte in the library), a file that
  # is no book to _failed/<date>/, keeping the subfolders. What Arthur throws
  # away goes to the trash folder (IntakeTrash). Directories starting with
  # "_" or "." are not looked at. The uploads' staging folder goes the same way.
  class Inbox
    IMPORTED   = "_imported"
    DUPLICATES = "_duplicates"
    FAILED     = "_failed"

    # A folder of the inbox the hub may not move files out of, with how many
    # files of the last pass lie there. path: below the inbox, "" for itself.
    record Folder, path : String, files : Int32 do
      include JSON::Serializable
    end

    # What the last pass could not take in for want of write access, the
    # folders with the most files first; files: 0 when all is well
    record Unwritable, files : Int32, folders : Array(Folder) do
      include JSON::Serializable

      def self.none
        new(0, [] of Folder)
      end
    end

    getter dir : String
    getter stable : Time::Span
    # of the last pass, for the Eingang
    getter unwritable : Unwritable = Unwritable.none

    def initialize(dir : String, @stable : Time::Span = 2.minutes, @writable : Proc(String, Bool) = ->(d : String) { File::Info.writable?(d) })
      @dir = File.expand_path(dir)
      # what this pass found it may not move, set by passed
      @stuck = Set(String).new
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
      return true if @writable.call(File.dirname(path))
      @stuck << path
      false
    end

    # A pass is over: what it could not move becomes #unwritable, by folder.
    # The log says it once when it changes, not on every pass.
    def passed : Unwritable
      by_folder = @stuck.group_by { |p| folder(p) }
      folders = by_folder.map { |dir, paths| Folder.new(dir, paths.size) }.sort_by! { |f| {-f.files, f.path} }
      now = Unwritable.new(@stuck.size, folders)
      @stuck = Set(String).new
      if now != @unwritable && now.files > 0
        shown = folders.first(5).join(", ") { |f| "#{f.path.presence || "."} (#{f.files})" }
        more = folders.size > 5 ? ", #{folders.size - 5} more" : ""
        STDERR.puts "inbox: #{count(now.files, "file")} in #{count(folders.size, "folder")} skipped, not writable for the hub (group write missing?): #{shown}#{more}"
      elsif now != @unwritable
        STDERR.puts "inbox: all folders writable for the hub again"
      end
      @unwritable = now
    end

    private def count(n : Int32, what : String) : String
      "#{n} #{what}#{n == 1 ? "" : "s"}"
    end

    private def folder(path : String) : String
      dir = File.dirname(rel(path))
      dir == "." ? "" : dir
    end

    # A file still being written isn't looked at
    def settled?(mtime : Int64, now = Time.local) : Bool
      now.to_unix - mtime >= @stable.total_seconds
    end

    # What the scanner found to be no book of its format goes to _failed,
    # so nothing lies around without a word; other kinds of files stay
    def fail_broken(skipped : Array(Incoming::Skipped), now = Time.local)
      skipped.each do |s|
        next unless s.reason.starts_with?("broken")
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
