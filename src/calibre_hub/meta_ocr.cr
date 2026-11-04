require "digest/sha256"
require "file_utils"
require "./command"
require "./meta_rules"

module CalibreHub
  module Meta
    # Text of a file without a text layer: its first and last few pages
    # through Tesseract (German and English). A backlog has thousands of
    # scans, so this runs on few pages, at most `jobs` books at a time, one
    # thread each and at low priority, and every page and book has a time
    # limit. A labelled ISBN on the first pages ends the book early. What
    # was read is kept (Cache): a later plan or import of the same file
    # doesn't read it again.
    module Ocr
      FRONT_PAGES  =   6
      BACK_PAGES   =   2
      DPI          = 200
      LANGUAGES    = "deu+eng"
      PAGE_TIMEOUT = 90.seconds
      BOOK_TIMEOUT = 5.minutes
      # bytes of the file's start and end that name it in the cache
      KEY_BYTES = 1024 * 1024

      # key of the file -> its first and last pages, nil when unknown
      alias Lookup = Proc(String, {String, String}?)
      alias Store = Proc(String, String, String, Nil)
      record Cache, get : Lookup, put : Store

      # books read at the same time, 0: no OCR
      @@slots = Channel(Nil).new(2)
      @@jobs = 2

      def self.jobs : Int32
        @@jobs
      end

      def self.jobs=(n : Int32)
        @@jobs = n
        @@slots = Channel(Nil).new({n, 1}.max)
      end

      # {front, back}; nil when there is nothing to read
      def self.read(path : String, format : String, cache : Cache? = nil) : {String, String}?
        return nil if @@jobs <= 0
        key = cache ? key(path) : ""
        if hit = cache.try(&.get.call(key))
          return hit
        end
        slots = @@slots
        slots.send(nil)
        begin
          pages = pages(path, format) || return nil
          text = book(path, format, pages)
        ensure
          slots.receive
        end
        cache.try(&.put.call(key, text[0], text[1]))
        text
      rescue ex : File::Error | IO::Error
        STDERR.puts "ocr: #{File.basename(path)}: #{ex.message}"
        nil
      end

      def self.key(path : String) : String
        File.open(path) do |f|
          digest = Digest::SHA256.new
          part = Bytes.new({KEY_BYTES.to_i64, f.size}.min)
          f.read_fully(part)
          digest.update(part)
          f.seek(-part.size, IO::Seek::End)
          f.read_fully(part)
          digest.update(part)
          "#{f.size}-#{digest.final.hexstring}"
        end
      end

      # which pages to read: the first, then the last ones
      def self.selection(pages : Int32) : {Array(Int32), Array(Int32)}
        front = (1..{FRONT_PAGES, pages}.min).to_a
        back = ({pages - BACK_PAGES + 1, front.size + 1}.max..pages).to_a
        {front, back}
      end

      private def self.pages(path : String, format : String) : Int32?
        output = IO::Memory.new
        if format == "PDF"
          Command.run("pdfinfo", [path], PAGE_TIMEOUT, output: output)
          output.to_s.scrub[/^Pages:\s*(\d+)/m, 1]?.try(&.to_i?)
        else
          Command.run("djvused", ["-e", "n", path], PAGE_TIMEOUT, output: output)
          output.to_s.strip.to_i?
        end
      rescue File::NotFoundError | IO::Error | Command::Timeout
        nil
      end

      private def self.book(path : String, format : String, pages : Int32) : {String, String}
        front_pages, back_pages = selection(pages)
        ends = Time.instant + BOOK_TIMEOUT
        dir = File.tempname("ocr")
        Dir.mkdir(dir)
        begin
          front = read_pages(path, format, front_pages, dir, ends)
          return {front, ""} if Isbn.found(front).any?(&.labelled)
          {front, read_pages(path, format, back_pages, dir, ends)}
        ensure
          FileUtils.rm_rf(dir)
        end
      end

      private def self.read_pages(path : String, format : String, list : Array(Int32), dir : String, ends : Time::Instant) : String
        String.build do |io|
          list.each do |p|
            break if Time.instant > ends
            io << page(path, format, p, dir) << '\f'
          end
        end
      end

      # one page as an image, then its text; "" when a tool gives up
      private def self.page(path : String, format : String, number : Int32, dir : String) : String
        image = File.join(dir, "page.pgm")
        if format == "PDF"
          Command.run("pdftoppm", ["-r", DPI.to_s, "-gray", "-singlefile", "-f", number.to_s, "-l", number.to_s, path, File.join(dir, "page")], PAGE_TIMEOUT)
        else
          Command.run("ddjvu", ["-format=pgm", "-scale=#{DPI}", "-page=#{number}", path, image], PAGE_TIMEOUT)
        end
        return "" unless File.exists?(image)
        output = IO::Memory.new
        status = Command.run("nice", ["-n", "15", "tesseract", image, "-", "-l", LANGUAGES], PAGE_TIMEOUT,
          env: {"OMP_THREAD_LIMIT" => "1"}, output: output)
        status.success? ? output.to_s.scrub : ""
      rescue File::NotFoundError | IO::Error | Command::Timeout
        ""
      ensure
        File.delete?(File.join(dir, "page.pgm"))
      end
    end
  end
end
