require "db"
require "json"
require "./backlog"
require "./backlog_jobs"
require "./meta_filename"
require "./meta_quality"
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
  # only filled. A name that can't be read for sure is decided by the file,
  # the metadata sources or the model (Meta::FileName.decide), else title
  # and authors stay and the book gets the unsure tag. A reading without an
  # author asks the catalogs (Meta::CrossCheck): what they confirm is taken,
  # anything less goes to the review with that tag.
  #
  # Books an import didn't add from a plain file (an upload, the inbox, a
  # calibre folder) are planned too when Meta::Quality finds them suspicious:
  # their title is read like a name (Meta::FileName.decide_own).
  #
  # A plan is a job that stores the proposals per book (import_repairs);
  # they are reviewed and accepted (a job that applies them, if the book
  # still has the values the plan saw) or rejected. Every change goes to
  # the metadata change log (source "rules"), revertible there; the
  # repaired books get a metadata run.
  class ImportRepair < Jobs
    # automatic changes the repair builds on (not a person's edits)
    AUTO = Set{"rules", "model", "authors"}
    # the import runs and books the quality report shows
    QUALITY_RUNS   = 5
    QUALITY_SAMPLE = 20

    record Proposed, field : String, old : JSON::Any, new : JSON::Any do
      include JSON::Serializable
    end

    # the metadata runs after a repair (when the cleanup is on)
    property metadata : MetadataJobs?
    # decides unclear names (Metadata#decider)
    property decider : Meta::FileName::Decider?
    # asks the catalogs about readings without an author (Metadata#checker)
    property checker : Meta::FileName::Checker?

    def initialize(db : DB::Database, calibre : Calibre, writer : Writer, @log : MetaLog)
      db.exec <<-SQL
        create table if not exists import_repairs (
          book_id integer primary key,
          file text not null,
          decided text,
          changes text not null,
          status text not null,
          detail text,
          at integer not null
        )
        SQL
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

    # Queues a plan of the books (not those accepted or rejected before);
    # apply: accept every proposal right away (the CLI's --apply)
    def submit_repair(params : Hash(String, JSON::Any), dry_run : Bool) : JSON::Any
      done = Set(Int64).new
      @db.query_each("select book_id from import_repairs where status in ('applied', 'rejected')") { |rs| done << rs.read(Int64) }
      files = files(params).reject { |id, _| done.includes?(id) }
      others = portion(params).select { |b| !done.includes?(b.id) && !files.has_key?(b.id) && !Meta::Quality.reasons(b).empty? }.map(&.id)
      ids = files.keys + others
      job = enqueue(ids, {"mode" => JSON::Any.new("plan"), "apply" => JSON::Any.new(!dry_run),
                          "files" => JSON.parse(files.transform_keys(&.to_s).to_json)})
      JSON.parse({dryRun: dry_run, books: ids.size, job: job}.to_json)
    end

    # The library's books in a portion. params: since (when the book was
    # added), minId, maxId, run (the books an import run added)
    private def portion(params : Hash(String, JSON::Any)) : Array(Book)
      since = params["since"]?.try(&.as_s?).try { |s| ImportCleanup.parse_time(s) }
      min = params["minId"]?.try { |v| v.as_i64? || raise Edit::Invalid.new("minId", "number expected") }
      max = params["maxId"]?.try { |v| v.as_i64? || raise Edit::Invalid.new("maxId", "number expected") }
      run = params["run"]?.try(&.as_s?).try { |r| run_books(r) }
      @calibre.list("", Calibre::DETAIL_FIELDS).select do |b|
        next false if min && b.id < min
        next false if max && b.id > max
        next false if since && (b.timestamp.nil? || b.timestamp.not_nil! < since)
        run.nil? || run.includes?(b.id)
      end
    end

    private def run_books(run : String) : Set(Int64)
      ids = Set(Int64).new
      @db.query_each("select distinct book_id from import_files where run_id = ? and status = 'imported' and book_id is not null", run) { |rs| ids << rs.read(Int64) }
      ids
    end

    # How many books of a portion look wrong and why (Meta::Quality); with
    # the library as the portion, also per import run, the last ones first
    def quality(params : Hash(String, JSON::Any)) : JSON::Any
      books = portion(params)
      suspects = books.compact_map { |b| Meta::Quality.reasons(b).try { |r| {b, r} unless r.empty? } }
      counts = Meta::Quality::REASONS.to_h { |r| {r, suspects.count { |_, list| list.includes?(r) }} }
      runs = [] of NamedTuple(run: String, at: String, total: Int32, suspect: Int32)
      if params.empty?
        by_id = suspects.map { |b, _| b.id }.to_set
        known = books.map(&.id).to_set
        latest = [] of {String, Int64}
        @db.query_each("select run_id, max(at) from import_files where status = 'imported' and book_id is not null group by run_id order by max(at) desc limit ?", QUALITY_RUNS) do |rs|
          latest << rs.read(String, Int64)
        end
        latest.each do |run, at|
          ids = run_books(run) & known
          runs << {run: run, at: Time.unix(at).to_rfc3339, total: ids.size, suspect: (ids & by_id).size}
        end
      end
      sample = suspects.first(QUALITY_SAMPLE).map { |b, r| {id: b.id, title: b.title, authors: b.authors, reasons: r} }
      JSON.parse({total: books.size, suspect: suspects.size, reasons: counts, runs: runs, books: sample}.to_json)
    end

    # Applies the proposals of these books (nil: all open ones)
    def accept(ids : Array(Int64)?) : JSON::Any
      open = proposals("pending").map(&.[0])
      books = ids ? ids.select { |id| open.includes?(id) } : open
      job = enqueue(books, {"mode" => JSON::Any.new("apply")})
      JSON.parse({books: books.size, job: job}.to_json)
    end

    # Rejects the proposals of these books (nil: all open ones); a later
    # plan leaves them out
    def reject(ids : Array(Int64)?) : Int64
      now = Time.utc.to_unix
      if ids
        ids.sum(0_i64) { |id| @db.exec("update import_repairs set status = 'rejected', at = ? where book_id = ? and status = 'pending'", now, id).rows_affected }
      else
        @db.exec("update import_repairs set status = 'rejected', at = ? where status = 'pending'", now).rows_affected
      end
    end

    # {book, file, who decided, changes, status, detail, at}
    def proposals(status : String? = nil) : Array({Int64, String, String?, Array(Proposed), String, String?, Int64})
      list = [] of {Int64, String, String?, Array(Proposed), String, String?, Int64}
      sql = "select book_id, file, decided, changes, status, detail, at from import_repairs"
      args = [] of DB::Any
      status.try { |s| sql += " where status = ?"; args << s }
      @db.query_each(sql + " order by book_id", args: args) do |rs|
        id, file, decided, changes, st, detail, at = rs.read(Int64, String, String?, String, String, String?, Int64)
        list << {id, file, decided, Array(Proposed).from_json(changes), st, detail, at}
      end
      list
    end

    # The open proposals with their books for the review, counts per status
    def review : JSON::Any
      counts = Hash(String, Int64).new(0_i64)
      @db.query_each("select status, count(*) from import_repairs group by status") { |rs| counts[rs.read(String)] = rs.read(Int64) }
      open = proposals("pending")
      books = @calibre.books(open.map(&.[0]))
      entries = open.map do |id, file, decided, changes, status, _, at|
        {bookId: id, file: file, decided: decided, status: status, at: Time.unix(at).to_rfc3339,
         changes: changes.map { |c| {field: c.field, old: c.old, new: c.new} }}
      end
      job = last.try(&.[0])
      JSON.parse({entries: entries, books: books, counts: counts, job: job, unsureTag: Meta.unsure_tag}.to_json)
    end

    # What the file name gives the book where it still has the import's
    # values (Meta::FileName.decide), and who decided
    def plan_book(book : Book, path : String, baseline : JSON::Any?) : {Array(Meta::Change), String}
      ImportRepair.plan_book(book, path, hint(File.dirname(path)), baseline, @log.active(book.id).reverse, @decider, @checker)
    end

    # The same for a book without a file an import read
    def plan_own(book : Book, baseline : JSON::Any?) : {Array(Meta::Change), String}
      ImportRepair.plan_own(book, baseline, @log.active(book.id).reverse, @checker)
    end

    # No baseline (books older than the events): a value that looks wrong
    # counts as nobody's edit
    def self.plan_own(book : Book, baseline : JSON::Any?, log : Array(MetaLog::Entry),
                      checker : Meta::FileName::Checker? = nil) : {Array(Meta::Change), String}
      imported = ->(field : String) do
        current = Meta::Merge.value(book, field)
        ImportRepair.origin(field, current, [baseline.try(&.[field]?) || current], log)
      end
      Meta::FileName.decide_own(book, imported, checker) || {[] of Meta::Change, Meta::FileName::NAME}
    end

    # log: the book's active changes, oldest first
    def self.plan_book(book : Book, path : String, hint : Symbol?, baseline : JSON::Any?, log : Array(MetaLog::Entry),
                       decider : Meta::FileName::Decider? = nil, checker : Meta::FileName::Checker? = nil) : {Array(Meta::Change), String}
      name = File.basename(path)
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
      Meta::FileName.decide(book, name, hint, imported, decider, checker) || {[] of Meta::Change, Meta::FileName::NAME}
    end

    # The value the field had when the book was imported (one of origins),
    # if it still has it or only automatic changes since (the change log,
    # oldest first); nil when someone changed it
    def self.origin(field : String, current : JSON::Any, origins : Array(JSON::Any), log : Array(MetaLog::Entry)) : JSON::Any?
      origins.each { |o| return o if same?(field, o, current) }
      entries = log.select { |e| e.field == field }
      return nil if entries.empty? || !entries.all? { |e| AUTO.includes?(e.source) }
      return nil unless same?(field, entries.last.new, current)
      origins.find { |o| same?(field, o, entries.first.old) }
    end

    def self.same?(field : String, a : JSON::Any, b : JSON::Any) : Bool
      if (x = a.as_s?) && (y = b.as_s?)
        Meta::FileName.same_text?(x, y)
      elsif (la = a.as_a?) && (lb = b.as_a?)
        Meta::FileName.same_authors?(la.map(&.to_s), lb.map(&.to_s))
      else
        Meta::Merge.same?(field, a, b)
      end
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
      case job.changes["mode"]?.try(&.as_s?)
      when "plan"
        path = job.changes["files"]?.try(&.[id.to_s]?).try(&.as_s?)
        book = @calibre.book(id) || raise Writer::NotFound.new
        baseline = baselines([id])[id]?
        changes, decided = path ? plan_book(book, path, baseline) : plan_own(book, baseline)
        store(id, path || "", decided, changes)
        apply_book(id, job.id) if job.changes["apply"]?.try(&.as_bool?) && !changes.empty?
      when "apply"
        apply_book(id, job.id)
      end
    ensure
      if index == job.total - 1
        repaired = @log.books(job.id)
        if (m = @metadata) && !repaired.empty?
          run = m.enqueue_books(repaired, false, "ids")
          puts "import repair: job #{job.id}: metadata run #{run.id} for #{repaired.size} books"
        end
      end
    end

    private def store(id : Int64, path : String, decided : String, changes : Array(Meta::Change))
      if changes.empty?
        @db.exec "delete from import_repairs where book_id = ? and status not in ('applied', 'rejected')", id
        return
      end
      proposed = changes.map { |c| Proposed.new(c.field, c.old, c.new) }
      @db.exec "insert or replace into import_repairs (book_id, file, decided, changes, status, detail, at) values (?, ?, ?, ?, 'pending', null, ?)",
        id, path, decided, proposed.to_json, Time.utc.to_unix
    end

    # The stored proposal, if the book still has the values the plan saw
    private def apply_book(id : Int64, job_id : String)
      row = proposals("pending").find { |p| p[0] == id } || return
      book = @calibre.book(id) || raise Writer::NotFound.new
      changes = row[3].reject { |c| c.field == Meta::FileName::CANDIDATE }
      if changed = changes.find { |c| !ImportRepair.same?(c.field, c.old, Meta::Merge.value(book, c.field)) }
        @db.exec "update import_repairs set status = 'failed', detail = ?, at = ? where book_id = ?",
          "#{changed.field} changed since the plan", Time.utc.to_unix, id
        raise Exception.new("#{changed.field} changed since the plan, plan again")
      end
      write(book, changes.map { |c| Meta::Change.new(c.field, c.old, c.new, "rules") }, job_id) unless changes.empty?
      @db.exec "update import_repairs set status = 'applied', at = ? where book_id = ?", Time.utc.to_unix, id
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

  private def self.repair_ids(body : Hash(String, JSON::Any)) : Array(Int64)?
    return nil if body["all"]?.try(&.as_bool?)
    list = body["bookIds"]?.try(&.as_a?) || raise Edit::Invalid.new("bookIds", "list of book ids or all: true expected")
    list.map { |v| v.as_i64? || raise Edit::Invalid.new("bookIds", "numbers expected") }
  end

  # The repair: POST plans (a job), GET lists the open proposals, accept
  # and reject them (bookIds or all)
  def self.import_repair_routes(repair : ImportRepair?)
    post "/api/import/repair" do |env|
      write_errors(env) do
        next fail(env, 404, {error: "backlog import is off"}) unless repair
        body = json_body(env)
        dry = body.delete("dryRun").try(&.as_bool?)
        dry = true if dry.nil?
        env.response.status_code = 202
        repair.submit_repair(body, dry).to_json
      end
    end

    get "/api/import/repair" do |env|
      next fail(env, 404, {error: "backlog import is off"}) unless repair
      repair.review.to_json
    end

    # the quality report: of the library (with the last runs), a run, an
    # id range or the books added since
    get "/api/import/quality" do |env|
      write_errors(env) do
        next fail(env, 404, {error: "backlog import is off"}) unless repair
        params = {} of String => JSON::Any
        env.params.query.each do |key, value|
          case key
          when "run", "since"   then params[key] = JSON::Any.new(value)
          when "minId", "maxId" then params[key] = JSON::Any.new(value.to_i64? || raise Edit::Invalid.new(key, "number expected"))
          end
        end
        repair.quality(params).to_json
      end
    end

    post "/api/import/repair/accept" do |env|
      write_errors(env) do
        next fail(env, 404, {error: "backlog import is off"}) unless repair
        env.response.status_code = 202
        repair.accept(repair_ids(json_body(env))).to_json
      end
    end

    post "/api/import/repair/reject" do |env|
      write_errors(env) do
        next fail(env, 404, {error: "backlog import is off"}) unless repair
        {rejected: repair.reject(repair_ids(json_body(env)))}.to_json
      end
    end
  end
end
