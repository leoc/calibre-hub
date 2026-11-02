require "http"
require "file_utils"
require "./covers"
require "./calibre"
require "./detector"
require "./edit"
require "./api"

module CalibreHub
  # Write side of the API. Every write goes to calibre-server and is then
  # run through the detector, so handlers see it right away.
  class Writer
    class NotFound < Exception
    end

    class Conflict < Exception
      getter book : Book

      def initialize(@book)
        super("changed in the meantime")
      end
    end

    class Duplicates < Exception
      getter books : Array(Book)
      getter titles : Array(String)

      def initialize(@books, @titles)
        super("duplicate")
      end
    end

    class Unsupported < Exception
    end

    class TooLarge < Exception
    end

    MAX_UPLOAD = 200_i64 * 1024 * 1024
    # calibre's BOOK_EXTENSIONS (9.14); recipes are refused by calibre anyway
    EXTENSIONS = %w(lrf rar zip rtf lit txt txtz text htm xhtm html htmlz xhtml pdf pdb updb pdr prc
      mobi azw doc epub fb2 fbz djv djvu lrx cbr cb7 cbz cbc oebzip rb imp odt chm tpz azw1 pml pmlz
      mbp tan snb xps oxps azw4 book zbf pobi docx docm md textile markdown ibook ibooks iba azw3 ps
      kepub kfx kpf)

    record Upload, file : String, filename : String, tags : Array(String), kategorie : String?,
      force : Bool, add_format_to : Int64?

    getter calibre : Calibre

    def initialize(@calibre : Calibre, @detector : Detector?, @wake : Channel(Nil)?,
                   @category_column : String?)
    end

    def update(id : Int64, body : Hash(String, JSON::Any)) : Book
      current = @calibre.book(id) || raise NotFound.new
      raise Conflict.new(current) if Edit.conflict?(body, current)
      changes = Edit.changes(body, current, @category_column)
      @calibre.set_fields(id, changes) unless changes.empty?
      written([id])
      @calibre.book(id) || raise NotFound.new
    end

    # Reads a multipart upload into a temp file; the caller deletes it
    def self.read_upload(request : HTTP::Request, dir = Dir.tempdir) : Upload
      if (len = request.headers["Content-Length"]?.try(&.to_i64?)) && len > MAX_UPLOAD + 1024 * 1024
        raise TooLarge.new
      end
      file = nil
      filename = ""
      tags = [] of String
      kategorie = nil
      force = false
      add_to = nil
      HTTP::FormData.parse(request) do |part|
        case part.name
        when "file"
          raise Edit::Invalid.new("file", "only one file per request") if file
          filename = File.basename(part.filename.presence || raise Edit::Invalid.new("file", "file name missing"))
          tmp = File.tempfile("upload", File.extname(filename), dir: dir)
          file = tmp.path
          copied = IO.copy(part.body, tmp, MAX_UPLOAD + 1)
          tmp.close
          raise TooLarge.new if copied > MAX_UPLOAD
        when "tags"
          part.body.gets_to_end.strip.presence.try { |t| tags << t }
        when "kategorie"
          kategorie = part.body.gets_to_end.strip.presence
        when "force"
          force = {"1", "true", "yes"}.includes?(part.body.gets_to_end.strip)
        when "addFormatTo"
          add_to = part.body.gets_to_end.strip.to_i64? || raise Edit::Invalid.new("addFormatTo", "book id expected")
        else
          raise Edit::Invalid.new(part.name, "unknown field")
        end
      end
      Upload.new(file || raise(Edit::Invalid.new("file", "file missing")), filename, tags.uniq, kategorie, force, add_to)
    rescue ex : HTTP::FormData::Error | IO::Error
      file.try { |f| File.delete?(f) }
      raise Edit::Invalid.new("file", "multipart/form-data expected: #{ex.message}")
    rescue ex
      file.try { |f| File.delete?(f) }
      raise ex
    end

    def self.extension(filename : String) : String
      ext = File.extname(filename).lchop('.').downcase
      raise Unsupported.new("unsupported format: #{ext.presence || "none"}") unless EXTENSIONS.includes?(ext)
      ext
    end

    # {book, created}
    def upload(u : Upload) : {Book, Bool}
      ext = Writer.extension(u.filename)
      if id = u.add_format_to
        @calibre.book(id) || raise NotFound.new
        @calibre.add_format(id, u.file, ext)
        written([id])
        return {@calibre.book(id) || raise(NotFound.new), false}
      end

      raise Edit::Invalid.new("kategorie", "no category column configured") if u.kategorie && !@category_column
      added = @calibre.add_book(u.file, u.filename, duplicates: u.force)
      id = added.book_id || raise Duplicates.new(duplicate_books(added.duplicates), added.duplicates.map(&.to_s))
      # embedded tags are dropped, like in the inbox
      changes = {"tags" => JSON.parse(u.tags.to_json)}
      if (k = u.kategorie) && (col = @category_column)
        changes["##{col}"] = JSON::Any.new(k)
      end
      @calibre.set_fields(id, changes)
      written([id])
      {@calibre.book(id) || raise(NotFound.new), true}
    end

    # calibre only names title and authors of the books it matched
    def duplicate_books(dups : Array(Calibre::Duplicate)) : Array(Book)
      ids = dups.flat_map do |d|
        query = %(title:"=#{Api.escape(d.title)}")
        query += d.authors.map { |a| %( and authors:"=#{Api.escape(a)}") }.join
        @calibre.search(query, "id", true, 0, 20).ids
      end
      @calibre.books(ids.uniq, Calibre::DETAIL_FIELDS)
    rescue ex : Calibre::Error
      STDERR.puts "duplicate lookup failed: #{ex.message}"
      [] of Book
    end

    private def written(ids : Array(Int64))
      if d = @detector
        d.touch(ids).each { |e| puts e.to_json }
      end
      if w = @wake
        select
        when w.send(nil)
        else
        end
      end
    end
  end
