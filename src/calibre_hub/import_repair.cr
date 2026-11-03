require "db"
require "json"
require "./backlog"
require "./backlog_jobs"
require "./meta_filename"
require "./metadata"
require "./writer"

module CalibreHub
  # Repairs the metadata of books the backlog import added from a plain
  # file before it read file names itself (Meta::FileName): calibre took
  # "Carr - Formulas and Theorems … (Chelsea, 1970).djvu" as the title
  # "Carr" by "Formulas" and "Theorems …". Per book (import_files: the
  # file it came from) the name is read again, and a field changes only
  # where the book still has what the import gave it: calibre's reading of
  # the name, or a title the file brought along that says nothing
  # (Meta::FileName.bad_title?), possibly cleaned up by the metadata rules
  # since; a field someone edited stays. Publisher, year and series are
  # only filled. Every change goes to the metadata change log (source
  # "rules"), revertible there; the repaired books get a metadata run.
  class ImportRepair < Jobs
    # automatic changes the repair builds on (not a person's edits)
    AUTO = Set{"rules", "model", "authors"}

    record Planned, book_id : Int64, file : String, field : String, old : JSON::Any, new : JSON::Any do
      def to_json(json : JSON::Builder)
        {bookId: book_id, file: file, field: field, old: old, new: new}.to_json(json)
      end
    end

    # the metadata runs after a repair (when the cleanup is on)
    property metadata : MetadataJobs?

    def initialize(db : DB::Database, calibre : Calibre, writer : Writer, @log : MetaLog)
      super(db, calibre, writer, nil, "import_repair_jobs")
      @hints = {} of String => Symbol?
    end

    # book id -> the file calibre read it from (the unit's primary format),
    # for books an import added from plain files. params: since (time the
    # file was imported), minId, maxId
    def files(params : Hash(String, JSON::Any)) : Hash(Int64, String)
      since = params["since"]?.try(&.as_s?).try { |s| ImportCleanup.parse_time(s) }
      min = params["minId"]?.try { |v| v.as_i64? || raise Edit::Invalid.new("minId", "number expected") }
      max = params["maxId"]?.try { |v| v.as_i64? || raise Edit::Invalid.new("maxId", "number expected") }
      sql = "select path, book_id from import_files where status = 'imported' and book_id is not null"
      args = [] of DB::Any
      since.try { |t| sql += " and at >= ?"; args << t.to_unix }
      min.try { |v| sql += " and book_id >= ?"; args << v }
      max.try { |v| sql += " and book_id <= ?"; args << v }
      by_book = {} of Int64 => Array(String)
      @db.query_each(sql + " order by book_id", args: args) do |rs|
        path, id = rs.read(String, Int64)
        (by_book[id] ||= [] of String) << path
      end
      result = {} of Int64 => String
      by_book.each do |id, paths|
        # a calibre folder's books came from its metadata.opf
        next if paths.any? { |p| File.exists?(File.join(File.dirname(p), Backlog::OPF)) }
        result[id] = paths.min_by { |p| Backlog::FORMATS.index(File.extname(p).lchop('.').upcase) || Backlog::FORMATS.size }
      end
      result
    end

    # The changes a repair would make, book by book
    def plan(params : Hash(String, JSON::Any)) : Array(Planned)
      files = files(params)
      return [] of Planned if files.empty?
      baselines = baselines(files.keys)
      @calibre.books(files.keys, Calibre::DETAIL_FIELDS).flat_map do |b|
        path = files[b.id]
        plan_book(b, path, baselines[b.id]?).map { |c| Planned.new(b.id, path, c.field, c.old, c.new) }
      end
    end

    # dry run: the planned changes; else 202 with the job that makes them
    def submit_repair(params : Hash(String, JSON::Any), dry_run : Bool) : JSON::Any
      planned = plan(params)
      books = planned.map(&.book_id).uniq
      if dry_run
        return JSON.parse({dryRun: true, books: books.size, total: planned.size, changes: planned}.to_json)
      end
      files = files(params).select { |id, _| books.includes?(id) }
      job = enqueue(books, {"files" => JSON.parse(files.transform_keys(&.to_s).to_json)})
      JSON.parse({dryRun: false, books: books.size, total: planned.size, changes: planned, job: job}.to_json)
    end

    # What the file name gives the book where it still has the import's
    # values (Meta::FileName.changes)
    def plan_book(book : Book, path : String, baseline : JSON::Any?) : Array(Meta::Change)
      ImportRepair.plan_book(book, path, hint(File.dirname(path)), baseline, @log.active(book.id).reverse)
    end

    # log: the book's active changes, oldest first
    def self.plan_book(book : Book, path : String, hint : Symbol?, baseline : JSON::Any?, log : Array(MetaLog::Entry)) : Array(Meta::Change)
      name = File.basename(path)
      guess = Meta::FileName.parse(name, hint) || return [] of Meta::Change
      cg_title, cg_authors = Meta::FileName.calibre(name)
      imported = ->(field : String) do
        origins = [] of JSON::Any
        case field
        when "title"
          origins << JSON::Any.new(cg_title)
          baseline.try(&.["title"]?).try { |t| origins << t }
        when "authors"
          origins << JSON.parse(cg_authors.to_json)
          baseline.try(&.["authors"]?).try { |a| origins << a }
        else
          origins << JSON::Any.new(nil)
        end
        ImportRepair.origin(field, Meta::Merge.value(book, field), origins, log)
      end
      Meta::FileName.changes(book, name, guess, imported)
    end

    # The value the field had when the book was imported (one of origins),
    # if it still has it or only automatic changes since (the change log,
    # oldest first); nil when someone changed it
    def self.origin(field : String, current : JSON::Any, origins : Array(JSON::Any), log : Array(MetaLog::Entry)) : JSON::Any?
      same = ->(a : JSON::Any, b : JSON::Any) do
        if (x = a.as_s?) && (y = b.as_s?)
          Meta::FileName.same_text?(x, y)
        elsif (la = a.as_a?) && (lb = b.as_a?)
          Meta::FileName.same_authors?(la.map(&.to_s), lb.map(&.to_s))
        else
          Meta::Merge.same?(field, a, b)
        end
      end
      origins.each { |o| return o if same.call(o, current) }
      entries = log.select { |e| e.field == field }
      return nil if entries.empty? || !entries.all? { |e| AUTO.includes?(e.source) }
      return nil unless same.call(entries.last.new, current)
      origins.find { |o| same.call(o, entries.first.old) }
    end

    # the book as the import left it: its first "added" event
    private def baselines(ids : Array(Int64)) : Hash(Int64, JSON::Any)
      found = {} of Int64 => JSON::Any
      ids.each_slice(500) do |slice|
        @db.query_each("select book_id, payload from events where type = 'added' and book_id in (#{slice.join(",")}) order by id") do |rs|
          id, payload = rs.read(Int64, String)
          next if found.has_key?(id)
          JSON.parse(payload)["book"]?.try { |b| found[id] = b }
        end
      end
      found
    end

    private def hint(dir : String) : Symbol?
      return @hints[dir] if @hints.has_key?(dir)
      names = begin
        Dir.children(dir).select { |n| Backlog::Scanner.format(n) }
      rescue File::Error
        # the backlog isn't there (any more): the files the imports handled
        list = [] of String
        @db.query_each("select path from import_files where path like ?", "#{dir}/%") do |rs|
          p = rs.read(String)
          list << File.basename(p) if File.dirname(p) == dir
        end
        list
      end
      @hints[dir] = Meta::FileName.orientation(names)
    end

    protected def apply(job : Job, index : Int32, id : Int64, resumed : Bool)
      path = job.changes["files"]?.try(&.[id.to_s]?).try(&.as_s?) || return
      book = @calibre.book(id) || raise Writer::NotFound.new
      changes = plan_book(book, path, baselines([id])[id]?)
      write(book, changes, job.id) unless changes.empty?
    ensure
      if index == job.total - 1
        repaired = @log.books(job.id)
        if (m = @metadata) && !repaired.empty?
          run = m.enqueue_books(repaired, false, "ids")
          puts "import repair: job #{job.id}: metadata run #{run.id} for #{repaired.size} books"
        end
      end
    end

    # One PATCH with lastModified (a book changed meanwhile is a Conflict,
    # that book fails), the tag of the cleanup, each field in the log
    private def write(book : Book, changes : Array(Meta::Change), job_id : String)
      body = Meta::Merge.patch(book, changes.to_h { |c| {c.field, c.new} })
      body["lastModified"] = JSON::Any.new(book.version)
      Meta::Merge.tags(body, "addTags", [Meta::TAG])
      updated = @writer.update(book.id, body)
      changes.each do |c|
        now = Meta::Merge.value(updated, c.field)
        next if Meta::Merge.same?(c.field, c.old, now)
        @log.add(book.id, c.field, c.old, now, c.source, job_id)
      end
    end
  end

  # POST /api/import/repair {dryRun?, since?, minId?, maxId?}
  def self.import_repair_routes(repair : ImportRepair?)
    post "/api/import/repair" do |env|
      write_errors(env) do
        next fail(env, 404, {error: "backlog import is off"}) unless repair
        body = json_body(env)
        dry = body.delete("dryRun").try(&.as_bool?)
        dry = true if dry.nil?
        result = repair.submit_repair(body, dry)
        env.response.status_code = dry ? 200 : 202
        result.to_json
      end
    end
  end
end
