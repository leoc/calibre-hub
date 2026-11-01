require "json"
require "./calibre"
require "./detector"

module CalibreHub
  # Imports files dropped into the inbox through calibre-server.
  # inbox/Fachbuch/Software/x.epub becomes a book with #<category column>
  # "Fachbuch.Software" and the tags "Fachbuch" and "Software"; tags embedded
  # in the file are dropped. Originals move to _imported/<date>/ (new) or
  # _duplicates/<date>/ (already there), keeping the subfolders. Directories
  # starting with "_" or "." are not imported.
  class Inbox
    EXTENSIONS = %w(epub pdf mobi azw azw3 kepub fb2 djvu cbz cbr docx rtf txt)
    # failures before a file is moved to _failed/
    MAX_FAILURES = 3

    def initialize(@dir : String, @calibre : Calibre, @detector : Detector,
                   @category_column : String?, @stable : Time::Span = 2.minutes)
      @failures = Hash(String, Int32).new(0)
    end

    # One pass; returns the number of files handled
    def run_once(now = Time.local) : Int32
      handled = 0
      files.each do |path|
        info = File.info?(path) || next
        next if now - info.modification_time < @stable
        import(path, now)
        handled += 1
      end
      cleanup(@dir, now)
      handled
    end

    def files : Array(String)
      found = [] of String
      walk(@dir) { |p| found << p }
      found.sort
    end

    # Category and tags from the folders between the inbox and the file
    def self.classify(rel : String) : {String?, Array(String)}
      folders = File.dirname(rel).split('/').reject { |p| p.empty? || p == "." }.map(&.strip).reject(&.empty?)
      {folders.empty? ? nil : folders.join('.'), folders}
    end

    private def import(path : String, now : Time)
      rel = path.lchop(@dir).lchop('/')
      # importing without being able to move the file away would import it
      # again on the next pass
      unless File::Info.writable?(File.dirname(path))
        if @failures[path] == 0
          STDERR.puts "inbox: #{rel} skipped, #{File.dirname(rel)} is not writable for the hub (group write missing?)"
        end
        @failures[path] = 1
        return
      end
      result = @calibre.add_book(path, File.basename(path))
      if id = result.book_id
        category, tags = Inbox.classify(rel)
        changes = {"tags" => JSON.parse(tags.to_json)}
        if category && (col = @category_column)
          changes["##{col}"] = JSON::Any.new(category)
        end
        @calibre.set_fields(id, changes)
        @detector.touch([id]).each { |e| puts e.to_json }
        move(path, rel, "_imported", now)
        puts "inbox: imported #{rel} as ##{id}"
      else
        move(path, rel, "_duplicates", now)
        puts "inbox: duplicate #{rel} (#{result.duplicates.join("; ")})"
      end
      @failures.delete(path)
    rescue ex : Calibre::Unavailable
      STDERR.puts "inbox: #{ex.message}"
      raise ex
    rescue ex
      @failures[path] += 1
      STDERR.puts "inbox: #{rel} failed (#{@failures[path]}/#{MAX_FAILURES}): #{ex.message}"
      if @failures[path] >= MAX_FAILURES
        move(path, rel.not_nil!, "_failed", now)
        @failures.delete(path)
      end
    end

    private def move(path : String, rel : String, target : String, now : Time)
      dest = File.join(@dir, target, now.to_s("%F"), rel)
      Dir.mkdir_p(File.dirname(dest))
      dest = File.join(File.dirname(dest), "#{now.to_s("%H%M%S")}-#{File.basename(dest)}") if File.exists?(dest)
      File.rename(path, dest)
    end

    private def walk(dir : String, &block : String ->)
      Dir.each_child(dir) do |name|
        next if name.starts_with?('_') || name.starts_with?('.')
        path = File.join(dir, name)
        if File.directory?(path)
          walk(path, &block)
        elsif EXTENSIONS.includes?(File.extname(name).lchop('.').downcase)
          block.call(path)
        end
      end
    end

    # empty sorting folders go away once they are older than the stable time
    # (not the inbox itself, not _*), so a folder just created over Samba stays
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