end

module CalibreHub
  # Bulk edits run as background jobs, one after another. Jobs live in
  # memory only; after a restart their ids are unknown (404).
  class Jobs
    CHANGES = %w(addTags removeTags kategorie series)
    KEEP    = 50

    class Job
      include JSON::Serializable

      getter id : String
      property status : String = "running"
      property done : Int32 = 0
      getter total : Int32
      getter errors = [] of NamedTuple(bookId: Int64, error: String)
      @[JSON::Field(ignore: true)]
      getter ids : Array(Int64)
      @[JSON::Field(ignore: true)]
      getter changes : Hash(String, JSON::Any)

      def initialize(@ids, @changes)
        @id = Random::Secure.hex(8)
        @total = @ids.size
      end
    end

    def initialize(@calibre : Calibre, @writer : Writer, @category_column : String?)
      @jobs = {} of String => Job
      @queue = Channel(Job).new(100)
      spawn { loop { run(@queue.receive) } }
    end

    def []?(id : String) : Job?
      @jobs[id]?
    end

    # body: {target: {ids: [...]} | {query: {...}}, changes: {...}}
    def submit(body : Hash(String, JSON::Any)) : Job
      changes = body["changes"]?.try(&.as_h?) || raise Edit::Invalid.new("changes", "object expected")
      raise Edit::Invalid.new("changes", "nothing to change") if changes.empty?
      if bad = changes.keys.find { |k| !CHANGES.includes?(k) }
        raise Edit::Invalid.new(bad, "not allowed in bulk edits")
      end
      # type errors now rather than once per book
      Edit.changes(changes, Jobs.blank, @category_column)
      job = Job.new(ids(body["target"]?), changes)
      @jobs[job.id] = job
      @jobs.shift? if @jobs.size > KEEP
      @queue.send(job)
      job
    end

    def ids(target : JSON::Any?) : Array(Int64)
      t = target.try(&.as_h?) || raise Edit::Invalid.new("target", "object expected")
      if list = t["ids"]?
        (list.as_a? || raise Edit::Invalid.new("target", "ids must be a list")).map do |v|
          v.as_i64? || raise Edit::Invalid.new("target", "ids must be numbers")
        end.uniq
      elsif query = t["query"]?.try(&.as_h?)
        params = HTTP::Params.new
        query.each do |k, v|
          raise Edit::Invalid.new("target", "offset/limit not allowed") if {"offset", "limit", "sort", "order"}.includes?(k)
          (v.as_a? || [v]).each { |x| params.add(k, x.as_s? || x.to_s) }
        end
        @calibre.search(Api.query(params, @category_column), "id", true, 0, 1_000_000).ids
      else
        raise Edit::Invalid.new("target", "ids or query expected")
      end
    end

    private def run(job : Job)
      job.ids.each do |id|
        begin
          @writer.update(id, job.changes)
        rescue Writer::NotFound
          job.errors << {bookId: id, error: "not found"}
        rescue ex
          job.errors << {bookId: id, error: ex.message || ex.class.name}
        end
        job.done += 1
      end
      job.status = job.errors.size == job.total && job.total > 0 ? "failed" : "done"
    end

    def self.blank : Book
      Book.new(id: 0_i64, title: "", authors: [] of String, author_sort: nil, tags: [] of String,
        series: nil, series_index: nil, formats: [] of String, last_modified: Time::UNIX_EPOCH,
        timestamp: nil, pubdate: nil, rating: nil, publisher: nil, identifiers: {} of String => String,
        languages: [] of String, comments: nil, custom: {} of String => JSON::Any)
    end
  end
