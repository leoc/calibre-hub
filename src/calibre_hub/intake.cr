require "db"
require "json"
require "kemal"
require "./backlog"
require "./backlog_jobs"
require "./import_repair"
require "./inbox"
require "./meta_flow"
require "./sanitizer"

module CalibreHub
  # The „Eingang“: every book file goes through a list before it reaches the
  # library, whichever way it came (origin: the backlog, the inbox, an upload).
  # New files in the import roots are found without a button and analysed one
  # after another, at low priority, while no repair runs; the inbox and uploads
  # have a fiber of their own (run_fast), so a new book doesn't wait behind a
  # backlog of thousands or the analysis being off. The same units as an
  # import (Backlog::Scanner), the same
  # check against the library (Backlog::Index) and the same decision
  # (Meta::Flow), only from the file instead of from a book calibre added.
  # Nothing here has a way to write: calibre-server is only asked for its
  # list, the result goes to the state DB (intake_entries, with everything
  # found per file in intake_candidates) and a file changes hands only by a
  # decision (IntakeJobs: Arthur's, the threshold's when it is on), or as an
  # exact copy of a library's file: of the backlog that goes to the trash
  # folder by itself, of the inbox and uploads to their _duplicates, byte for
  # byte the same or it stays in the list.
  #
  # A file analysed once stays that way as long as path, size and mtime are
  # the same, also over a restart; a file gone or handled by an import leaves
  # the list. A calibre folder's metadata.opf is the file's metadata that has
  # to prove itself like a PDF's, not what the book is called.
  #
  # POST /api/intake/analysis stops the analysis after the file at hand and
  # starts it again (hub eingang analysis off|on), without a deploy and over a
  # restart: the flag is in the state DB.
  class Intake
    # between two looks at the roots, after the hub started
    INTERVAL = 5.minutes
    START    = 1.minute
    # a file younger than this may still be copied
    STABLE = 2.minutes
    # between two books, so a run of hours stays in the background
    PAUSE = 500.milliseconds
    # between two looks while a repair runs
    WAIT = 30.seconds
    # entries per request at most
    MAX_LIMIT = 500
    # ids per statement
    STORE_BATCH = 500
    # meta: the analysis is switched off
    OFF = "intake_off"
    # meta: from this confidence on entries are accepted after the analysis,
    # the backlog's under this key, the others' with their origin behind it
    AUTO     = "intake_auto"
    AUTO_MIN =  60
    AUTO_MAX = 100
    # the inbox and uploads until someone changes it; the backlog: off
    AUTO_DEFAULT = 90
    # between two looks at the inbox and the uploads
    TICK = 30.seconds
    # where an entry comes from
    BACKLOG = "backlog"
    INBOX   = "inbox"
    UPLOAD  = "upload"
    ORIGINS = {BACKLOG, INBOX, UPLOAD}
    # what a decision's run_id is in import_files
    RUN = "intake"

    # what a Book needs of the flow's fields, as the list shows them
    FIELDS = %w(title authors publisher pubdate series seriesIndex isbn languages)
    # the surest first, what has no value last; a bulk goes the same way
    SURE  = "coalesce(confidence, -1)"
    ORDER = "#{SURE} desc, lower(path), path"

    # The metadata the hub proposes
    @[JSON::Serializable::Options(emit_nulls: true)]
    class Proposal
      include JSON::Serializable

      getter title : String
      getter authors : Array(String)
      getter publisher : String?
      getter pubdate : String?
      getter series : String?
      @[JSON::Field(key: "seriesIndex")]
      getter series_index : Float64?
      getter isbn : String?
      getter languages : Array(String)

      def initialize(@title, @authors, @publisher, @pubdate, @series, @series_index, @isbn, @languages)
      end
    end

    # One thing found about a file: where from, how sure, what it says
    record Candidate, source : String, confidence : Int32, fields : Meta::Record, url : String? = nil do
      include JSON::Serializable
    end

    # One field the analysis changed against what the file says
    record Changed, field : String, old : JSON::Any, new : JSON::Any, source : String do
      include JSON::Serializable
    end

    # a row of intake_entries
    record Entry, id : Int64, path : String, kind : String, files : Array(Backlog::BookFile), status : String,
      detail : String?, proposal : Proposal?, confidence : Int32?, title_confidence : Int32?, authors_confidence : Int32?,
      level : Int32?, source : String?, decided : String?, isbn_source : String?, notes : Array(Meta::Flow::Note),
      changes : Array(Changed), action : String, book_id : Int64?, match : String?, same_as : String?,
      add_formats : Array(String), cover : String?, at : Int64, skipped : Bool, error : String?, book_title : String?,
      decision : String?, origin : String, tags : Array(String), kategorie : String?, forced : Bool, same_book : Bool do
      def primary : Backlog::BookFile
        files.min_by { |f| Backlog::FORMATS.index(f.format) || Backlog::FORMATS.size }
      end

      def band : String?
        confidence.try { |c| Meta::Confidence.band(c) }
      end

      # the unit as an import sees it; a calibre folder's OPF as it is now
      def unit : Backlog::Unit
        return Backlog::Unit.new(kind, File.dirname(primary.path), files) unless kind == "calibre"
        cover = File.join(path, Backlog::COVER)
        Backlog::Unit.new(kind, path, files, File.file?(cover) ? cover : nil,
          Backlog::OpfMeta.parse(File.read(File.join(path, Backlog::OPF))))
      end

      # the file's folder below its root, nil in the root
      def folder(roots : Array(String)) : String?
        dir = File.dirname(primary.path)
        root = roots.select { |r| dir == r || dir.starts_with?(r.rstrip('/') + "/") }.max_by?(&.size)
        root ? dir.lchop(root).lchop('/').presence : dir
      end

      def to_api(roots : Array(String))
        {id: id, path: path, name: File.basename(primary.path), folder: origin == UPLOAD ? nil : folder(roots), kind: kind, origin: origin,
         files: files.map { |f| {path: f.path, format: f.format, size: f.size} },
         status: status, detail: detail, proposal: proposal, confidence: confidence, band: band,
         titleConfidence: title_confidence, authorsConfidence: authors_confidence, level: level, source: source,
         decided: decided, isbnSource: isbn_source, notes: notes, action: action, bookId: book_id, match: match,
         sameAs: same_as, addFormats: add_formats, cover: cover ? "/api/intake/#{id}/cover?v=#{at}" : nil,
         analysedAt: Time.unix(at).to_rfc3339, skipped: skipped, error: error, bookTitle: book_title, sameBook: same_book}
      end
    end

    COLUMNS = "id, path, kind, files, status, detail, proposal, confidence, title_confidence, authors_confidence, level, source, " \
              "decided, isbn_source, notes, changes, action, book_id, match, same_as, add_formats, cover, at, " \
              "skipped, error, book_title, decision, origin, tags, kategorie, forced, same_book"

    # What comes with a file besides the file: where from, the inbox's folders
    # or an upload's form, and that it is wanted whatever it looks like
    record Extra, origin : String = BACKLOG, tags : Array(String) = [] of String, kategorie : String? = nil, forced : Bool = false

    # reads a file for the rule flow (Metadata#read_flow, at low priority),
    # catalogs by ISBN (Metadata#isbn_lookup), an unclear name
    # (Metadata#decider), a reading without an author (Metadata#checker),
    # a title search (Metadata#search)
    property reader : Proc(String, String, Meta::FileMeta::Info?)?
    property by_isbn : Meta::Flow::Lookup?
    property decider : Meta::FileName::Decider?
    property checker : Meta::FileName::Checker?
    property search : Proc(Book, Meta::Guess, Array(Meta::Candidate))?
    # a repair runs: the backlog's analysis waits
    property busy : Proc(Bool)
    # the column an inbox's folders or an upload's category go to
    property category_column : String?
    # the file's cover at a path (FileMeta.cover), true when there is one
    property cover_reader : Proc(String, String, String, Bool) = ->(path : String, format : String, target : String) do
      Meta::FileMeta.cover(path, format, target, nice: true)
    end

    # idle, scanning, analysing, paused, off
    getter state = "idle"
    # the file being analysed
    getter current : String? = nil

    def self.migrate(db : DB::Database)
      db.exec "create table if not exists meta (key text primary key, value text)"
      db.exec <<-SQL
        create table if not exists intake_entries (
          id integer primary key autoincrement,
          path text not null unique,
          kind text not null,
          files text not null,
          status text not null,
          detail text,
          proposal text,
          confidence integer,
          title_confidence integer,
          authors_confidence integer,
          level integer,
          source text,
          decided text,
          isbn_source text,
          notes text not null default '[]',
          changes text not null default '[]',
          action text not null,
          book_id integer,
          match text,
          same_as text,
          add_formats text not null default '[]',
          cover text,
          at integer not null
        )
        SQL
      db.exec <<-SQL
        create table if not exists intake_candidates (
          entry_id integer not null,
          idx integer not null,
          source text not null,
          confidence integer not null,
          fields text not null,
          url text,
          primary key (entry_id, idx)
        )
        SQL
      columns = [] of String
      db.query_each("select name from pragma_table_info('intake_entries')") { |rs| columns << rs.read(String) }
      # the job the entry waits in: it left the list
      db.exec "alter table intake_entries add column decision text" unless columns.includes?("decision")
      # not asked again until taken back
      db.exec "alter table intake_entries add column skipped integer not null default 0" unless columns.includes?("skipped")
      # why the last decision came back
      db.exec "alter table intake_entries add column error text" unless columns.includes?("error")
      # the library's book it looks like, for the list
      db.exec "alter table intake_entries add column book_title text" unless columns.includes?("book_title")
      # backlog, inbox or upload
      db.exec "alter table intake_entries add column origin text not null default 'backlog'" unless columns.includes?("origin")
      # what the source says of it
      db.exec "alter table intake_entries add column tags text not null default '[]'" unless columns.includes?("tags")
      db.exec "alter table intake_entries add column kategorie text" unless columns.includes?("kategorie")
      # sent again on purpose: no duplicate
      db.exec "alter table intake_entries add column forced integer not null default 0" unless columns.includes?("forced")
      # a duplicate with the title and authors of its book (Dedup.same_book?)
      db.exec "alter table intake_entries add column same_book integer not null default 0" unless columns.includes?("same_book")
      # An upload outlives its entry, so whoever sent it can ask what came of
      # it. status: staged (with or without an entry), imported, formatAdded,
      # copy (byte for byte in the library), trashed, gone
      db.exec <<-SQL
        create table if not exists intake_uploads (
          id text primary key,
          file text not null unique,
          name text not null,
          tags text not null default '[]',
          kategorie text,
          forced integer not null default 0,
          by text not null,
          status text not null,
          book_id integer,
          at integer not null
        )
        SQL
    end

    # covers: where the pictures of plain files go, next to the state DB
    def initialize(@db : DB::Database, @calibre : Calibre, @imports : Importer, @library : String?,
                   @covers : String, @interval = INTERVAL, @stable = STABLE, @pause = PAUSE, @wait = WAIT,
                   @inbox : Inbox? = nil, @uploads : Inbox? = nil, @tick = TICK)
      Intake.migrate(@db)
      @peeks = File.join(File.dirname(@covers), "intake-peeks")
      @wake = Channel(Nil).new(1)
      # of the inbox and uploads: files left and the current one
      @fast_left = 0
      @fast_current = nil.as(String?)
      @busy = -> { false }
      # files of this pass left, the current one included
      @left = 0
      @decisions = nil.as(IntakeJobs?)
      @decisions = IntakeJobs.new(@db, @calibre, @imports.writer, @imports, self)
      release
    end

    # the queue of decisions
    def decisions : IntakeJobs
      @decisions.not_nil!
    end

    # Looks at the roots from now on, at the inbox and the uploads on their own
    def start(delay = START)
      spawn do
        sleep delay
        loop do
          begin
            run_once
          rescue ex
            # calibre-server down, usually: the next pass starts over
            STDERR.puts "intake failed: #{ex.message}"
          end
          sleep @interval
        end
      end
      spawn do
        loop do
          begin
            run_fast
          rescue ex
            STDERR.puts "intake failed: #{ex.message}"
          end
          select
          when @wake.receive
          when timeout(@tick)
          end
        end
      end
    end

    # every folder a file of the list can lie in
    def roots : Array(String)
      @imports.roots + [@inbox, @uploads].compact.map(&.dir)
    end

    # the sources there are here: an inbox only with its folder
    def origins_on : Array(String)
      list = [] of String
      list << BACKLOG unless @imports.roots.empty?
      list << INBOX if @inbox
      list << UPLOAD if @uploads
      list
    end

    private def box(origin : String) : Inbox?
      case origin
      when INBOX  then @inbox
      when UPLOAD then @uploads
      end
    end

    # One pass over what came in by the inbox and uploads. Nothing here waits
    # for the backlog's analysis, a repair or the analysis being off: a book
    # someone just sent is one file. Returns how many.
    def run_fast : Int32
      now = Time.local
      @inbox.try(&.cleanup(now))
      @uploads.try(&.cleanup(now))
      uploads = staged_uploads
      units = inbox_units(now)
      return 0 if uploads.empty? && units.empty?
      ix = Backlog::Index.load(@calibre, @library, @db)
      all.each { |e| remember(ix, e) if e.action == "add" && e.status == "analysed" }
      @fast_left = uploads.size + units.size
      uploads.each do |file, extra|
        fast(upload_unit(file), ix, extra) { settled_upload(file, "gone", nil) }
      end
      units.each do |u|
        # a changed file: the old entry leaves like any other, with its
        # candidates, cover and first pages; what a job has comes up afterwards
        old = entry_at(u.name)
        if old.try(&.decision)
          @fast_left -= 1
          next
        end
        old.try { |e| forget(e) }
        fast(u, ix, inbox_extra(u)) { }
      end
      uploads.size + units.size
    ensure
      @fast_left = 0
      @fast_current = nil
    end

    private def fast(unit : Backlog::Unit?, ix : Backlog::Index, extra : Extra, &)
      if unit
        @fast_current = File.basename(unit.primary.path)
        analyse(unit, ix, extra)
      else
        yield
      end
      @fast_left -= 1
    end

    # what is new in the inbox and may be taken in: settled, and movable once
    # it is decided. What is in the list is looked at again only when it
    # changed; what went into the library left the folder, so a file dropped
    # again is new.
    private def inbox_units(now : Time) : Array(Backlog::Unit)
      box = @inbox || return [] of Backlog::Unit
      known = Backlog::Known.new
      @db.query_each("select files from intake_entries where origin = ?", INBOX) do |rs|
        Array(Backlog::BookFile).from_json(rs.read(String)).each { |f| known[f.path] = {f.size, f.mtime, "analysed", nil} }
      end
      scanner = Backlog::Scanner.new([box.dir], known, inbox: true)
      scanner.run
      box.fail_broken(scanner.skipped, now)
      scanner.units.select { |u| u.files.all? { |f| box.settled?(f.mtime, now) } && u.files.all? { |f| box.movable?(f.path) } }
    end

    # the folders are the category and the tags; a calibre folder's aren't
    private def inbox_extra(u : Backlog::Unit) : Extra
      return Extra.new(INBOX) if u.kind == "calibre"
      category, tags = Inbox.classify(@inbox.not_nil!.rel(u.primary.path))
      Extra.new(INBOX, tags, category)
    end

    private def upload_unit(file : String) : Backlog::Unit?
      info = File.info?(file) || return nil
      f = Backlog::BookFile.new(file, File.extname(file).lchop('.').upcase, info.size, info.modification_time.to_unix)
      Backlog::Unit.new("file", File.dirname(file), [f])
    end

    # the uploads no analysis got to, also over a restart
    private def staged_uploads : Array({String, Extra})
      list = [] of {String, Extra}
      @db.query_each("select file, tags, kategorie, forced from intake_uploads where status = 'staged' and " \
                     "file not in (select path from intake_entries) order by at, id") do |rs|
        file, tags, kategorie, forced = rs.read(String, String, String?, Int64)
        list << {file, Extra.new(UPLOAD, Array(String).from_json(tags), kategorie, forced == 1)}
      end
      list
    end

    # An upload goes to the staging folder under its name, in a folder of its
    # own. Admins only (POST /api/books, like everything that writes): the
    # answer says it is in the Eingang, upload_state what came of it.
    def stage(u : Writer::Upload, by : String) : JSON::Any
      Writer.extension(u.filename)
      raise Edit::Invalid.new("kategorie", "no category column configured") if u.kategorie && !@category_column
      box = @uploads || raise Writer::Unsupported.new("uploads are off")
      id = Random::Secure.hex(8)
      file = File.join(box.dir, id, u.filename)
      Dir.mkdir_p(File.dirname(file))
      File.rename(u.file, file)
      File.chmod(file, 0o660)
      @db.exec "insert into intake_uploads (id, file, name, tags, kategorie, forced, by, status, at) values (?, ?, ?, ?, ?, ?, ?, 'staged', ?)",
        id, file, u.filename, u.tags.to_json, u.kategorie, u.force ? 1 : 0, by, Time.utc.to_unix
      puts "intake: upload #{u.filename} from #{by}"
      select
      when @wake.send(nil)
      else
      end
      upload_state(id).not_nil!
    end

    private def settled_upload(file : String, status : String, book : Int64?)
      @db.exec "update intake_uploads set status = ?, book_id = ? where file = ? and status = 'staged'", status, book, file
    end

    # What came of an upload, for whoever sent it. status: checking (the
    # analysis or a decision is at it), waiting (in the Eingang, below the
    # threshold), duplicate (in the Eingang, looks like a book of the library),
    # imported, formatAdded, copy (the same file is in the library, it went to
    # _duplicates), trashed, gone.
    def upload_state(id : String) : JSON::Any?
      row = @db.query_one?("select file, name, status, book_id from intake_uploads where id = ?", id, as: {String, String, String, Int64?}) || return nil
      file, name, status, book = row
      e = entry_at(file)
      h = {} of String => JSON::Any
      h["id"] = JSON::Any.new(id)
      h["name"] = JSON::Any.new(name)
      h["status"] = JSON::Any.new(status)
      case status
      when "staged"
        h["status"] = JSON::Any.new("checking")
        waiting_state(h, e) if e && e.decision.nil?
      when "imported", "formatAdded"
        h["book"] = JSON.parse(book.try { |b| @calibre.book(b) }.to_json)
        similar = status == "imported" ? book.try { |b| similar_books(b) } : nil
        h["possibleDuplicates"] = JSON.parse(similar.to_json) if similar
      when "copy"
        h["duplicates"] = JSON.parse(book_list(book).to_json)
      end
      JSON::Any.new(h)
    end

    private def entry_at(path : String) : Entry?
      @db.query_one?("select #{COLUMNS} from intake_entries where path = ?", path) { |rs| read_entry(rs) }
    end

    private def waiting_state(h : Hash(String, JSON::Any), e : Entry)
      h["entryId"] = JSON::Any.new(e.id)
      h["error"] = JSON::Any.new(e.error || e.detail)
      if e.action != "add" && !e.forced
        h["status"] = JSON::Any.new("duplicate")
        h["duplicates"] = JSON.parse(book_list(e.book_id).to_json)
        h["titles"] = JSON.parse([e.same_as.try { |s| File.basename(s) }].compact.to_json)
      else
        h["status"] = JSON::Any.new("waiting")
        h["confidence"] = JSON::Any.new(e.confidence.try(&.to_i64))
        h["threshold"] = JSON::Any.new(threshold(UPLOAD).try(&.to_i64))
      end
    end

    private def book_list(id : Int64?) : Array(Book)
      id ? @calibre.books([id], Calibre::DETAIL_FIELDS) : [] of Book
    end

    # the hub's own detection, beyond calibre's title and author check; the
    # book stands without the hint
    private def similar_books(id : Int64) : Array(Book)?
      @imports.writer.similar.try(&.call(id)).try { |l| l.empty? ? nil : l }
    rescue ex
      STDERR.puts "intake: duplicate check for ##{id} failed: #{ex.message}"
      nil
    end

    # One pass: the new files of the roots analysed. Returns how many.
    def run_once : Int32
      # the analysis may stand still for long, the list's numbers don't
      mark_same(Backlog::Index.load(@calibre, @library, @db)) if off? || @busy.call
      wait_idle
      @state = "scanning"
      ix = index
      sweep(ix)
      mark_same(ix)
      accept_above
      scanner = Backlog::Scanner.new(@imports.roots, @known)
      scanner.run
      now = Time.utc.to_unix
      units = scanner.units.select { |u| u.files.all? { |f| now - f.mtime >= @stable.total_seconds } }
      @left = units.size
      puts "intake: #{units.size} new books" unless units.empty?
      units.each do |u|
        ix = index if wait_idle
        @state = "analysing"
        @current = File.basename(u.primary.path)
        analyse(u, ix)
        @left -= 1
        sleep @pause
      end
      units.size
    ensure
      @state = "idle"
      @current = nil
      @left = 0
    end

    @known = Backlog::Known.new

    # true when it waited: the library may have changed
    private def wait_idle : Bool
      waited = false
      while off? || @busy.call
        waited = true
        @state = off? ? "off" : "paused"
        sleep @wait
      end
      waited
    end

    def off? : Bool
      !@db.query_one?("select 1 from meta where key = ?", OFF, as: Int64).nil?
    end

    # on: the next file goes on, within WAIT; off: after the file at hand
    def analysis=(on : Bool)
      if on
        @db.exec "delete from meta where key = ?", OFF
      else
        @db.exec "insert or replace into meta (key, value) values (?, '1')", OFF
      end
    end

    # The library and the books the list would add already, so the same book
    # twice in the roots is marked; what changed or left since goes first
    private def index : Backlog::Index
      ix = Backlog::Index.load(@calibre, @library, @db)
      release
      handled = @imports.known(ix)
      @known = settle(handled)
      all.each { |e| remember(ix, e) if e.action == "add" && e.status == "analysed" }
      ix
    end

    # The files not to look at again: what imports handled and what is
    # analysed and unchanged. An entry whose files changed, went or were
    # handled by an import leaves the list.
    private def settle(handled : Backlog::Known) : Backlog::Known
      known = handled.dup
      all.each do |e|
        same = unchanged?(e)
        gone = e.origin == BACKLOG && e.files.all? { |f| (k = handled[f.path]?) && k[0] == f.size && k[1] == f.mtime }
        if same && !gone
          e.files.each { |f| known[f.path] = {f.size, f.mtime, "analysed", nil} }
        else
          forget(e)
        end
      end
      known
    end

    def unchanged?(e : Entry) : Bool
      e.files.all? do |f|
        info = File.info?(f.path)
        info && info.size == f.size && info.modification_time.to_unix == f.mtime
      end
    end

    # What the library knows by now about entries analysed earlier: an exact
    # copy goes, the others keep the title of the book they look like
    private def sweep(ix : Backlog::Index)
      all.each do |e|
        next if e.decision || e.forced
        if (u = unit_of(e)) && trash_copy(u, ix, e.origin)
          forget(e)
        elsif (title = e.book_id.try { |b| ix.title(b) }) && title != e.book_title
          @db.exec "update intake_entries set book_title = ? where id = ?", title, e.id
        end
      end
    end

    # The library's titles and authors change, and entries analysed before
    # the column came have to get it
    private def mark_same(ix : Backlog::Index)
      all.each { |e| mark_same(e, ix) }
    end

    # Is the entry the book it looks like, by title and authors? A format the
    # book lacks isn't that (action addFormats), neither is a file like
    # another in the Eingang (no book_id), or one without a proposal.
    private def mark_same(e : Entry, ix : Backlog::Index) : Bool
      p, book = e.proposal, e.book_id
      same = e.status == "analysed" && e.action == "duplicate" && !p.nil? && !book.nil? && ix.same_book?(Intake.proposed_book(p), book)
      @db.exec "update intake_entries set same_book = ? where id = ?", same ? 1 : 0, e.id unless same == e.same_book
      same
    end

    private def unit_of(e : Entry) : Backlog::Unit?
      e.unit
    rescue ex : File::Error | IO::Error | XML::Error | ArgumentError
      STDERR.puts "intake: #{e.path}: #{ex.message}"
      nil
    end

    # Every file of the unit is in the library, byte for byte, and a calibre
    # folder has nothing else that would go with it: the unit moves to the
    # trash folder, or by the inbox's rules to _duplicates. A move that fails
    # leaves it in the list.
    private def trash_copy(u : Backlog::Unit, ix : Backlog::Index, origin : String) : Bool
      book = ix.exact(u) || return false
      return false if u.kind == "calibre" && !Intake.only_book?(u)
      paths = Intake.paths(u.kind, u.name, u.files)
      moved = box(origin).try { |b| paths.map { |p| b.move(p, Inbox::DUPLICATES) } } || IntakeTrash.move(roots, paths)
      puts "intake: #{u.name} is in book #{book} byte for byte, moved to #{moved.join(", ")}"
      settled_upload(u.name, "copy", book) if origin == UPLOAD
      true
    rescue ex : File::Error | IO::Error
      STDERR.puts "intake: moving #{u.name} failed: #{ex.message}"
      false
    end

    def self.only_book?(u : Backlog::Unit) : Bool
      files = u.files.map { |f| File.basename(f.path) }.to_set
      Dir.children(u.dir).all? { |n| files.includes?(n) || n == Backlog::OPF || n == Backlog::COVER }
    end

    # what moves: a calibre folder as a whole, else the unit's files
    def self.paths(kind : String, name : String, files : Array(Backlog::BookFile)) : Array(String)
      kind == "calibre" ? [name] : files.map(&.path)
    end

    private def forget(e : Entry)
      settled_upload(e.path, "gone", nil) if e.origin == UPLOAD
      @db.exec "delete from intake_candidates where entry_id = ?", e.id
      @db.exec "delete from intake_entries where id = ?", e.id
      e.cover.try { |c| File.delete?(c) if c.starts_with?(@covers) }
      forget_peeks(e.id)
    end

    # the entries of jobs that ended without them are back in the list
    private def release
      @db.exec "update intake_entries set decision = null where decision is not null and " \
               "decision not in (select id from intake_jobs where status = 'running')"
    end

    # The job stopped: what it hadn't got to is back in the list
    def release(job : String, why : String?)
      @db.exec "update intake_entries set decision = null, error = ? where decision = ?", why, job
    end

    # A decision went through, or the entry's files changed: the next pass
    # looks at what is left
    def finish(e : Entry)
      forget(e)
    end

    # The book is in the library. The backlog's file stays where it is and
    # import_files remembers it, the inbox's and an upload's leaves the
    # folder. A move that fails doesn't take the book back: the file comes up
    # again and goes to _duplicates as a copy.
    def taken(e : Entry, unit : Backlog::Unit)
      if b = box(e.origin)
        begin
          Intake.paths(e.kind, e.path, e.files).each { |p| b.move(p, Inbox::IMPORTED) }
        rescue ex : File::Error | IO::Error
          STDERR.puts "intake: moving #{e.path} away failed: #{ex.message}"
        end
        settled_upload(e.path, unit.status, unit.book_id) if e.origin == UPLOAD
        unit.book_id.try do |id|
          found = unit.status == "imported" ? similar_books(id) : nil
          puts "#{e.origin}: ##{id} looks like #{found.map { |x| "##{x.id}" }.join(", ")} (see Duplikate)" if found
        end
      else
        @imports.handled(unit, RUN)
      end
      finish(e)
    end

    # The decision failed: the entry is back in the list and says why
    def failed(e : Entry, why : String)
      @db.exec "update intake_entries set decision = null, error = ? where id = ?", why, e.id
    end

    # Taking the book turned out to add nothing, it looks like one the
    # library has: back in the list as that
    def duplicate(e : Entry, u : Backlog::Unit, ix : Backlog::Index)
      @db.exec "update intake_entries set decision = null, error = ?, action = 'duplicate', book_id = ?, match = ?, " \
               "same_as = ?, add_formats = '[]', book_title = ? where id = ?",
        u.detail, u.book_id, u.match, u.same_as, u.book_id.try { |b| ix.title(b) }, e.id
      self[e.id]?.try { |now| mark_same(now, ix) }
    end

    # entries wait in the job from now on, they left the list
    def waiting(ids : Array(Int64), job : String)
      ids.each_slice(STORE_BATCH) do |slice|
        @db.exec "update intake_entries set decision = ?, error = null where id in (#{slice.join(",")})", job
      end
    end

    # What the entry's decision writes. accept: the proposal, or what a
    # chosen candidate says; title and authors as edited over those; file:
    # nothing. A book marked as a duplicate was taken knowing that.
    def chosen(e : Entry, changes : Hash(String, JSON::Any)) : Importer::Chosen
      decision = flow_decision(e)
      return given(e, {} of String => JSON::Any, as_in_file) if changes["decision"] == "file"
      p = e.proposal || raise Edit::Invalid.new("decision", "no proposal")
      values = Intake.values(p)
      if i = changes["candidate"]?.try(&.as_i?) || changes["picks"]?.try(&.[e.id.to_s]?).try(&.as_i?)
        c = candidates(e.id)[i]? || raise Edit::Invalid.new("candidate", "no such candidate")
        values = Intake.candidate_values(p, c.fields)
        decision = Intake.picked(decision || as_in_file, c)
      end
      title = changes["title"]?.try(&.as_s?)
      authors = changes["authors"]?.try(&.as_a?)
      if title || authors
        title.try { |t| values["title"] = JSON::Any.new(t) }
        authors.try { |a| values["authors"] = JSON::Any.new(a) }
        hand = Meta::Confidence::HAND
        decision = (decision || as_in_file).copy_with(changes: [] of Meta::Change, title: title ? hand : (decision.try(&.title) || hand),
          authors: authors ? hand : (decision.try(&.authors) || hand))
      end
      given(e, values, decision || as_in_file)
    end

    # with what the entry's source says of it
    private def given(e : Entry, values : Hash(String, JSON::Any), decision : Meta::Flow::Decision) : Importer::Chosen
      category = e.kategorie.try { |k| @category_column.try { |c| {c, k} } }
      Importer::Chosen.new(values, decision, e.action == "duplicate" || e.forced, e.forced, e.tags, category)
    end

    # the flow's decision again, from the entry; a standard's has none
    private def flow_decision(e : Entry) : Meta::Flow::Decision?
      level = e.level || return nil
      kept = Meta::Confidence::KEPT
      Meta::Flow::Decision.new(e.changes.map { |c| Meta::Change.new(c.field, c.old, c.new, c.source) }, e.decided || "rules", level,
        e.source || "rules", e.title_confidence || kept, e.authors_confidence || kept, e.proposal.try(&.isbn), e.isbn_source, e.notes)
    end

    # nobody's but the person's who took the file as it is
    private def as_in_file : Meta::Flow::Decision
      kept = Meta::Confidence::KEPT
      Meta::Flow::Decision.new([] of Meta::Change, "file", Meta::Flow::LEVEL_META, "file", kept, kept)
    end

    # A candidate is chosen because the proposal is another book: nothing of
    # that book stays but a title and authors the candidate doesn't have.
    def self.candidate_values(p : Proposal, r : Meta::Record) : Hash(String, JSON::Any)
      v = {"title" => JSON::Any.new(p.title), "authors" => JSON.parse(p.authors.to_json)}
      overlay(v, r)
      v
    end

    # Arthur's choice: as sure as his hand whatever the rules thought of it,
    # with no tag and no note about the proposal's ISBN
    def self.picked(d : Meta::Flow::Decision, c : Candidate) : Meta::Flow::Decision
      hand = Meta::Confidence::HAND
      d.copy_with(changes: [] of Meta::Change, how: c.source, source: c.source, title: hand, authors: hand,
        isbn: c.fields.isbn.try { |i| Meta::Isbn.normalize(i) }, isbn_source: c.fields.isbn ? c.source : nil,
        notes: [] of Meta::Flow::Note)
    end

    def self.values(p : Proposal) : Hash(String, JSON::Any)
      v = {"title" => JSON::Any.new(p.title), "authors" => JSON.parse(p.authors.to_json)}
      overlay(v, Meta::Record.new(publisher: p.publisher, pubdate: p.pubdate, series: p.series, series_index: p.series_index,
        isbn: p.isbn, languages: p.languages))
      v
    end

    # what the record says, over values
    def self.overlay(v : Hash(String, JSON::Any), r : Meta::Record)
      r.title.presence.try { |t| v["title"] = JSON::Any.new(t) }
      r.authors.try { |a| v["authors"] = JSON.parse(a.to_json) unless a.empty? }
      r.publisher.presence.try { |x| v["publisher"] = JSON::Any.new(x) }
      r.pubdate.presence.try { |x| v["pubdate"] = JSON::Any.new(x) }
      r.isbn.presence.try { |x| v["isbn"] = JSON::Any.new(x) }
      r.comments.presence.try { |x| v["comments"] = JSON::Any.new(x) }
      r.languages.try { |l| v["languages"] = JSON.parse(l.to_json) unless l.empty? }
      r.series.presence.try do |s|
        v["series"] = JSON::Any.new(s)
        r.series_index.try { |i| v["seriesIndex"] = JSON::Any.new(i) }
      end
    end

    # The entry's unit to the trash folder
    def trash(e : Entry)
      moved = IntakeTrash.move(roots, Intake.paths(e.kind, e.path, e.files))
      puts "intake: #{e.path} moved to #{moved.join(", ")}"
      settled_upload(e.path, "trashed", nil) if e.origin == UPLOAD
      forget(e)
    end

    private def auto_key(origin : String) : String
      origin == BACKLOG ? AUTO : "#{AUTO}_#{origin}"
    end

    # A source's threshold, nil: off. The inbox and uploads are on until
    # someone switches them off, so a stored „off“ is what says so.
    def threshold(origin : String = BACKLOG) : Int32?
      stored = @db.query_one?("select value from meta where key = ?", auto_key(origin), as: String)
      return stored.to_i? if stored
      origin == BACKLOG ? nil : AUTO_DEFAULT
    end

    # the thresholds of the sources there are
    def thresholds : Hash(String, Int32?)
      origins_on.to_h { |o| {o, threshold(o)} }
    end

    # nil switches it off; what is above it already goes the same way
    def set_threshold(origin : String, value : Int32?)
      @db.exec "insert or replace into meta (key, value) values (?, ?)", auto_key(origin), value ? value.to_s : "off"
      accept_above if value
    end

    # Entries at or above their source's threshold go to the library. Nobody
    # looks at them: only new books, not what looks like one the library has,
    # not what was skipped or came back with an error.
    private def accept_above
      ORIGINS.each do |origin|
        limit = threshold(origin) || next
        ids = [] of Int64
        @db.query_each("select id from intake_entries where decision is null and skipped = 0 and error is null and " \
                       "status = 'analysed' and action = 'add' and origin = ? and confidence >= ?", origin, limit) { |rs| ids << rs.read(Int64) }
        decisions.queue(ids, {"decision" => JSON::Any.new("accept")}) unless ids.empty?
      end
    end

    # the analysis is at it, so what can wait does (RepairRecheck)
    def working? : Bool
      @state.in?("scanning", "analysing") || !@fast_current.nil?
    end

    # the entry's book counts for later ones, by a pseudo id
    private def remember(ix : Backlog::Index, e : Entry)
      remember(ix, e.id, e.path, e.files, e.proposal)
    end

    private def remember(ix : Backlog::Index, id : Int64, path : String, files : Array(Backlog::BookFile), p : Proposal?)
      pseudo = -id
      ix.planned[pseudo] = path
      ix.add_files(pseudo, files)
      return unless p
      m = Backlog::OpfMeta.new
      m.title = p.title
      m.authors = p.authors
      m.series = p.series
      m.series_index = p.series_index
      m.publisher = p.publisher
      p.isbn.try { |i| m.identifiers["isbn"] = i }
      ix.add_meta(pseudo, m)
    end

    # One unit: what the library knows of it, what the rules make of it. An
    # upload sent on purpose is a new book, whatever it looks like.
    def analyse(unit : Backlog::Unit, ix : Backlog::Index, extra = Extra.new)
      Backlog.plan(unit, ix)
      return if !extra.forced && trash_copy(unit, ix, extra.origin)
      primary = unit.primary
      name = File.basename(primary.path)
      info = read(primary)
      book = Intake.book(unit, info)
      calibre_named = unit.kind == "calibre" || Backlog.calibre_name?(unit.dir)
      hint = calibre_named ? Meta::FileName::CALIBRE_NAME : @imports.hint(unit.dir)
      found = [] of Candidate
      input = Meta::Flow::Input.new(book, ->(field : String) { Meta::Merge.value(book, field).as(JSON::Any?) }, name, hint)
      input.info = Intake.flow_info(unit, info)
      input.by_isbn = watched_lookup(found, input.info.try(&.words))
      input.decider = watched_decider(found)
      input.checker = watched_checker(found)
      input.owners = ->(isbn : String) { ix.isbn_books(isbn) }
      decision = Meta::Flow.decide(input)
      proposal = Intake.proposal(book, decision, info)
      Intake.own_candidates(found, unit, info, name, hint)
      searched(found, book, proposal)
      if unit.action == "add" && (hit = ix.match_book(Intake.proposed_book(proposal)))
        Backlog.mark(unit, hit[0], hit[1], ix)
      end
      Intake.as_new(unit) if extra.forced
      id = store(unit, proposal, decision, Intake.ranked(found), extra)
      unit.book_id.try { |b| @db.exec "update intake_entries set book_title = ? where id = ?", ix.title(b), id }
      self[id]?.try { |e| mark_same(e, ix) }
      remember(ix, id, unit.name, unit.files, proposal) if unit.action == "add"
      cover(unit, id)
      accept_above
    rescue ex
      # the file stays in the list, unchanged it isn't tried again
      STDERR.puts "intake: #{unit.name}: #{ex.message}"
      store_failed(unit, ex.message || ex.class.name, extra)
    end

    # the plan of a book nothing is known about
    def self.as_new(unit : Backlog::Unit)
      unit.action = "add"
      unit.book_id = nil
      unit.match = nil
      unit.same_as = nil
      unit.add_formats = [] of String
    end

    private def read(file : Backlog::BookFile) : Meta::FileMeta::Info?
      r = @reader || return nil
      return r.call(file.path, file.format) if Meta::FileMeta::FORMATS.includes?(file.format)
      Meta::FileMeta.metadata(file.path, file.format, nice: true)
    end

    # What calibre would read, without adding the book: the name as calibre
    # reads it (FileName.calibre) with the file's metadata over it. A calibre
    # folder's book is what its metadata.opf says.
    def self.book(unit : Backlog::Unit, info : Meta::FileMeta::Info?) : Book
      title, authors = Meta::FileName.calibre(File.basename(unit.primary.path))
      r = unit.meta.try { |m| opf_record(m) } || info.try(&.record) || Meta::Record.new
      ids = unit.meta.try(&.identifiers.dup) || {} of String => String
      r.isbn.try { |i| ids["isbn"] = i }
      Book.new(id: 0_i64, title: r.title.presence || title, authors: r.authors.try { |a| a.reject(&.empty?) unless a.all?(&.empty?) } || authors,
        author_sort: nil, tags: unit.meta.try(&.tags) || [] of String, series: r.series, series_index: r.series_index,
        formats: unit.files.map(&.format), last_modified: Time::UNIX_EPOCH, timestamp: nil, pubdate: time(r.pubdate),
        rating: nil, publisher: r.publisher, identifiers: ids, languages: r.languages || [] of String,
        comments: r.comments, custom: {} of String => JSON::Any)
    end

    private def self.time(date : String?) : Time?
      date.try { |d| Time.parse_utc(Meta::Dates.full(d)[0, 10], "%F") }
    rescue Time::Format::Error
      nil
    end

    def self.opf_record(m : Backlog::OpfMeta) : Meta::Record
      Meta::Record.new(title: m.title, authors: m.authors.empty? ? nil : m.authors, isbn: m.isbn, publisher: m.publisher,
        pubdate: m.pubdate, languages: m.languages.empty? ? nil : m.languages, comments: m.comments, series: m.series,
        series_index: m.series_index)
    end

    # What the flow reads: of a calibre folder the OPF takes the place of the
    # file's metadata. Its format is no EPUB's, which Flow would trust: its
    # title and authors have to fit the text or the name.
    def self.flow_info(unit : Backlog::Unit, info : Meta::FileMeta::Info?) : Meta::FileMeta::Info?
      m = unit.meta || return info
      record = opf_record(m)
      info ? info.copy_with(record: record, format: "OPF") : Meta::FileMeta::Info.new(record, [] of String, format: "OPF")
    end

    # The book with the decision's changes; below the threshold what was
    # found as a suggestion, the confidence says how far to trust it
    def self.proposal(book : Book, d : Meta::Flow::Decision?, info : Meta::FileMeta::Info?) : Proposal
      values = changed_values(book, d.try(&.changes) || [] of Meta::Change)
      unless d
        # a standard: the rules know its name, no flow decides it
        Meta::Norms.parse(book, info.try(&.cover)).try do |norm|
          r = norm.record
          values["title"] = JSON::Any.new(r.title)
          values["authors"] = JSON.parse((r.authors || book.authors).to_json)
          values["publisher"] = JSON::Any.new(r.publisher)
          values["pubdate"] = JSON::Any.new(r.pubdate)
        end
      end
      from_values(values)
    end

    def self.changed_values(book : Book, changes : Array(Meta::Change)) : Hash(String, JSON::Any)
      values = FIELDS.to_h { |f| {f, Meta::Merge.value(book, f)} }
      changes.each do |c|
        if c.field == Meta::FileName::CANDIDATE
          c.new["title"]?.try(&.as_s?).try { |t| values["title"] = JSON::Any.new(t) }
          c.new["authors"]?.try { |a| values["authors"] = a unless a.as_a.empty? }
        elsif values.has_key?(c.field)
          values[c.field] = c.new
        end
      end
      values
    end

    def self.from_values(values : Hash(String, JSON::Any)) : Proposal
      Proposal.new(values["title"].as_s, values["authors"].as_a.map(&.as_s), values["publisher"].as_s?, values["pubdate"].as_s?,
        values["series"].as_s?, values["seriesIndex"].as_f?, values["isbn"].as_s?, values["languages"].as_a.map(&.as_s))
    end

    # the proposal as Dedup's rules see it
    def self.proposed_book(p : Proposal) : Book
      Backlog.book(0_i64, p.title, p.authors, p.series, p.series_index,
        p.isbn ? {"isbn" => p.isbn.not_nil!} : {} of String => String, p.publisher)
    end

    # The flow's questions to the catalogs are the candidates: nothing is
    # asked twice and the rules stay in one place. An ISBN's record is as sure
    # as it fits the book's text.
    private def watched_lookup(found : Array(Candidate), words : Meta::Words?) : Meta::Flow::Lookup?
      lookup = @by_isbn || return nil
      ->(isbn : String) do
        list = lookup.call(isbn)
        list.each do |c|
          fit = words.try { |w| Meta::Fit.check(c.fields, w) }
          value = if fit.nil?
                    Meta::Confidence::CATALOG
                  elsif fit.both?
                    Meta::Confidence::ISBN_BOTH
                  elsif fit.any?
                    Meta::Confidence::ISBN_ONE
                  else
                    Meta::Confidence::ISBN_AGAINST
                  end
          found << Candidate.new(c.source, value, c.fields, c.url)
        end
        list
      end
    end

    private def watched_checker(found : Array(Candidate)) : Meta::FileName::Checker?
      checker = @checker || return nil
      ->(b : Book, g : Meta::Guess) do
        v = checker.call(b, g)
        if v
          value = v.confirmed && v.sources.size >= 2 ? Meta::Confidence::CATALOGS : Meta::Confidence::CATALOG
          found << Candidate.new(v.source, value, Meta::Record.new(title: v.title || g.title, authors: v.authors))
        end
        v
      end
    end

    private def watched_decider(found : Array(Candidate)) : Meta::FileName::Decider?
      decider = @decider || return nil
      ->(b : Book, name : String, readings : Array(Meta::Guess)) do
        d = decider.call(b, name, readings)
        if d
          guess, source = d
          value = source == "model" ? Meta::Confidence::MODEL : Meta::Confidence::CATALOG_NAME
          found << Candidate.new(source, value, Meta::Record.new(title: guess.title, authors: guess.authors))
        end
        d
      end
    end

    # what the file, its OPF and its name say themselves
    def self.own_candidates(found : Array(Candidate), unit : Backlog::Unit, info : Meta::FileMeta::Info?, name : String, hint : Symbol?)
      reading = Meta::FileName.parse(name, hint)
      unit.meta.try { |m| own_candidate(found, Meta::Flow::SOURCE_OPF, opf_record(m), reading) }
      info.try { |i| own_candidate(found, "file", i.record, reading) }
      return unless reading
      value = reading.authors.empty? ? Meta::Confidence::UNCLEAR : Meta::Flow.name_value(reading.authors)
      found << Candidate.new(Meta::FileName::NAME, value, Meta::Record.new(title: reading.title,
        authors: reading.authors.empty? ? nil : reading.authors, publisher: reading.publisher, series: reading.series,
        series_index: reading.series_index))
    end

    private def self.own_candidate(found : Array(Candidate), source : String, r : Meta::Record, reading : Meta::Guess?)
      title = r.title.presence || return
      value = if reading.nil?
                Meta::Confidence::META_NOTHING
              elsif Meta::FileName.same_book?(reading.title, title)
                Meta::Confidence::META_NAME
              else
                Meta::Confidence::META_NAME - Meta::Confidence::META_AGAINST_NAME
              end
      found << Candidate.new(source, value, r)
    end

    # a file without a catalog's record so far: what they have under its title
    private def searched(found : Array(Candidate), book : Book, p : Proposal)
      search = @search || return
      return if found.any? { |c| !own_source?(c.source) } || Meta::FileName.bad_title?(p.title)
      known = Meta::Clean.unknown_authors?(p.authors) ? [] of String : p.authors
      search.call(book, Meta::Guess.new(p.title, known)).each do |c|
        value = c.sure || c.score >= Meta::HIGH ? Meta::Confidence::CATALOG_NAME : Meta::Confidence::CATALOG
        found << Candidate.new(c.source, value, c.fields, c.url)
      end
    end

    private def own_source?(source : String) : Bool
      source.in?("file", Meta::Flow::SOURCE_OPF, Meta::FileName::NAME)
    end

    # the surest first, one per source and title; no HTML of others unchecked
    def self.ranked(found : Array(Candidate)) : Array(Candidate)
      list = found.sort_by { |c| -c.confidence }
      seen = Set({String, String}).new
      list = list.select { |c| seen.add?({c.source, Meta::Text.key(c.fields.title || "")}) }
      list.each { |c| c.fields.comments = c.fields.comments.try { |html| Sanitizer.clean(html).presence } }
      list
    end

    private def store(unit : Backlog::Unit, p : Proposal, d : Meta::Flow::Decision?, candidates : Array(Candidate), extra : Extra) : Int64
      changes = (d.try(&.changes) || [] of Meta::Change).map { |c| Changed.new(c.field, c.old, c.new, c.source) }
      # a standard and whatever no rule has a word about: nothing against it
      confidence = d.try(&.confidence) || Meta::Confidence::KEPT
      id = insert(unit, "analysed", nil, p.to_json, confidence, d.try(&.title) || confidence, d.try(&.authors) || confidence,
        d.try(&.level), d.try(&.source) || "rules", d.try(&.how), d.try(&.isbn_source), (d.try(&.notes) || [] of Meta::Flow::Note).to_json, changes.to_json, extra)
      @db.transaction do |tx|
        candidates.each_with_index do |c, i|
          tx.connection.exec "insert into intake_candidates (entry_id, idx, source, confidence, fields, url) values (?, ?, ?, ?, ?, ?)",
            id, i, c.source, c.confidence, c.fields.to_json, c.url
        end
      end
      id
    end

    private def store_failed(unit : Backlog::Unit, detail : String, extra : Extra)
      insert(unit, "failed", detail, nil, nil, nil, nil, nil, nil, nil, nil, "[]", "[]", extra)
    end

    private def insert(unit : Backlog::Unit, status : String, detail : String?, proposal : String?, confidence : Int32?,
                       title : Int32?, authors : Int32?, level : Int32?, source : String?, decided : String?,
                       isbn_source : String?, notes : String, changes : String, extra : Extra) : Int64
      @db.exec("insert or replace into intake_entries (path, kind, files, status, detail, proposal, confidence, title_confidence, " \
               "authors_confidence, level, source, decided, isbn_source, notes, changes, action, book_id, match, same_as, add_formats, cover, at, " \
               "origin, tags, kategorie, forced) " \
               "values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        unit.name, unit.kind, unit.files.to_json, status, detail, proposal, confidence, title, authors, level, source, decided,
        isbn_source, notes, changes, unit.action, unit.book_id, unit.match, unit.same_as, unit.add_formats.to_json, unit.cover,
        Time.utc.to_unix, extra.origin, extra.tags.to_json, extra.kategorie, extra.forced ? 1 : 0).last_insert_id
    end

    private def cover(unit : Backlog::Unit, id : Int64)
      return if unit.cover
      Dir.mkdir_p(@covers)
      target = File.join(@covers, "#{id}.jpg")
      primary = unit.primary
      @db.exec "update intake_entries set cover = ? where id = ?", target, id if @cover_reader.call(primary.path, primary.format, target)
    rescue ex : File::Error | IO::Error
      # the list does without it
      STDERR.puts "intake: no cover of #{unit.name}: #{ex.message}"
    end

    private def read_entry(rs) : Entry
      id, path, kind, files, status, detail, proposal = rs.read(Int64, String, String, String, String, String?, String?)
      confidence, title, authors, level = rs.read(Int32?, Int32?, Int32?, Int32?)
      source, decided, isbn_source, notes, changes, action = rs.read(String?, String?, String?, String, String, String)
      book, match, same_as, add_formats, cover, at = rs.read(Int64?, String?, String?, String, String?, Int64)
      skipped, error, book_title, job = rs.read(Int64, String?, String?, String?)
      origin, tags, kategorie, forced, same_book = rs.read(String, String, String?, Int64, Int64)
      Entry.new(id, path, kind, Array(Backlog::BookFile).from_json(files), status, detail, proposal.try { |p| Proposal.from_json(p) },
        confidence, title, authors, level, source, decided, isbn_source, Array(Meta::Flow::Note).from_json(notes),
        Array(Changed).from_json(changes), action, book, match, same_as, Array(String).from_json(add_formats), cover, at,
        skipped == 1, error, book_title, job, origin, Array(String).from_json(tags), kategorie, forced == 1, same_book == 1)
    end

    private def all : Array(Entry)
      list = [] of Entry
      @db.query_each("select #{COLUMNS} from intake_entries order by id") { |rs| list << read_entry(rs) }
      list
    end

    def []?(id : Int64) : Entry?
      @db.query_one?("select #{COLUMNS} from intake_entries where id = ?", id) { |rs| read_entry(rs) }
    end

    def candidates(id : Int64) : Array(Candidate)
      list = [] of Candidate
      @db.query_each("select source, confidence, fields, url from intake_candidates where entry_id = ? order by idx", id) do |rs|
        source, confidence, fields, url = rs.read(String, Int32, String, String?)
        list << Candidate.new(source, confidence, Meta::Record.from_json(fields), url)
      end
      list
    end

    # Where the analysis is, of the whole list whatever the filters, so it
    # goes on after a restart. total: every book in the Eingang, analysed or
    # not. done: the ones looked at, those that failed included. analysed:
    # with a proposal.
    def progress
      done = @db.query_one("select count(*) from intake_entries where decision is null", as: Int64)
      analysed = @db.query_one("select count(*) from intake_entries where decision is null and status = 'analysed'", as: Int64)
      # the inbox and uploads go on while the rest stands still
      state = @fast_current ? "analysing" : (off? ? "off" : @state)
      {state: state, done: done, total: done + @left + @fast_left, analysed: analysed, current: @fast_current || @current}
    end

    # bulk, review, unsure: Meta::Confidence's bands; none: failed files
    private def band_sql(band : String?) : String?
      case band
      when nil      then nil
      when "bulk"   then "confidence >= #{Meta::Confidence::BULK}"
      when "review" then "confidence >= #{Meta::Confidence::REVIEW} and confidence < #{Meta::Confidence::BULK}"
      when "unsure" then "confidence < #{Meta::Confidence::REVIEW}"
      when "none"   then "confidence is null"
      else               raise Edit::Invalid.new("band", "bulk, review, unsure or none expected")
      end
    end

    # what is in the list by a filter; what waits for its job isn't
    private def filter_sql(band : String?, duplicates : Bool?, skipped : Bool?, origin : String? = nil) : String
      kind = duplicates.nil? ? nil : (duplicates ? "action != 'add'" : "action = 'add'")
      ["decision is null", band_sql(band), kind, skipped ? "skipped = 1" : nil, origin_sql(origin)].compact.join(" and ")
    end

    private def origin_sql(origin : String?) : String?
      return nil unless origin
      raise Edit::Invalid.new("origin", "backlog, inbox or upload expected") unless ORIGINS.includes?(origin)
      "origin = '#{origin}'"
    end

    # how many of each source are in the list, whatever the filters: only
    # with more than one the page offers to choose
    private def origin_counts : Hash(String, Int64)
      counts = {} of String => Int64
      @db.query_each("select origin, count(*) from intake_entries where decision is null group by origin") { |rs| counts[rs.read(String)] = rs.read(Int64) }
      counts
    end

    # Of a filter what „Alle N übernehmen“ takes. Not a failed file, there is
    # no proposal; not what looks like a book of the library, that is for
    # Arthur one by one; not what he skipped, unless that is the filter.
    private def takeable_sql(band : String?, duplicates : Bool?, skipped : Bool?, origin : String? = nil) : String
      sql = "#{filter_sql(band, duplicates, skipped, origin)} and status = 'analysed' and action != 'duplicate'"
      skipped ? sql : "#{sql} and skipped = 0"
    end

    # Of the filter on possible duplicates what „Alle N in den Papierkorb“
    # takes: a duplicate with the title and authors of its book, not what
    # only looks like it, what brings a format or what Arthur skipped.
    private def trashable_sql(band : String?, origin : String? = nil) : String
      "#{filter_sql(band, true, nil, origin)} and status = 'analysed' and action = 'duplicate' and same_book = 1 and skipped = 0"
    end

    # a place in the list, for a page to go on from: confidence and what
    # orders within it
    def self.place(confidence : Int32?, key : String | Int64) : String
      "#{confidence || -1}:#{key}"
    end

    def self.place(after : String) : {Int32, String}
      sure, _, key = after.partition(':')
      {sure.to_i? || raise(Edit::Invalid.new("after", "next of the page before expected")), key}
    end

    # What of a filter a bulk decision leaves in the list and why, so the
    # button's number and the filter's add up
    private def left_out(band : String?, duplicates : Bool?, skipped : Bool?, origin : String? = nil)
      clause = filter_sql(band, duplicates, skipped, origin)
      count = ->(extra : String) { @db.query_one("select count(*) from intake_entries where #{clause} and #{extra}", as: Int64) }
      {duplicates: count.call("status = 'analysed' and action = 'duplicate'"), failed: count.call("status != 'analysed'"),
       skipped: skipped ? 0_i64 : count.call("status = 'analysed' and action != 'duplicate' and skipped = 1"), unchanged: 0_i64}
    end

    # The list for the page: a page of entries with the filter's total, how
    # many of that kind there are per band, and what a bulk decision takes
    # (takeable; trashable on the filter on possible duplicates, else 0).
    # band: by confidence; duplicates: only those that match a book, or
    # (false) only the new ones; skipped: only the skipped ones; origin: of
    # one source. In the order of ORDER; after: the page behind this place
    # (next of the page before), a confidence and a path, which stays right
    # while entries leave the list and the analysis adds some.
    def list(band : String? = nil, duplicates : Bool? = nil, offset = 0, limit = 100, skipped : Bool? = nil, after : String? = nil, origin : String? = nil) : JSON::Any
      clause = filter_sql(band, duplicates, skipped, origin)
      total = @db.query_one("select count(*) from intake_entries where #{clause}", as: Int64)
      entries = [] of Entry
      size = limit.clamp(1, MAX_LIMIT)
      page = after ? "#{clause} and (#{SURE} < ? or (#{SURE} = ? and (lower(path), path) > (lower(?), ?)))" : clause
      args = [] of DB::Any
      after.try do |a|
        sure, path = Intake.place(a)
        args = [sure, sure, path, path] of DB::Any
      end
      args += [(size + 1).as(DB::Any), {offset, 0}.max.as(DB::Any)]
      @db.query_each("select #{COLUMNS} from intake_entries where #{page} order by #{ORDER} limit ? offset ?", args: args) do |rs|
        entries << read_entry(rs)
      end
      more = entries.size > size
      entries.pop if more
      counts = Hash(String, Int64).new(0_i64)
      (Meta::Confidence::BANDS + ["none"]).each do |b|
        counts[b] = @db.query_one("select count(*) from intake_entries where #{filter_sql(b, duplicates, skipped, origin)}", as: Int64)
      end
      takeable = takeable_sql(band, duplicates, skipped, origin)
      JSON.parse({enabled: true, progress: progress, total: total, counts: counts, next: more ? Intake.place(entries.last.confidence, entries.last.path) : nil,
                  takeable: @db.query_one("select count(*) from intake_entries where #{takeable}", as: Int64),
                  unsure: @db.query_one("select count(*) from intake_entries where #{takeable} and confidence < #{Meta::Confidence::REVIEW}", as: Int64),
                  trashable: duplicates ? @db.query_one("select count(*) from intake_entries where #{trashable_sql(band, origin)}", as: Int64) : 0_i64,
                  left: left_out(band, duplicates, skipped, origin), skipped: skipped_count,
                  last: @db.query_one("select coalesce(max(id), 0) from intake_entries", as: Int64),
                  pending: pending_count,
                  thresholds: thresholds, origins: origin_counts, entries: entries.map(&.to_api(roots))}.to_json)
    end

    private def skipped_count : Int64
      @db.query_one("select count(*) from intake_entries where decision is null and skipped = 1", as: Int64)
    end

    # decided, waiting for their job; a library book's accept too
    private def pending_count : Int64
      @db.query_one("select count(*) from intake_entries where decision is not null", as: Int64) +
        (@repair ? @db.query_one("select count(*) from import_repairs where decision is not null", as: Int64) : 0_i64)
    end

    # POST /api/intake/decide. decision: accept, file, trash go through the
    # queue, and format (one entry's files to the book {book: id}), skip and
    # unskip are done at once. target: {ids: [...]} or, to
    # accept all of a filter, {query: {band, duplicates, skipped, origin}, last, expect}:
    # last (the list's) leaves out what the analysis added since, expect
    # (takeable) is the number meant. The same to trash all of the filter on
    # possible duplicates, {query: {band, duplicates: true, origin}, ...},
    # expect being trashable. One entry's accept takes a candidate
    # (index) and the edited title and authors, a filter's the candidates
    # chosen so far (picks: {entry id: index}). Library books (negative ids,
    # query {library: true}) have their own exits: decide_library.
    def decide(body : Hash(String, JSON::Any)) : {Int32, JSON::Any}
      decision = body["decision"]?.try(&.as_s?) || raise Edit::Invalid.new("decision", "accept, file, format, skip, unskip, trash or reject expected")
      raise Edit::Invalid.new("decision", "accept, file, format, skip, unskip, trash or reject expected") unless DECISIONS.includes?(decision)
      target = body["target"]?.try(&.as_h?) || raise Edit::Invalid.new("target", "object expected")
      return decide_library(body, decision, target) if library_target?(target)
      raise Edit::Invalid.new("decision", "reject is for books of the library") if decision == "reject"
      ids = target["query"]? ? by_filter(target, decision) : by_ids(target)
      changes = chosen_changes(body, decision, ids)
      if decision.in?("skip", "unskip")
        skip(ids, decision == "skip")
        return {200, JSON.parse({total: ids.size}.to_json)}
      end
      job = ids.empty? ? nil : decisions.queue(ids, changes)
      {202, JSON.parse({jobId: job.try(&.id), total: ids.size}.to_json)}
    end

    DECISIONS = %w(accept file format skip unskip trash reject)

    # the ones still in the list
    private def by_ids(target : Hash(String, JSON::Any)) : Array(Int64)
      list = target["ids"]?.try(&.as_a?) || raise Edit::Invalid.new("target", "ids or query expected")
      wanted = list.map { |v| v.as_i64? || raise Edit::Invalid.new("target", "ids must be numbers") }.uniq
      found = [] of Int64
      wanted.each_slice(STORE_BATCH) do |slice|
        @db.query_each("select id from intake_entries where decision is null and id in (#{slice.join(",")})") { |rs| found << rs.read(Int64) }
      end
      found
    end

    private def by_filter(target : Hash(String, JSON::Any), decision : String) : Array(Int64)
      raise Edit::Invalid.new("target", "only accept and trash take a filter") unless decision.in?("accept", "trash")
      q = target["query"].as_h? || raise Edit::Invalid.new("target", "object expected")
      expect = target["expect"]?.try(&.as_i64?) || raise Edit::Invalid.new("target", "expect (the number of books meant) required")
      last = target["last"]?.try(&.as_i64?) || raise Edit::Invalid.new("target", "last expected")
      trash = decision == "trash"
      raise Edit::Invalid.new("target", "trash takes the filter on possible duplicates") if trash && q["duplicates"]?.try(&.as_bool?) != true
      band, origin = q["band"]?.try(&.as_s?), q["origin"]?.try(&.as_s?)
      sql = trash ? trashable_sql(band, origin) : takeable_sql(band, q["duplicates"]?.try(&.as_bool?), q["skipped"]?.try(&.as_bool?), origin)
      ids = [] of Int64
      @db.query_each("select id from intake_entries where #{sql} and id <= ? order by #{ORDER}", last) { |rs| ids << rs.read(Int64) }
      ids = same_now(ids) if trash
      raise Jobs::CountMismatch.new(expect, ids.size) unless ids.size == expect
      ids
    end

    # The mark is as old as the last pass: the files go by the library as it
    # is now. A book changed or removed since takes its entry out of the
    # count and the mark, so the 409 is followed by the right number.
    private def same_now(ids : Array(Int64)) : Array(Int64)
      entries = ids.compact_map { |id| self[id]? }
      ix = Backlog::Index.new(@calibre.books(entries.compact_map(&.book_id).uniq))
      entries.select { |e| mark_same(e, ix) }.map(&.id)
    end

    # checked now, so a job finds what it needs
    private def chosen_changes(body : Hash(String, JSON::Any), decision : String, ids : Array(Int64)) : Hash(String, JSON::Any)
      changes = {"decision" => JSON::Any.new(decision)}
      if decision == "format"
        raise Edit::Invalid.new("target", "format is for one entry") unless ids.size <= 1
        id = body["book"]?.try(&.as_i64?) || raise Edit::Invalid.new("book", "book id expected")
        @calibre.book(id) || raise Writer::NotFound.new
        changes["book"] = JSON::Any.new(id)
      end
      %w(candidate title authors).each do |k|
        v = body[k]? || next
        next if v.raw.nil?
        raise Edit::Invalid.new(k, "only for one entry's accept") unless decision == "accept" && ids.size <= 1
        changes[k] = v
      end
      body["picks"]?.try do |picks|
        raise Edit::Invalid.new("picks", "only for accepting a filter") unless decision == "accept" && body["target"]["query"]?
        (picks.as_h? || raise Edit::Invalid.new("picks", "object expected")).each do |id, i|
          next unless (entry = id.to_i64?) && ids.includes?(entry)
          raise Edit::Invalid.new("picks", "no such candidate") unless i.as_i?.try { |n| candidates(entry)[n]? }
        end
        changes["picks"] = picks
      end
      changes["candidate"]?.try do |c|
        i = c.as_i? || raise Edit::Invalid.new("candidate", "index expected")
        ids.first?.try { |id| raise Edit::Invalid.new("candidate", "no such candidate") unless candidates(id)[i]? }
      end
      changes["title"]?.try do |t|
        raise Edit::Invalid.new("title", "title expected") unless t.as_s?.try(&.strip.presence)
        changes["title"] = JSON::Any.new(t.as_s.strip)
      end
      changes["authors"]?.try do |a|
        names = a.as_a?.try(&.map { |n| n.as_s?.try(&.strip) || "" }.reject(&.empty?)) || [] of String
        raise Edit::Invalid.new("authors", "at least one author") if names.empty?
        changes["authors"] = JSON.parse(names.to_json)
      end
      if decision == "accept"
        ids.each_slice(STORE_BATCH) do |slice|
          n = @db.query_one("select count(*) from intake_entries where proposal is null and id in (#{slice.join(",")})", as: Int64)
          raise Edit::Invalid.new("decision", "no proposal, the analysis failed") if n > 0
        end
      end
      changes
    end

    private def skip(ids : Array(Int64), on : Bool)
      ids.each_slice(STORE_BATCH) do |slice|
        @db.exec "update intake_entries set skipped = ? where id in (#{slice.join(",")})", on ? 1 : 0
      end
    end

    # One entry for the drawer: what the analysis changed, everything found
    def detail(id : Int64) : JSON::Any?
      return library_detail(-id) if id < 0
      e = self[id]? || return nil
      h = JSON.parse(e.to_api(roots).to_json).as_h
      h["changes"] = JSON.parse(e.changes.to_json)
      h["candidates"] = JSON.parse(candidates(id).to_json)
      h["bookTitle"] = JSON::Any.new(e.book_id.try { |b| book_title(b) })
      JSON::Any.new(h)
    end

    # the title of the library's book it looks like, for the note
    private def book_title(id : Int64) : String?
      @calibre.book(id).try(&.title)
    rescue Calibre::Error
      nil
    end
  end

  def self.intake_routes(intake : Intake?)
    get "/api/intake" do |env|
      next {enabled: false}.to_json unless intake
      write_errors(env) do
        q = env.params.query
        if q["library"]? == "true"
          next intake.library_list(q["band"]?.presence, q["limit"]?.try(&.to_i?) || 100, q["after"]?.presence).to_json
        end
        duplicates = q["duplicates"]?.presence.try { |v| v == "true" }
        intake.list(q["band"]?.presence, duplicates, q["offset"]?.try(&.to_i?) || 0, q["limit"]?.try(&.to_i?) || 100,
          q["skipped"]? == "true" ? true : nil, q["after"]?.presence, q["origin"]?.presence).to_json
      end
    end

    post "/api/intake/decide" do |env|
      write_errors(env) do
        next fail(env, 404, {error: "backlog import is off"}) unless intake
        status, result = intake.decide(json_body(env, required: true))
        env.response.status_code = status
        result.to_json
      end
    end

    # {origin, value: 60..100} accepts a source's books from there on,
    # {origin, value: null} switches it off
    post "/api/intake/threshold" do |env|
      write_errors(env) do
        next fail(env, 404, {error: "backlog import is off"}) unless intake
        body = json_body(env, required: true)
        origin = body["origin"]?.try(&.as_s?) || raise Edit::Invalid.new("origin", "backlog, inbox or upload expected")
        raise Edit::Invalid.new("origin", "backlog, inbox or upload expected") unless intake.origins_on.includes?(origin)
        raw = body["value"]? || raise Edit::Invalid.new("value", "number or null expected")
        value = raw.raw.nil? ? nil : (raw.as_i? || raise Edit::Invalid.new("value", "number or null expected"))
        raise Edit::Invalid.new("value", "#{Intake::AUTO_MIN} to #{Intake::AUTO_MAX} expected") if value && !(Intake::AUTO_MIN..Intake::AUTO_MAX).includes?(value)
        intake.set_threshold(origin, value)
        {thresholds: intake.thresholds}.to_json
      end
    end

    # what came of an upload (POST /api/books)
    get "/api/intake/uploads/:id" do |env|
      intake.try(&.upload_state(env.params.url["id"])).try(&.to_json) || fail(env, 404, {error: "not found"})
    end

    # {on: false} stops the analysis, {on: true} lets it go on
    post "/api/intake/analysis" do |env|
      write_errors(env) do
        next fail(env, 404, {error: "backlog import is off"}) unless intake
        on = json_body(env, required: true)["on"]?.try(&.as_bool?)
        raise Edit::Invalid.new("on", "true or false expected") if on.nil?
        intake.analysis = on
        intake.progress.to_json
      end
    end

    get "/api/intake/:id" do |env|
      id = env.params.url["id"].to_i64? || next fail(env, 404, {error: "not found"})
      intake.try(&.detail(id)).try(&.to_json) || fail(env, 404, {error: "not found"})
    end

    # the file itself, to read a few pages of it: only what the entry says is
    # its file, nothing is kept about the reading. first=1: a look is enough,
    # a large PDF's and a DjVu's first pages do (Intake#peek), the header says
    # when that isn't the whole book. Data, never a page of the hub.
    get "/api/intake/:id/file" do |env|
      id = env.params.url["id"].to_i64? || next fail(env, 404, {error: "not found"})
      first = env.params.query["first"]? == "1"
      file = intake.try(&.readable(id, env.params.query["format"]?.presence, first ? Intake::PEEKABLE : Intake::READABLE))
      next fail(env, 404, {error: "not found"}) unless file
      peek = first ? intake.not_nil!.peek(id, file) : Intake::Peek.new(file.path)
      path = peek.path || next fail(env, 422, {error: "no pages to show of this file"})
      env.response.content_type = "application/octet-stream"
      env.response.headers["Content-Disposition"] = "attachment"
      env.response.headers["Cache-Control"] = "private, no-store"
      env.response.headers[Intake::PEEK_HEADER] = Intake::PEEK_PAGES.to_s if peek.excerpt
      File.open(path) do |io|
        env.response.content_length = io.size
        IO.copy(io, env.response)
      end
      nil
    end

    get "/api/intake/:id/cover" do |env|
      id = env.params.url["id"].to_i64? || next fail(env, 404, {error: "not found"})
      path = intake.try(&.[id]?).try(&.cover)
      next fail(env, 404, {error: "not found"}) unless path && File.file?(path)
      data = File.open(path, &.getb_to_end)
      type = Covers.image_type(data) || next fail(env, 404, {error: "not found"})
      env.response.content_type = "image/#{type}"
      env.response.headers["Cache-Control"] = "private, max-age=86400"
      env.response.write(data)
      nil
    end
  end
end

require "./intake_decide"
require "./intake_library"
require "./intake_peek"
