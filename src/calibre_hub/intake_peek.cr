require "file_utils"
require "./intake"

module CalibreHub
  # Reading in over a slow line: a large PDF's first pages instead of the
  # whole file, a DjVu's as a PDF, because the reader has none. Made on first
  # asking, at low priority, and kept next to the covers while the entry is
  # there; readable refuses a file changed since the analysis, so what is kept
  # is always of the file at hand.
  #
  # Per file and format in the folder, by what came of it:
  #   <id>-PDF.pdf         the first pages
  #   <id>-DJVU.all.pdf    a DjVu short enough to be all of it
  #   <id>-PDF.whole       nothing to gain or the tools can't: not tried again
  #   <id>-PDF.build/      at work
  # A book's file itself is only read.
  class Intake
    # what a look into a book takes; the reader says so from the header
    PEEK_PAGES  = 30
    PEEK_HEADER = "X-Hub-Excerpt-Pages"
    # below this a file is there soon enough as it is
    PEEK_FROM = 8_000_000_i64
    # no reader for these, only their first pages as a PDF
    DJVU     = %w(DJVU DJV)
    PEEKABLE = READABLE + DJVU

    # path: what to send, nil when there is nothing. excerpt: only the first
    # pages of the book.
    record Peek, path : String?, excerpt : Bool = false

    # where the first pages go, next to the covers
    property peeks : String
    property peek_from = PEEK_FROM
    # the first pages at a path (FileMeta.first_pages), how many the file has
    property peek_reader : Proc(String, String, String, Int32?) = ->(path : String, format : String, target : String) do
      Meta::FileMeta.first_pages(path, format, target, PEEK_PAGES, nice: true)
    end

    # what is at work: who comes second waits for it
    @peek_builds = {} of String => Channel(Nil)
    @peek_lock = Mutex.new

    # What to send for the entry's file when a look is enough
    def peek(id : Int64, file : Incoming::BookFile) : Peek
      djvu = DJVU.includes?(file.format)
      return Peek.new(file.path) unless djvu || (file.format == "PDF" && file.size > @peek_from)
      base = File.join(@peeks, "#{id}-#{file.format}")
      once(base) { build_peek(id, base, file, djvu) unless peek_done?(base) }
      return Peek.new("#{base}.pdf", true) if File.file?("#{base}.pdf")
      return Peek.new("#{base}.all.pdf") if File.file?("#{base}.all.pdf")
      Peek.new(djvu ? nil : file.path)
    end

    private def peek_done?(base : String) : Bool
      {".pdf", ".all.pdf", ".whole"}.any? { |ext| File.exists?(base + ext) }
    end

    # one at a time per key, the others wait for that one instead
    private def once(key : String, &)
      other = @peek_lock.synchronize do
        @peek_builds[key]?.tap { |c| @peek_builds[key] = Channel(Nil).new unless c }
      end
      if other
        other.receive?
        return
      end
      begin
        yield
      ensure
        @peek_lock.synchronize { @peek_builds.delete(key).try(&.close) }
      end
    end

    private def build_peek(id : Int64, base : String, file : Incoming::BookFile, djvu : Bool)
      work = "#{base}.build"
      FileUtils.rm_rf(work)
      Dir.mkdir_p(work)
      made = File.join(work, "peek.pdf")
      pages = @peek_reader.call(file.path, file.format, made)
      if pages && File.file?(made) && (djvu || File.size(made) * 3 <= file.size * 2)
        File.rename(made, pages > PEEK_PAGES ? "#{base}.pdf" : "#{base}.all.pdf")
      else
        File.touch("#{base}.whole")
      end
      # it left the list meanwhile, nobody would remove this later
      forget_peeks(id) unless self[id]?
    rescue ex : File::Error | IO::Error
      STDERR.puts "intake: no first pages of #{file.path}: #{ex.message}"
    ensure
      FileUtils.rm_rf(work) if work
    end

    private def forget_peeks(id : Int64)
      return unless Dir.exists?(@peeks)
      Dir.children(@peeks).each { |n| FileUtils.rm_rf(File.join(@peeks, n)) if n.starts_with?("#{id}-") }
    rescue ex : File::Error
      STDERR.puts "intake: first pages of #{id} stay: #{ex.message}"
    end
  end
end