end

module CalibreHub
  class Writer
    class NoCover < Exception
    end

    COVER_FORMATS = %w(EPUB AZW3 MOBI PDF)

    def set_cover(id : Int64, data : Bytes) : Book
      @calibre.book(id) || raise NotFound.new
      type = Covers.image_type(data)
      raise Unsupported.new("JPEG or PNG expected#{type == "webp" ? " (convert WebP first)" : ""}") unless {"jpeg", "png"}.includes?(type)
      @calibre.set_cover(id, data, type.not_nil!)
      written([id])
      @calibre.book(id) || raise NotFound.new
    end

    def cover_from_url(id : Int64, url : String) : Book
      @calibre.book(id) || raise NotFound.new
      data, _ = Covers.fetch(url)
      set_cover(id, data)
    rescue ex : Covers::FetchError
      raise Edit::Invalid.new("url", ex.message || "download failed")
    end

    # Extracts the cover from a book file with ebook-meta
    def cover_from_file(id : Int64, format : String?) : Book
      book = @calibre.book(id) || raise NotFound.new
      fmt = if f = format.presence
              f.upcase.tap { |u| raise Edit::Invalid.new("format", "book has no #{u}") unless book.formats.includes?(u) }
            else
              COVER_FORMATS.find { |f| book.formats.includes?(f) } || book.formats.first? || raise NoCover.new("book has no files")
            end
      dir = File.tempname("cover")
      Dir.mkdir(dir)
      begin
        file = File.join(dir, "book.#{fmt.downcase}")
        File.open(file, "w") do |out_io|
          @calibre.forward("GET", "/get/#{fmt.downcase}/#{id}") do |r|
            raise NotFound.new unless r.success?
            IO.copy(r.body_io, out_io)
          end
        end
        jpg = File.join(dir, "cover.jpg")
        status = Process.run("ebook-meta", [file, "--get-cover=#{jpg}"], env: {"QT_QPA_PLATFORM" => "offscreen"},
          output: Process::Redirect::Close, error: Process::Redirect::Close)
        raise NoCover.new("no cover in file") unless status.success? && File.exists?(jpg) && File.size(jpg) > 0
        set_cover(id, File.open(jpg, &.getb_to_end))
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end
end
