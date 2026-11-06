require "db"
require "json"
require "./backlog"
require "./backlog_jobs"
require "./meta_filename"
require "./meta_quality"
require "./metadata"
require "./writer"

module CalibreHub
  # Repairs the metadata of books by the rule flow (Meta::Flow): the ISBN in
  # the book first, then its metadata, its file name last. For books the
  # backlog import added from a plain file before it read file names itself
  # (Meta::FileName), calibre took
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
  # the metadata change log (with its source and level), revertible there;
  # the repaired books get a metadata run. Every plan keeps per book how sure
  # it is (MetaLog#decide): the quality report shows the bands.
  #
  # The proposals are one list with two doors: the Prüfliste and the
  # Eingang's filter „Schon in der Bibliothek“ (Intake#library_list) both read
  # import_repairs, so a decision in one is gone from the other. A proposal
  # waiting for its accept job is out of the Eingang (decision), a skipped
  # one is not asked again there (skipped). An accept that fails stays and
  # says why (detail); one that found a field changed is failed, only a new
  # plan helps there.
  class ImportRepair < Jobs
    # automatic changes the repair builds on (not a person's edits)
    AUTO = Set{"rules", "model", "authors"}
    # the import runs and books the quality report shows
    QUALITY_RUNS   =  5
    QUALITY_SAMPLE = 20
    # books a sample check picks from a band
    SAMPLE_SIZE = 30
    # the fields a person's edit shows in the event log, as the proposals
    # name them
    HAND_FIELDS = {"title" => "title", "authors" => "authors", "authorSort" => "authorSort", "publisher" => "publisher",
                   "pubdate" => "pubdate", "series" => "series", "seriesIndex" => "seriesIndex"}
    # what a backlog import writes right after adding a book isn't an edit
    IMPORT_WINDOW = 10.minutes

    record Proposed, field : String, old : JSON::Any, new : JSON::Any, source : String = "rules" do
      include JSON::Serializable
    end

    # a row of import_repairs
    record Proposal, book_id : Int64, file : String, decided : String?, changes : Array(Proposed), status : String,
      detail : String?, at : Int64, confidence : Int32?, level : Int32?, source : String?, title_confidence : Int32?,
      authors_confidence : Int32?, notes : Array(Meta::Flow::Note), skipped : Bool

    getter log : MetaLog

    # the metadata runs after a repair (when the cleanup is on)
    property metadata : MetadataJobs?
    # the same at low priority, for a recheck
    property quiet_reader : Proc(Book, String?, Meta::FileMeta::Info?)?
    # decides unclear names (Metadata#decider)
    property decider : Meta::FileName::Decider?
    # asks the catalogs about readings without an author (Metadata#checker)
    property checker : Meta::FileName::Checker?
    # reads a book's file for the rule flow (Metadata#flow_info)
    property reader : Proc(Book, String?, Meta::FileMeta::Info?)?
    # asks the catalogs for an ISBN (Metadata#isbn_lookup)
    property by_isbn : Meta::Flow::Lookup?
    # the books with an ISBN (Metadata#owners)
    property owners : Meta::Flow::Owners?

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
      columns = [] of String
      db.query_each("pragma table_info(import_repairs)") { |rs| rs.read(Int32); columns << rs.read(String); rs.read(String, Int32, String?, Int32) }
      {"confidence" => "integer", "level" => "integer", "source" => "text", "title_confidence" => "integer",
       "authors_confidence" => "integer", "notes" => "text", "skipped" => "integer not null default 0",
       "decision" => "text"}.each do |c, type|
        db.exec "alter table import_repairs add column #{c} #{type}" unless columns.includes?(c)
      end
      # the books a recheck looked at, whatever came of it
      db.exec "create table if not exists import_rechecks (book_id integer primary key, at integer not null)"
      super(db, calibre, writer, nil, "import_repair_jobs")
      @hints = {} of String => Symbol?
    end

    # book id -> the file calibre read it from (the unit's primary format),
    # for books an import added from plain files. params: since (time the
    # file was imported), minId, maxId. folders: also the books of calibre
    # folders, which a plan leaves to their metadata.opf
    def files(params : Hash(String, JSON::Any), folders = false) : Hash(Int64, String)
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
        next if !folders && paths.any? { |p| Backlog.calibre_name?(File.dirname(p)) }
        result[id] = paths.min_by { |p| Backlog::FORMATS.index(File.extname(p).lchop('.').upcase) || Backlog::FORMATS.size }
      end
      result
    end

    # Queues a plan of the books (not those accepted or rejected before):
    # those an import added from a plain file and the suspicious ones, with
    # library: true every book, a dry run over the whole library. apply:
    # accept the proposals right away that may be accepted in bulk
    def submit_repair(params : Hash(String, JSON::Any), dry_run : Bool) : JSON::Any
      library = params.delete("library").try(&.as_bool?) || false
      done = Set(Int64).new
      @db.query_each("select book_id from import_repairs where status in ('applied', 'rejected')") { |rs| done << rs.read(Int64) }
      # an import's row outlives a book moved to the trash
      known = @calibre.list("", Calibre::DETAIL_FIELDS).map(&.id).to_set
      files = files(params).select { |id, _| known.includes?(id) && !done.includes?(id) }
      others = portion(params).select { |b| !done.includes?(b.id) && !files.has_key?(b.id) && (library || !Meta::Quality.reasons(b).empty?) }.map(&.id)
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
      decided = @log.decisions
      bands = Meta::Confidence::BANDS.to_h { |b| {b, 0} }
      bands["none"] = 0
      levels = {"1" => 0, "2" => 0, "3" => 0}
      books.each do |b|
        d = decided[b.id]?
        bands[d ? Meta::Confidence.band(d.confidence) : "none"] += 1
        levels[d.level.to_s] += 1 if d
      end
      JSON.parse({total: books.size, suspect: suspects.size, reasons: counts, runs: runs, books: sample,
                  bands: bands, levels: levels, isbn: isbn_report(books, decided), conflicts: conflicts(books, decided),
                  samples: @log.samples}.to_json)
    end

    # How many books have an ISBN and where it came from: the rule flow's
    # source, else the change log's, else it was there (calibre)
    private def isbn_report(books : Array(Book), decided : Hash(Int64, MetaLog::Decided))
      logged = @log.logged_isbn_sources
      sources = Hash(String, Int32).new(0)
      with_isbn = 0
      books.each do |b|
        isbn = b.identifiers["isbn"]?.try { |i| Meta::Isbn.normalize(i) } || next
        with_isbn += 1
        d = decided[b.id]?
        source = d.try { |x| x.isbn_source if x.isbn == isbn } || logged[b.id]? || Meta::Flow::SOURCE_CALIBRE
        sources[source] += 1
      end
      {with: with_isbn, without: books.size - with_isbn, sources: sources}
    end

    # The same ISBN on two books, and what the flow found against a book's ISBN
    private def conflicts(books : Array(Book), decided : Hash(Int64, MetaLog::Decided))
      by_isbn = books.group_by { |b| b.identifiers["isbn"]?.try { |i| Meta::Isbn.normalize(i) } }
      duplicates = by_isbn.compact_map { |isbn, list| {isbn: isbn, books: list.map(&.id)} if isbn && list.size >= 2 }
      noted = books.compact_map { |b| decided[b.id]?.try { |d| {id: b.id, title: b.title, notes: d.notes} unless d.notes.empty? } }
      {duplicates: duplicates.first(QUALITY_SAMPLE), duplicateCount: duplicates.size,
       noted: noted.first(QUALITY_SAMPLE), notedCount: noted.size}
    end

    # A random sample of a band to check by hand
    def sample(band : String, size = SAMPLE_SIZE) : JSON::Any
      raise Edit::Invalid.new("band", "bulk, review or unsure expected") unless Meta::Confidence::BANDS.includes?(band)
      ids = @log.decisions.values.select { |d| Meta::Confidence.band(d.confidence) == band }.shuffle.first(size)
      books = @calibre.books(ids.map(&.book_id))
      JSON.parse({band: band, books: ids.compact_map do |d|
        b = books.find { |x| x.id == d.book_id } || next
        {id: b.id, title: b.title, authors: b.authors, confidence: d.confidence, level: d.level, source: d.source}
      end}.to_json)
    end

    # The measured hit rate of a band
    def add_sample(band : String, checked : Int32, correct : Int32) : MetaLog::Sample
      raise Edit::Invalid.new("band", "bulk, review or unsure expected") unless Meta::Confidence::BANDS.includes?(band)
      raise Edit::Invalid.new("checked", "positive number expected") unless checked > 0
      raise Edit::Invalid.new("correct", "0 to checked expected") unless 0 <= correct <= checked
      @log.add_sample(band, checked, correct)
    end

    # Applies the proposals of these books. nil: all open ones that may be
    # written without looking at them one by one: not below the threshold.
    # band: the open ones of that band ("bulk"), the only band for that.
    def accept(ids : Array(Int64)?, band : String? = nil) : JSON::Any
      raise Edit::Invalid.new("band", "only bulk can be accepted as a band") unless band.nil? || band == "bulk"
      open = proposals("pending")
      books = if band
                open.select { |p| p.confidence.try { |c| Meta::Confidence.band(c) } == band }.map(&.book_id)
              elsif ids
                wanted = open.map(&.book_id).to_set
                ids.select { |id| wanted.includes?(id) }
              else
                open.select { |p| p.confidence.nil? || p.confidence.not_nil! >= Meta::Confidence::REVIEW }.map(&.book_id)
              end
      job = enqueue(books, {"mode" => JSON::Any.new("apply")})
      books.each_slice(500) do |slice|
        @db.exec "update import_repairs set decision = ?, detail = null where status = 'pending' and book_id in (#{slice.join(",")})", job.id
      end
      JSON.parse({books: books.size, job: job}.to_json)
    end

    # the accept job ended without these: open again
    def release
      @db.exec "update import_repairs set decision = null where decision is not null and " \
               "decision not in (select id from import_repair_jobs where status = 'running')"
    end

    # Rejects the proposals of these books (nil: all open ones), also one
    # that failed; a later plan leaves them out
    def reject(ids : Array(Int64)?) : Int64
      now = Time.utc.to_unix
      list = ids || proposals("pending").map(&.book_id)
      list.sum(0_i64) do |id|
        n = @db.exec("update import_repairs set status = 'rejected', decision = null, at = ? where book_id = ? and status in ('pending', 'failed')", now, id).rows_affected
        @log.decided_status(id, "rejected") if n > 0
        n
      end
    end

    PROPOSAL = "book_id, file, decided, changes, status, detail, at, confidence, level, source, title_confidence, authors_confidence, notes, skipped"

    def proposals(status : String? = nil) : Array(Proposal)
      list = [] of Proposal
      sql = "select #{PROPOSAL} from import_repairs"
      args = [] of DB::Any
      status.try { |s| sql += " where status = ?"; args << s }
      @db.query_each(sql + " order by book_id", args: args) { |rs| list << read_proposal(rs) }
      list
    end

    # by a condition on import_repairs, the book's order
    def proposals(where : String, args : Array(DB::Any), limit = -1) : Array(Proposal)
      list = [] of Proposal
      @db.query_each("select #{PROPOSAL} from import_repairs where #{where} order by book_id limit #{limit}", args: args) { |rs| list << read_proposal(rs) }
      list
    end

    # not asked again in the Eingang until taken back
    def skip(ids : Array(Int64), on : Bool)
      ids.each_slice(500) { |slice| @db.exec "update import_repairs set skipped = ? where book_id in (#{slice.join(",")})", on ? 1 : 0 }
    end

    private def proposal(id : Int64, status : String) : Proposal?
      @db.query_one?("select #{PROPOSAL} from import_repairs where book_id = ? and status = ?", id, status) { |rs| read_proposal(rs) }
    end

    private def read_proposal(rs) : Proposal
      id, file, decided, changes, st, detail, at, confidence, level, source, title, authors, notes =
        rs.read(Int64, String, String?, String, String, String?, Int64, Int32?, Int32?, String?, Int32?, Int32?, String?)
      skipped = rs.read(Int64)
      Proposal.new(id, file, decided, Array(Proposed).from_json(changes), st, detail, at, confidence, level, source, title, authors,
        notes ? Array(Meta::Flow::Note).from_json(notes) : [] of Meta::Flow::Note, skipped == 1)
    end

    # The open proposals with their books for the review, counts per status
    def review : JSON::Any
      counts = Hash(String, Int64).new(0_i64)
      @db.query_each("select status, count(*) from import_repairs group by status") { |rs| counts[rs.read(String)] = rs.read(Int64) }
      open = proposals("pending")
      books = @calibre.books(open.map(&.book_id))
      entries = open.map do |p|
        {bookId: p.book_id, file: p.file, decided: p.decided, status: p.status, at: Time.unix(p.at).to_rfc3339,
         confidence: p.confidence, band: p.confidence.try { |c| Meta::Confidence.band(c) }, level: p.level, source: p.source,
         titleConfidence: p.title_confidence, authorsConfidence: p.authors_confidence, notes: p.notes,
         changes: p.changes.map { |c| {field: c.field, old: c.old, new: c.new} }}
      end
      job = last.try(&.[0])
      # a plan rewrites the proposals, an accept job only works them off
      planning = !!job.try { |j| j.status == "running" && j.changes["mode"]?.try(&.as_s?) == "plan" }
      JSON.parse({entries: entries, books: books, counts: counts, job: job, planning: planning, unsureTag: Meta.unsure_tag}.to_json)
    end

    # The rule flow on one book. path: the file an import read
    def decide(book : Book, path : String?, baseline : JSON::Any?, reader = @reader) : Meta::Flow::Decision?
      hand = hand_fields(book.id)
      log = @log.active(book.id).reverse
      imported = imported_proc(book, path, baseline, log, hand)
      input = Meta::Flow::Input.new(book, imported, path.try { |p| File.basename(p) }, path.try { |p| hint(File.dirname(p)) })
      input.info = reader.try(&.call(book, path))
      input.by_isbn = @by_isbn
      input.decider = @decider
      input.checker = @checker
      input.owners = @owners
      input.hand = hand
      Meta::Flow.decide(input)
    end

    private def imported_proc(book : Book, path : String?, baseline : JSON::Any?, log : Array(MetaLog::Entry), hand : Set(String)) : Proc(String, JSON::Any?)
      ->(field : String) { hand.includes?(field) ? nil : ImportRepair.automatic_value(book, path, field, baseline, log) }
    end

    # imported_value, or the value now when no hand and no catalog wrote it:
    # what the import itself wrote after adding the book ("Vol 17" made
    # "Grzimek's …: Vol 17") is in neither the baseline nor the change log.
    # The caller left out the fields edited by hand. No baseline: no way to
    # tell, the value stays nobody's to change.
    def self.automatic_value(book : Book, path : String?, field : String, baseline : JSON::Any?, log : Array(MetaLog::Entry)) : JSON::Any?
      value = imported_value(book, path, field, baseline, log)
      return value if value || baseline.nil?
      log.all? { |e| e.field != field || AUTO.includes?(e.source) } ? Meta::Merge.value(book, field) : nil
    end

    # The fields of the book that were edited by hand: the event log has a
    # change that neither the cleanup's log knows nor an import made right
    # after adding the book
    def hand_fields(id : Int64) : Set(String)
      added = nil.as(Int64?)
      changed = [] of {Int64, JSON::Any}
      @db.query_each("select type, payload, created_at from events where book_id = ? and type in ('added', 'changed') order by id", id) do |rs|
        type, payload, at = rs.read(String, String, Int64)
        if type == "added"
          added ||= at
        else
          changed << {at, JSON.parse(payload)}
        end
      end
      ImportRepair.hand_fields(added, changed, @log.list(id, limit: 10_000))
    end

    def self.hand_fields(added : Int64?, changed : Array({Int64, JSON::Any}), log : Array(MetaLog::Entry)) : Set(String)
      hand = Set(String).new
      changed.each do |at, event|
        next if added && at - added <= IMPORT_WINDOW.total_seconds
        changes = event["changes"]?.try(&.as_h?) || next
        changes.each do |key, pair|
          news = pair.as_a?.try(&.[1]?)
          if key == "identifiers"
            old = pair.as_a?.try(&.[0]?).try(&.as_h?.try(&.["isbn"]?)).try(&.as_s?)
            now = news.try(&.as_h?.try(&.["isbn"]?)).try(&.as_s?)
            next if old == now
            hand << "isbn" unless log.any? { |e| e.field == "isbn" && e.new.as_s? == now }
            next
          end
          field = HAND_FIELDS[key]? || next
          next if news.nil?
          known = log.any? { |e| e.field == field && (same?(field, e.new, news) || (e.reverted_at && same?(field, e.old, news))) }
          hand << field unless known
        end
      end
      hand
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
      imported = ->(field : String) { ImportRepair.imported_value(book, path, field, baseline, log) }
      Meta::FileName.decide(book, name, hint, imported, decider, checker) || {[] of Meta::Change, Meta::FileName::NAME}
    end

    # The field's value at the import, nil when someone changed it; no
    # path: a book without a file an import read, no baseline (books older
    # than the events): a value that looks wrong counts as nobody's edit
    def self.imported_value(book : Book, path : String?, field : String, baseline : JSON::Any?, log : Array(MetaLog::Entry)) : JSON::Any?
      current = Meta::Merge.value(book, field)
      return ImportRepair.origin(field, current, [baseline.try(&.[field]?) || current], log) unless path
      cg_title, cg_authors = Meta::FileName.calibre(File.basename(path))
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
      ImportRepair.origin(field, current, origins, log)
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

    # a calibre folder, gone by now or not, says it by its name
    private def hint(dir : String) : Symbol?
      return Meta::FileName::CALIBRE_NAME if Backlog.calibre_name?(dir)
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
        # gone since the plan started: nothing to plan
        book = @calibre.book(id) || return
        baseline = baselines([id])[id]?
        decision = decide(book, path, baseline) || return
        store(id, path || "", decision, job.id)
        # without a look at them: only what may be accepted in bulk
        if job.changes["apply"]?.try(&.as_bool?) && decision.band == "bulk"
          apply_book(id, job.id)
        end
      when "apply"
        begin
          apply_book(id, job.id)
        rescue ex : Jobs::Abort
          raise ex
        rescue ex
          # a proposal that stays pending says why it came back
          @db.exec "update import_repairs set decision = null, detail = ? where book_id = ? and status = 'pending'",
            ex.message || ex.class.name, id
          raise ex
        end
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

    # The plan of a book, unless it was accepted or rejected meanwhile. A
    # book without changes needs no review, unless a conflict is noted.
    private def store(id : Int64, path : String, d : Meta::Flow::Decision, job_id : String?)
      return if @db.query_one?("select 1 from import_repairs where book_id = ? and status in ('applied', 'rejected')", id, as: Int64)
      nothing = d.changes.empty? && d.notes.empty?
      @log.decide(id, d, nothing ? "written" : "planned", job_id)
      if nothing
        @db.exec "delete from import_repairs where book_id = ?", id
        return
      end
      proposed = d.changes.map { |c| Proposed.new(c.field, c.old, c.new, c.source) }
      @db.exec "insert or replace into import_repairs (book_id, file, decided, changes, status, detail, at, confidence, level, source, title_confidence, authors_confidence, notes) values (?, ?, ?, ?, 'pending', null, ?, ?, ?, ?, ?, ?, ?)",
        id, path, d.how, proposed.to_json, Time.utc.to_unix, d.confidence, d.level, d.source, d.title, d.authors, d.notes.to_json
    end

    # The books a recheck has to look at, with the file an import read:
    # those accepted before the rules of today (a plan leaves them out), those
    # whose accept failed, and the books of an import run (the last one
    # without a run), once each. Nothing that is open or was rejected, nothing
    # Arthur took in the Eingang, no book gone from the library.
    def recheck_list(run : String? = nil) : {Array(Int64), Hash(Int64, String)}
      rows = {} of Int64 => String
      @db.query_each("select book_id, status from import_repairs") { |rs| rows[rs.read(Int64)] = rs.read(String) }
      ids = rows.select { |_, s| s.in?("applied", "failed") }.keys.to_set
      (run || last_run).try { |r| ids.concat(run_books(r).reject { |id| rows.has_key?(id) }) }
      @db.query_each("select book_id from import_rechecks") { |rs| ids.delete(rs.read(Int64)) }
      known = @calibre.list("", Calibre::DETAIL_FIELDS).map(&.id).to_set
      decided = @log.decisions
      list = ids.select { |id| known.includes?(id) && decided[id]?.try(&.status) != MetaLog::ACCEPTED }.to_a.sort!
      paths = files({} of String => JSON::Any, folders: true)
      {list, paths.select { |id, _| ids.includes?(id) }}
    end

    # the newest run of the import proper, the Eingang's decisions aren't one
    private def last_run : String?
      @db.query_one?("select run_id from import_files where status = 'imported' and run_id != ? order by at desc limit 1", Intake::RUN, as: String)
    end

    # A book planned again. The flow is the plan's, so a field edited by hand
    # stays and what a catalog wrote gives way to an ISBN only. A plan that
    # would write nothing leaves everything as it was: no proposal, the book
    # keeps its decision. Decided meanwhile: left alone.
    def recheck(id : Int64, path : String?)
      now = @db.query_one?("select status from import_repairs where book_id = ?", id, as: String)
      unless now.in?("pending", "rejected") || @log.decided(id).try(&.status) == MetaLog::ACCEPTED
        book = @calibre.book(id) || return
        d = decide(book, path, baselines([id])[id]?, @quiet_reader || @reader)
        replace(id, path || "", d) if d
      end
      @db.exec "insert or replace into import_rechecks (book_id, at) values (?, ?)", id, Time.utc.to_unix
    end

    private def replace(id : Int64, path : String, d : Meta::Flow::Decision)
      changes = d.changes.reject { |c| c.field == Meta::FileName::CANDIDATE || Meta::Merge.same?(c.field, c.old, c.new) }
      # a failed accept had nothing to say any more
      @db.exec "delete from import_repairs where book_id = ? and status = 'failed'", id if changes.empty?
      return if changes.empty?
      @db.exec "delete from import_repairs where book_id = ?", id
      store(id, path, d, nil)
    end

    # A decision of the import with a conflict goes to the review
    def flagged(id : Int64, path : String, d : Meta::Flow::Decision)
      store(id, path, d.copy_with(changes: [] of Meta::Change), nil)
      @log.decided_status(id, "written")
    end

    # A conflict the metadata run found goes to the review
    def flag(id : Int64, note : Meta::Flow::Note)
      return if @db.query_one?("select 1 from import_repairs where book_id = ?", id, as: Int64)
      @db.exec "insert into import_repairs (book_id, file, decided, changes, status, detail, at, confidence, notes) values (?, '', 'rules', '[]', 'pending', null, ?, ?, ?)",
        id, Time.utc.to_unix, Meta::Confidence::CONFLICT, [note].to_json
    end

    # The stored proposal, if the book still has the values the plan saw
    private def apply_book(id : Int64, job_id : String)
      row = proposal(id, "pending") || return
      book = @calibre.book(id) || raise Writer::NotFound.new
      changes = row.changes.reject { |c| c.field == Meta::FileName::CANDIDATE }
      if changed = changes.find { |c| !ImportRepair.same?(c.field, c.old, Meta::Merge.value(book, c.field)) }
        @db.exec "update import_repairs set status = 'failed', decision = null, detail = ?, at = ? where book_id = ?",
          "#{changed.field} changed since the plan", Time.utc.to_unix, id
        # the next recheck plans it again
        @db.exec "delete from import_rechecks where book_id = ?", id
        raise Exception.new("#{changed.field} changed since the plan, plan again")
      end
      write(book, changes.map { |c| Meta::Change.new(c.field, c.old, c.new, c.source) }, job_id, row.level) unless changes.empty?
      @db.exec "update import_repairs set status = 'applied', decision = null, at = ? where book_id = ?", Time.utc.to_unix, id
      @log.decided_status(id, "written")
    end

    # One PATCH with lastModified (a book changed meanwhile is a Conflict,
    # that book fails), the tag of the cleanup, each field in the log
    private def write(book : Book, changes : Array(Meta::Change), job_id : String, level : Int32?)
      body = Meta::Merge.patch(book, changes.to_h { |c| {c.field, c.new} })
      body["lastModified"] = JSON::Any.new(book.version)
      Meta::Merge.tags(body, "addTags", [Meta::TAG])
      updated = @writer.update(book.id, body)
      changes.each do |c|
        now = Meta::Merge.value(updated, c.field)
        next if Meta::Merge.same?(c.field, c.old, now)
        @log.add(book.id, c.field, c.old, now, c.source, job_id, level)
      end
    end
  end

  # Plans the books no plan got to (ImportRepair#recheck_list), in a queue of
  # its own: a run of hours keeps the Prüfliste's and the Eingang's accepts
  # from waiting, and the analysis, which waits for repairs, from waiting for
  # this. It goes like the analysis, one book after the other with a pause and
  # reading at low priority, and it gives way to it: while the analysis or an
  # import works it stands still. Nothing here writes to a book.
  class RepairRecheck < Jobs
    PAUSE = 500.milliseconds
    WAIT  = 30.seconds

    # the analysis or an import works
    property busy : Proc(Bool) = -> { false }

    # standing still for the analysis
    getter? waiting = false

    def initialize(db : DB::Database, calibre : Calibre, writer : Writer, @repair : ImportRepair, @pause = PAUSE, @wait = WAIT)
      super(db, calibre, writer, nil, "import_recheck_jobs")
    end

    # the job that runs, or a new one for what is left to check
    def queue(run : String? = nil) : Job
      running = last.try(&.[0]).try { |j| j if j.status == "running" }
      return running if running
      ids, files = @repair.recheck_list(run)
      enqueue(ids, {"files" => JSON.parse(files.transform_keys(&.to_s).to_json)})
    end

    protected def apply(job : Job, index : Int32, id : Int64, resumed : Bool)
      while @busy.call
        @waiting = true
        sleep @wait
      end
      @waiting = false
      @repair.recheck(id, job.changes["files"]?.try(&.[id.to_s]?).try(&.as_s?))
      sleep @pause
    end
  end

  private def self.repair_ids(body : Hash(String, JSON::Any)) : Array(Int64)?
    return nil if body["all"]?.try(&.as_bool?) || body["band"]?
    list = body["bookIds"]?.try(&.as_a?) || raise Edit::Invalid.new("bookIds", "list of book ids or all: true expected")
    list.map { |v| v.as_i64? || raise Edit::Invalid.new("bookIds", "numbers expected") }
  end

  # The repair: POST plans (a job), GET lists the open proposals, accept
  # and reject them (bookIds or all)
  def self.import_repair_routes(repair : ImportRepair?, recheck : RepairRecheck? = nil)
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

    # {run?}: the books no plan got to, see ImportRepair#recheck_list
    post "/api/import/repair/recheck" do |env|
      write_errors(env) do
        next fail(env, 404, {error: "backlog import is off"}) unless recheck
        job = recheck.queue(json_body(env)["run"]?.try(&.as_s?).presence)
        env.response.status_code = 202
        {books: job.total, job: job}.to_json
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

    # a sample check of a band: GET picks books to check, POST records how
    # many were right
    get "/api/import/quality/sample" do |env|
      write_errors(env) do
        next fail(env, 404, {error: "backlog import is off"}) unless repair
        repair.sample(env.params.query["band"]? || "").to_json
      end
    end

    post "/api/import/quality/sample" do |env|
      write_errors(env) do
        next fail(env, 404, {error: "backlog import is off"}) unless repair
        body = json_body(env, required: true)
        number = ->(key : String) { body[key]?.try(&.as_i?) || raise Edit::Invalid.new(key, "number expected") }
        env.response.status_code = 201
        repair.add_sample(body["band"]?.try(&.as_s?) || "", number.call("checked"), number.call("correct")).to_json
      end
    end

    post "/api/import/repair/accept" do |env|
      write_errors(env) do
        next fail(env, 404, {error: "backlog import is off"}) unless repair
        env.response.status_code = 202
        body = json_body(env)
        repair.accept(repair_ids(body), body["band"]?.try(&.as_s?)).to_json
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
