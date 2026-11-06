require "db"
require "json"
require "kemal"
require "./backlog"
require "./backlog_jobs"
require "./meta_flow"
require "./sanitizer"

module CalibreHub
  # The „Eingang“: every book file of the backlog goes through a list before
  # it reaches the library. New files in the import roots are found without a
  # button and analysed one after another, at low priority, while no import
  # or repair runs: the same units as an import (Backlog::Scanner), the same
  # check against the library (Backlog::Index) and the same decision
  # (Meta::Flow), only from the file instead of from a book calibre added.
  # Nothing here has a way to write: calibre-server is only asked for its
  # list, the result goes to the state DB (intake_entries, with everything
  # found per file in intake_candidates) and a file changes hands only by a
  # decision (a later phase).
  #
  # A file analysed once stays that way as long as path, size and mtime are
  # the same, also over a restart; a file gone or handled by an import leaves
  # the list. A calibre folder's metadata.opf is the file's metadata that has
  # to prove itself like a PDF's, not what the book is called.
  class Intake
    # between two looks at the roots, after the hub started
    INTERVAL = 5.minutes
    START    = 1.minute
    # a file younger than this may still be copied
    STABLE = 2.minutes
    # between two books, so a run of hours stays in the background
    PAUSE = 500.milliseconds
    # between two looks while an import or repair runs
    WAIT = 30.seconds
    # entries per request at most
    MAX_LIMIT = 500

    # what a Book needs of the flow's fields, as the list shows them
    FIELDS = %w(title authors publisher pubdate series seriesIndex isbn languages)
    ORDER  = "lower(path)"

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
      add_formats : Array(String), cover : String?, at : Int64 do
      def primary : Backlog::BookFile
        files.min_by { |f| Backlog::FORMATS.index(f.format) || Backlog::FORMATS.size }
      end

      def band : String?
        confidence.try { |c| Meta::Confidence.band(c) }
      end

      def to_api
        {id: id, path: path, name: File.basename(primary.path), kind: kind,
         files: files.map { |f| {path: f.path, format: f.format, size: f.size} },
         status: status, detail: detail, proposal: proposal, confidence: confidence, band: band,
         titleConfidence: title_confidence, authorsConfidence: authors_confidence, level: level, source: source,
         decided: decided, isbnSource: isbn_source, notes: notes, action: action, bookId: book_id, match: match,
         sameAs: same_as, addFormats: add_formats, cover: cover ? "/api/intake/#{id}/cover?v=#{at}" : nil,
         analysedAt: Time.unix(at).to_rfc3339}
      end
    end

    COLUMNS = "id, path, kind, files, status, detail, proposal, confidence, title_confidence, authors_confidence, level, source, " \
              "decided, isbn_source, notes, changes, action, book_id, match, same_as, add_formats, cover, at"

    # reads a file for the rule flow (Metadata#read_flow, at low priority),
    # catalogs by ISBN (Metadata#isbn_lookup), an unclear name
    # (Metadata#decider), a reading without an author (Metadata#checker),
    # a title search (Metadata#search)
    property reader : Proc(String, String, Meta::FileMeta::Info?)?
    property by_isbn : Meta::Flow::Lookup?
    property decider : Meta::FileName::Decider?
    property checker : Meta::FileName::Checker?
    property search : Proc(Book, Meta::Guess, Array(Meta::Candidate))?
    # an import or repair runs: the analysis waits
    property busy : Proc(Bool)
    # the file's cover at a path (FileMeta.cover), true when there is one
    property cover_reader : Proc(String, String, String, Bool) = ->(path : String, format : String, target : String) do
      Meta::FileMeta.cover(path, format, target, nice: true)
    end

    # idle, scanning, analysing, paused
    getter state = "idle"
    # the file being analysed
    getter current : String? = nil

    def self.migrate(db : DB::Database)
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
    end

    # covers: where the pictures of plain files go, next to the state DB
    def initialize(@db : DB::Database, @calibre : Calibre, @imports : ImportJobs, @library : String?,
                   @covers : String, @interval = INTERVAL, @stable = STABLE, @pause = PAUSE, @wait = WAIT)
      Intake.migrate(@db)
      @busy = -> { @imports.running? }
      # files of this pass left, the current one included
      @left = 0
    end

    # Looks at the roots from now on
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
    end

    # One pass: the new files of the roots analysed. Returns how many.
    def run_once : Int32
      wait_idle
      @state = "scanning"
      ix = index
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
      while @busy.call
        waited = true
        @state = "paused"
        sleep @wait
      end
      waited
    end

    # The library and the books the list would add already, so the same book
    # twice in the roots is marked; what changed or left since goes first
    private def index : Backlog::Index
      ix = Backlog::Index.load(@calibre, @library, @db)
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
        same = e.files.all? do |f|
          info = File.info?(f.path)
          info && info.size == f.size && info.modification_time.to_unix == f.mtime
        end
        gone = e.files.all? { |f| (k = handled[f.path]?) && k[0] == f.size && k[1] == f.mtime }
        if same && !gone
          e.files.each { |f| known[f.path] = {f.size, f.mtime, "analysed", nil} }
        else
          forget(e)
        end
      end
      known
    end

    private def forget(e : Entry)
      @db.exec "delete from intake_candidates where entry_id = ?", e.id
      @db.exec "delete from intake_entries where id = ?", e.id
      e.cover.try { |c| File.delete?(c) if c.starts_with?(@covers) }
    end

    # the entry's book counts for later ones, by a pseudo id like a dry run's
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

    # One unit: what the library knows of it, what the rules make of it
    def analyse(unit : Backlog::Unit, ix : Backlog::Index)
      Backlog.plan(unit, ix)
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
      id = store(unit, proposal, decision, Intake.ranked(found))
      remember(ix, id, unit.name, unit.files, proposal) if unit.action == "add"
      cover(unit, id)
    rescue ex
      # the file stays in the list, unchanged it isn't tried again
      STDERR.puts "intake: #{unit.name}: #{ex.message}"
      store_failed(unit, ex.message || ex.class.name)
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
      values = FIELDS.to_h { |f| {f, Meta::Merge.value(book, f)} }
      d.try &.changes.each do |c|
        if c.field == Meta::FileName::CANDIDATE
          c.new["title"]?.try(&.as_s?).try { |t| values["title"] = JSON::Any.new(t) }
          c.new["authors"]?.try { |a| values["authors"] = a unless a.as_a.empty? }
        elsif values.has_key?(c.field)
          values[c.field] = c.new
        end
      end
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

    private def store(unit : Backlog::Unit, p : Proposal, d : Meta::Flow::Decision?, candidates : Array(Candidate)) : Int64
      changes = (d.try(&.changes) || [] of Meta::Change).map { |c| Changed.new(c.field, c.old, c.new, c.source) }
      # a standard and whatever no rule has a word about: nothing against it
      confidence = d.try(&.confidence) || Meta::Confidence::KEPT
      id = insert(unit, "analysed", nil, p.to_json, confidence, d.try(&.title) || confidence, d.try(&.authors) || confidence,
        d.try(&.level), d.try(&.source) || "rules", d.try(&.how), d.try(&.isbn_source), (d.try(&.notes) || [] of Meta::Flow::Note).to_json, changes.to_json)
      @db.transaction do |tx|
        candidates.each_with_index do |c, i|
          tx.connection.exec "insert into intake_candidates (entry_id, idx, source, confidence, fields, url) values (?, ?, ?, ?, ?, ?)",
            id, i, c.source, c.confidence, c.fields.to_json, c.url
        end
      end
      id
    end

    private def store_failed(unit : Backlog::Unit, detail : String)
      insert(unit, "failed", detail, nil, nil, nil, nil, nil, nil, nil, nil, "[]", "[]")
    end

    private def insert(unit : Backlog::Unit, status : String, detail : String?, proposal : String?, confidence : Int32?,
                       title : Int32?, authors : Int32?, level : Int32?, source : String?, decided : String?,
                       isbn_source : String?, notes : String, changes : String) : Int64
      @db.exec("insert or replace into intake_entries (path, kind, files, status, detail, proposal, confidence, title_confidence, " \
               "authors_confidence, level, source, decided, isbn_source, notes, changes, action, book_id, match, same_as, add_formats, cover, at) " \
               "values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        unit.name, unit.kind, unit.files.to_json, status, detail, proposal, confidence, title, authors, level, source, decided,
        isbn_source, notes, changes, unit.action, unit.book_id, unit.match, unit.same_as, unit.add_formats.to_json, unit.cover,
        Time.utc.to_unix).last_insert_id
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
      Entry.new(id, path, kind, Array(Backlog::BookFile).from_json(files), status, detail, proposal.try { |p| Proposal.from_json(p) },
        confidence, title, authors, level, source, decided, isbn_source, Array(Meta::Flow::Note).from_json(notes),
        Array(Changed).from_json(changes), action, book, match, same_as, Array(String).from_json(add_formats), cover, at)
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

    # Where the analysis is, for the one line above the list: done of total
    # counts the whole list, so it goes on after a restart
    def progress
      done = @db.query_one("select count(*) from intake_entries", as: Int64)
      {state: @state, done: done, total: done + @left, current: @current}
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

    # The list for the page: a page of entries with the filter's total, and
    # how many there are per filter. band: by confidence; duplicates: only
    # those that match a book, or (false) only the new ones.
    def list(band : String? = nil, duplicates : Bool? = nil, offset = 0, limit = 100) : JSON::Any
      where = [band_sql(band)]
      where << (duplicates ? "action != 'add'" : "action = 'add'") unless duplicates.nil?
      clause = where.compact.join(" and ").presence.try { |w| " where #{w}" } || ""
      total = @db.query_one("select count(*) from intake_entries#{clause}", as: Int64)
      entries = [] of Entry
      @db.query_each("select #{COLUMNS} from intake_entries#{clause} order by #{ORDER} limit ? offset ?", limit.clamp(1, MAX_LIMIT), {offset, 0}.max) do |rs|
        entries << read_entry(rs)
      end
      counts = Hash(String, Int64).new(0_i64)
      (Meta::Confidence::BANDS + ["none"]).each { |b| counts[b] = @db.query_one("select count(*) from intake_entries where #{band_sql(b)}", as: Int64) }
      counts["duplicates"] = @db.query_one("select count(*) from intake_entries where action != 'add'", as: Int64)
      JSON.parse({enabled: true, progress: progress, total: total, counts: counts, entries: entries.map(&.to_api)}.to_json)
    end

    # One entry for the drawer: what the analysis changed, everything found
    def detail(id : Int64) : JSON::Any?
      e = self[id]? || return nil
      h = JSON.parse(e.to_api.to_json).as_h
      h["changes"] = JSON.parse(e.changes.to_json)
      h["candidates"] = JSON.parse(candidates(id).to_json)
      JSON::Any.new(h)
    end
  end

  def self.intake_routes(intake : Intake?)
    get "/api/intake" do |env|
      next {enabled: false}.to_json unless intake
      write_errors(env) do
        q = env.params.query
        duplicates = q["duplicates"]?.presence.try { |v| v == "true" }
        intake.list(q["band"]?.presence, duplicates, q["offset"]?.try(&.to_i?) || 0, q["limit"]?.try(&.to_i?) || 100).to_json
      end
    end

    get "/api/intake/:id" do |env|
      id = env.params.url["id"].to_i64? || next fail(env, 404, {error: "not found"})
      intake.try(&.detail(id)).try(&.to_json) || fail(env, 404, {error: "not found"})
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
