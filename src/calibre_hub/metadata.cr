require "db"
require "file_utils"
require "json"
require "./alert"
require "./meta_rules"
require "./meta_sources"
require "./calibre"
require "./backlog_pause"
require "./covers"
require "./writer"
require "./classify"

module CalibreHub
  # The cleanup's change log (old/new per field, revertible) and per book
  # the outcome of the last run, in the state DB
  class MetaLog
    struct Entry
      include JSON::Serializable

      getter id : Int64
      @[JSON::Field(key: "bookId")]
      getter book_id : Int64
      getter field : String
      @[JSON::Field(emit_null: true)]
      getter old : JSON::Any
      @[JSON::Field(emit_null: true)]
      getter new : JSON::Any
      getter source : String
      @[JSON::Field(key: "jobId", emit_null: true)]
      getter job_id : String?
      getter at : Time
      @[JSON::Field(key: "revertedAt", emit_null: true)]
      getter reverted_at : Time?

      def initialize(@id, @book_id, @field, @old, @new, @source, @job_id, @at, @reverted_at)
      end
    end

    COLUMNS = "id, book_id, field, old, new, source, job_id, at, reverted_at"
    # a book checked this recently isn't part of "incomplete" again
    RECHECK = 30.days

    def initialize(@db : DB::Database)
      @db.exec <<-SQL
        create table if not exists metadata_changes (
          id integer primary key autoincrement,
          book_id integer not null,
          field text not null,
          old text not null,
          new text not null,
          source text not null,
          job_id text,
          at integer not null,
          reverted_at integer
        )
        SQL
      @db.exec "create index if not exists metadata_changes_book on metadata_changes (book_id)"
      # status: queued (waiting for a run, e.g. a new book), done, retry
      # (a source failed or the book changed meanwhile), failed
      @db.exec <<-SQL
        create table if not exists metadata_books (
          book_id integer primary key,
          status text not null,
          at integer not null,
          job_id text
        )
        SQL
    end

    def add(book_id : Int64, field : String, old : JSON::Any, new : JSON::Any, source : String, job_id : String?) : Entry
      at = Time.utc
      @db.exec "insert into metadata_changes (book_id, field, old, new, source, job_id, at) values (?, ?, ?, ?, ?, ?, ?)",
        book_id, field, old.to_json, new.to_json, source, job_id, at.to_unix
      id = @db.scalar("select last_insert_rowid()").as(Int64)
      self[id]?.not_nil!
    end

    def []?(id : Int64) : Entry?
      @db.query_one?("select #{COLUMNS} from metadata_changes where id = ?", id) { |rs| read(rs) }
    end

    # newest first
    def list(book_id : Int64? = nil, since : Time? = nil, reverted : Bool? = nil, limit = 500) : Array(Entry)
      where = [] of String
      args = [] of DB::Any
      book_id.try { |b| where << "book_id = ?"; args << b }
      since.try { |s| where << "at >= ?"; args << s.to_unix }
      where << (reverted ? "reverted_at is not null" : "reverted_at is null") unless reverted.nil?
      args << limit.to_i64
      sql = "select #{COLUMNS} from metadata_changes #{where.empty? ? "" : "where " + where.join(" and ")} order by id desc limit ?"
      list = [] of Entry
      @db.query_each(sql, args: args) { |rs| list << read(rs) }
      list
    end

    def active(book_id : Int64) : Array(Entry)
      list(book_id, reverted: false, limit: 10_000)
    end

    def reverted!(id : Int64)
      @db.exec "update metadata_changes set reverted_at = ? where id = ?", Time.utc.to_unix, id
    end

    def changed_books : Int64
      @db.query_one("select count(distinct book_id) from metadata_changes where reverted_at is null", as: Int64)
    end

    # author names an online source confirmed; they win the unification
    def sourced_authors : Set(String)
      set = Set(String).new
      @db.query_each("select new from metadata_changes where field = 'authors' and source in ('hardcover', 'openlibrary', 'dnb') and reverted_at is null") do |rs|
        JSON.parse(rs.read(String)).as_a?.try &.each { |a| a.as_s?.try { |s| set << s } }
      end
      set
    end

    def status(book_id : Int64) : String?
      @db.query_one?("select status from metadata_books where book_id = ?", book_id, as: String)
    end

    def set_status(book_id : Int64, status : String, job_id : String? = nil)
      @db.exec "insert or replace into metadata_books (book_id, status, at, job_id) values (?, ?, ?, ?)",
        book_id, status, Time.utc.to_unix, job_id
    end

    # checked within RECHECK with nothing left to retry
    def settled?(book_id : Int64, now = Time.utc) : Bool
      @db.query_one?("select 1 from metadata_books where book_id = ? and status = 'done' and at > ?",
        book_id, (now - RECHECK).to_unix, as: Int64) != nil
    end

    private def read(rs) : Entry
      id, book_id, field, old, new, source, job_id, at, reverted = rs.read(Int64, Int64, String, String, String, String, String?, Int64, Int64?)
      Entry.new(id, book_id, field, JSON.parse(old), JSON.parse(new), source, job_id, Time.unix(at), reverted.try { |r| Time.unix(r) })
    end
  end

  # The alert command (CALIBRE_HUB_ALERT_COMMAND, called with subject and
  # text), each key at most once a day; the last time per key is kept in
  # the state DB, so a restart doesn't repeat it
  class DailyAlert
    def initialize(@db : DB::Database, @command : Array(String)?)
      @db.exec "create table if not exists alerts (key text primary key, at integer not null)"
    end

    # false when the key was sent within the last day, or sending failed
    # (then the next call tries again instead of keeping quiet for a day)
    def call(key : String, subject : String, text : String, now = Time.utc) : Bool
      last = @db.query_one?("select at from alerts where key = ?", key, as: Int64)
      return false if last && now.to_unix - last < 1.day.total_seconds
      STDERR.puts "alert: #{subject}: #{text}"
      return false unless Alert.run(@command, subject, text)
      @db.exec "insert or replace into alerts (key, at) values (?, ?)", key, now.to_unix
      true
    rescue ex : DB::Error
      STDERR.puts "alert failed: #{ex.message}"
      false
    end

    def proc : Meta::Hardcover::Alert
      ->(key : String, subject : String, text : String) { call(key, subject, text); nil }
    end
  end

  # Completes and cleans up a book's metadata: file -> rules (model only
  # when they can't decide) -> online sources (ISBN first, then title and
  # author: Hardcover for English books, the DNB for German ones, Open
  # Library as the supplement) -> scored and checked candidates (no
  # translation, other language or volume) -> per-field merge (Meta::Merge)
  # -> one PATCH with lastModified -> change log and the tag auto-metadaten.
  class Metadata
    SOURCES = %w(file hardcover dnb openlibrary)

    MODEL_SYSTEM = <<-TXT
      You clean up the title and author fields of an e-book whose metadata
      came from its file name, e.g. "Tolkien - Der Herr der Ringe (z-lib.org)".
      Return the book's real title (no subtitle, file junk, years or series
      numbers), its authors written "First Last", and the series and number
      only if the input names one. Use only words from the input, never add
      or translate any. Answer only with JSON:
      {"title": "...", "authors": ["..."], "series": "", "seriesIndex": null}
      TXT

    alias FileReader = Proc(Book, Meta::FileMeta::Info?)

    getter log : MetaLog
    getter sources : Array(String)
    # HH:MM of the nightly run, for the status
    getter nightly : String?

    def initialize(@calibre : Calibre, @writer : Writer, @log : MetaLog, @sources : Array(String),
                   @openlibrary : Meta::OpenLibrary?, @dnb : Meta::Dnb?, @http : Meta::Http,
                   @ollama : Ollama? = nil, @read_file : FileReader? = nil, @nightly : String? = nil,
                   @hardcover : Meta::Hardcover? = nil)
    end

    # the sources asked: Hardcover only with a token
    def active_sources : Array(String)
      @sources.reject { |s| s == "hardcover" && !@hardcover.try(&.enabled?) }
    end

    def model : String?
      @ollama.try(&.model)
    end

    # Downloads EPUB (else PDF) through calibre-server and reads it
    def file_info(book : Book) : Meta::FileMeta::Info?
      return nil unless @sources.includes?("file")
      if r = @read_file
        return r.call(book)
      end
      fmt = %w(EPUB PDF).find { |f| book.formats.includes?(f) } || return nil
      dir = File.tempname("meta")
      Dir.mkdir(dir)
      begin
        path = File.join(dir, "book.#{fmt.downcase}")
        File.open(path, "w") do |io|
          @calibre.forward("GET", "/get/#{fmt.downcase}/#{book.id}") do |r|
            return nil unless r.success?
            IO.copy(r.body_io, io)
          end
        end
        Meta::FileMeta.read(path, fmt)
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    # The rules' readings, the model's first when the rules can't decide
    def guesses(book : Book) : Array(Meta::Guess)
      gs, ambiguous = Meta::Clean.guesses(book.title, book.authors, book.pubdate.try(&.year))
      if ambiguous && (m = @ollama)
        begin
          ask_model(m, book).try { |g| gs = [g] + gs.reject { |x| x.title == g.title && x.authors == g.authors } }
        rescue ex : Ollama::Unavailable | Classifier::BadAnswer
          STDERR.puts "metadata: model not asked about #{book.id}: #{ex.message}"
        end
      end
      gs
    end

    # Only title and authors go to the model. Its answer is used only when
    # every word in it was in the input.
    def ask_model(ollama : Ollama, book : Book) : Meta::Guess?
      input = "Title: #{book.title}\nAuthors: #{book.authors.join(", ")}"
      schema = JSON.parse({
        type:       "object",
        properties: {
          title:       {type: "string"},
          authors:     {type: "array", items: {type: "string"}},
          series:      {type: "string"},
          seriesIndex: {type: ["number", "null"]},
        },
        required: %w(title authors),
      }.to_json)
      content = ollama.chat([{"role" => "system", "content" => MODEL_SYSTEM}, {"role" => "user", "content" => input}], schema)
      Metadata.model_guess(content, input)
    end

    def self.model_guess(content : String, input : String) : Meta::Guess?
      json = JSON.parse(content) rescue raise Classifier::BadAnswer.new("no JSON: #{content[0, 100]}")
      title = json["title"]?.try(&.as_s?).try(&.strip).presence || raise Classifier::BadAnswer.new("title missing")
      authors = json["authors"]?.try(&.as_a?).try(&.compact_map(&.as_s?.try(&.strip).presence)) || [] of String
      series = json["series"]?.try(&.as_s?).try(&.strip).presence
      index = json["seriesIndex"]?.try { |v| v.as_f? || v.as_i64?.try(&.to_f) }
      words = Meta::Text.tokens(input).to_set
      used = Meta::Text.tokens(([title, series].compact + authors).join(' '))
      return nil unless used.all? { |w| words.includes?(w) }
      Meta::Guess.new(Meta::Clean.fix_title_case(title), Meta::Clean.authors(authors), series, series ? index : nil, source: "model")
    end

    # in @sources order; Hardcover only with a token
    private def providers : Array({String, Meta::OpenLibrary | Meta::Dnb | Meta::Hardcover})
      list = [] of {String, Meta::OpenLibrary | Meta::Dnb | Meta::Hardcover}
      @sources.each do |s|
        case s
        when "hardcover"   then @hardcover.try { |p| list << {s, p} if p.enabled? }
        when "openlibrary" then @openlibrary.try { |p| list << {s, p} }
        when "dnb"         then @dnb.try { |p| list << {s, p} }
        end
      end
      list
    end

    # Candidates from the online sources, checked and ranked; errors: a
    # source failed. ISBNs first (calibre's, the OPF's, the text's); title
    # and author only when no ISBN gave a sure match, and each source
    # decides whether the book is one for it (Hardcover: English, DNB:
    # German). Translations, other languages and other volumes are dropped
    # (Meta::Match). q: the user's own search text.
    def lookup(book : Book, guesses : Array(Meta::Guess), info : Meta::FileMeta::Info?, q : String? = nil) : {Array(Meta::Candidate), Bool}
      trusted = [book.identifiers["isbn"]?.try { |i| Meta::Isbn.normalize(i) }, info.try(&.record.isbn)].compact.uniq
      isbns = (trusted + (info.try(&.isbns.first(3)) || [] of String)).uniq.first(4)
      languages = Meta::Lang.known(book.languages)
      languages = Meta::Lang.known(info.try(&.record.languages) || [] of String) if languages.empty?
      title = guesses.first?.try(&.title).presence || book.title
      check = ->(list : Array(Meta::Candidate)) do
        list.reject do |c|
          reason = Meta::Match.reject(c, languages, title, trusted)
          STDERR.puts "metadata: #{book.id}: #{c.source} #{c.url} dropped (#{reason})" if reason
          reason
        end
      end
      all = [] of Meta::Candidate
      errors = false
      ask = ->(block : Proc(Array(Meta::Candidate))) do
        begin
          all.concat block.call
        rescue ex : Meta::SourceError | JSON::ParseException | XML::Error
          STDERR.puts "metadata: #{ex.message}"
          errors = true
        end
      end
      unless q
        isbns.each { |isbn| providers.each { |_, p| ask.call(-> { p.by_isbn(isbn) }) } }
      end
      all = check.call(all)
      ranked = Meta::Score.rank(all, guesses, languages, trusted)
      unless ranked.any?(&.sure)
        searches = q ? [Meta::Guess.new(q, [] of String)] : guesses.first(2)
        searches.each do |g|
          next if g.title.empty?
          author = g.authors.first? || (q ? guesses.first?.try(&.authors.first?) : nil)
          query = Meta::Query.new(g.title, author, languages, book.publisher || info.try(&.record.publisher))
          providers.each { |_, p| ask.call(-> { p.search(query) }) }
        end
        seen = Set(String).new
        all = check.call(all.select { |c| c.url.nil? || seen.add?("#{c.source} #{c.url}") })
        ranked = Meta::Score.rank(all, q ? searches + guesses : guesses, languages, trusted)
      end
      {ranked, errors}
    end

    # Descriptions, languages, series of the accepted Open Library candidates
    private def complete(candidates : Array(Meta::Candidate), book : Book)
      return unless book.comments.nil? || book.languages.empty? || book.series.nil?
      ol = @openlibrary || return
      candidates.select { |c| c.source == Meta::OpenLibrary::NAME && (c.sure || c.score >= Meta::ACCEPT) }.first(1).each do |c|
        ol.complete(c)
      rescue ex : Meta::SourceError | JSON::ParseException
        STDERR.puts "metadata: #{ex.message}"
      end
    end

    # For the edit form's "Metadaten holen": the cleaned names, the file
    # and the online candidates, best first
    def candidates(id : Int64, q : String? = nil) : Array(Meta::Candidate)
      book = @calibre.book(id) || raise Writer::NotFound.new
      info = file_info(book)
      # a standard: the rules know, the online sources don't have them
      if norm = Meta::Norms.parse(book, info.try(&.cover))
        return [Meta::Candidate.new("rules", norm.record).tap { |c| c.score = 1.0 }]
      end
      gs = guesses(book)
      list, _ = lookup(book, gs, info, q.presence)
      complete(list, book)
      out = [] of Meta::Candidate
      g = gs.first
      if g.title != book.title || (g.authors != book.authors && !g.authors.empty?) || g.series
        r = Meta::Record.new(title: g.title, authors: g.authors.empty? ? nil : g.authors, series: g.series, series_index: g.series_index)
        out << Meta::Candidate.new(g.source, r).tap { |c| c.score = 1.0 }
      end
      if info
        out << Meta::Candidate.new("file", info.record).tap { |c| c.score = 1.0 }
      end
      out + list.first(10)
    end

    # One book: plan and apply. Returns the logged changes.
    def run(id : Int64, job_id : String? = nil) : Array(MetaLog::Entry)
      book = @calibre.book(id) || raise Writer::NotFound.new
      info = file_info(book)
      if norm = Meta::Norms.parse(book, info.try(&.cover))
        entries = run_norm(book, norm, job_id)
        @log.set_status(id, "done", job_id)
        return entries
      end
      gs = guesses(book)
      candidates, errors = lookup(book, gs, info)
      complete(candidates, book)
      changes = Meta::Merge.plan(book, gs.first?, info.try(&.record), candidates, @calibre.has_cover?(id))
      entries = apply(book, changes, job_id)
      @log.set_status(id, errors ? "retry" : "done", job_id)
      entries
    end

    # A standard: its fields by the rules (Meta::Norms), no online source.
    # The other editions in the library decide "ersetzt": this one gets it
    # when a newer edition is there, older ones get it from this one.
    def run_norm(book : Book, norm : Meta::Norms::Norm, job_id : String?) : Array(MetaLog::Entry)
      editions = editions(book, norm)
      entries = apply(book, Meta::Norms.plan(book, norm, Meta::Norms.replaced?(norm, editions.map(&.[1]))), job_id)
      editions.each do |other, n|
        next unless Meta::Norms.replaced?(n, [norm])
        change = Meta::Norms.replace(other) || next
        begin
          apply(other, [change], job_id)
        rescue Writer::Conflict
          # changed meanwhile: its own run tags it
        end
      end
      entries
    end

    # The other books with the same designation, as standards
    def editions(book : Book, norm : Meta::Norms::Norm) : Array({Book, Meta::Norms::Norm})
      number = norm.number
      ids = @calibre.search(%(title:"#{Api.escape(number)}"), "id", true, 0, 1000).ids - [book.id]
      @calibre.books(ids, Calibre::DETAIL_FIELDS).compact_map do |b|
        n = Meta::Norms.parse(b) || next
        {b, n} if n.designation == norm.designation
      end
    end

    # One PATCH (lastModified: a book changed meanwhile is a Conflict) plus
    # the cover, then the log. The tag marks every changed book.
    def apply(book : Book, changes : Array(Meta::Change), job_id : String?) : Array(MetaLog::Entry)
      cover = nil
      if c = changes.find { |x| x.field == "cover" }
        cover = begin
          c.new.as_s?.try { |u| @http.image(u) }.try { |d| {"jpeg", "png"}.includes?(Covers.image_type(d)) ? d : nil }
        rescue ex : Meta::SourceError
          STDERR.puts "metadata: cover: #{ex.message}"
          nil
        end
      end
      fields = changes.reject { |x| x.field == "cover" }
      return [] of MetaLog::Entry if fields.empty? && cover.nil?
      body = Meta::Merge.patch(book, fields.to_h { |x| {x.field, x.new} })
      body["lastModified"] = JSON::Any.new(book.version)
      Meta::Merge.tags(body, "addTags", [Meta::TAG])
      updated = @writer.update(book.id, body)
      entries = fields.compact_map do |x|
        now = Meta::Merge.value(updated, x.field)
        next if Meta::Merge.same?(x.field, x.old, now)
        @log.add(book.id, x.field, x.old, now, x.source, job_id)
      end
      if (data = cover) && (c = changes.find { |x| x.field == "cover" })
        @writer.set_cover(book.id, data)
        entries << @log.add(book.id, "cover", JSON::Any.new(nil), c.new, c.source, job_id)
      end
      if entries.empty?
        # calibre normalized everything back: nothing changed, no tag
        @writer.update(book.id, {"removeTags" => JSON.parse([Meta::TAG].to_json)}) if @log.active(book.id).empty?
      end
      entries
    end

    # Sets the old value again, if the field still has the logged new one
    # (else Conflict). The last change of a book takes the tag away.
    def revert(change_id : Int64) : {MetaLog::Entry, Book}
      e = @log[change_id]? || raise Writer::NotFound.new
      book = @calibre.book(e.book_id) || raise Writer::NotFound.new
      raise Writer::Conflict.new(book) if e.reverted_at
      last = @log.active(book.id).all? { |x| x.id == e.id }
      body = {} of String => JSON::Any
      if e.field == "cover"
        @calibre.set_fields(book.id, {"cover" => JSON::Any.new(nil), "last_modified" => JSON::Any.new(Time.utc.to_rfc3339(fraction_digits: 6))})
        @writer.written([book.id])
        book = @calibre.book(book.id) || raise Writer::NotFound.new
      else
        raise Writer::Conflict.new(book) unless Meta::Merge.same?(e.field, Meta::Merge.value(book, e.field), e.new)
        body = Meta::Merge.patch(book, {e.field => e.old})
        # an author sort that was empty can't be set empty again; calibre's own is next best
        body["authorSort"] = JSON::Any.new(Meta::AuthorSort.for(book.authors)) if e.field == "authorSort" && e.old.raw.nil?
      end
      Meta::Merge.tags(body, "removeTags", [Meta::TAG]) if last
      body["lastModified"] = JSON::Any.new(book.version) unless body.empty?
      book = @writer.update(book.id, body) unless body.empty?
      @log.reverted!(e.id)
      {@log[e.id]?.not_nil!, book}
    end

    # Ids of all active changes of the books, newest first
    def revert_books(ids : Array(Int64)) : Array(Int64)
      ids.flat_map { |id| @log.active(id).map(&.id) }
    end

    # Library-wide: author names that differ only in spelling become the
    # most common (or source-confirmed) one, book by book, logged
    def unify_authors(job_id : String? = nil) : Int32
      counts = (@calibre.categories["authors"]? || [] of NamedTuple(name: String, count: Int32)).to_h { |a| {a[:name], a[:count]} }
      changed = 0
      Meta::Authors.groups(counts, @log.sourced_authors).each do |canonical, variants|
        variants.each do |variant|
          ids = @calibre.search(%(authors:"=#{Api.escape(variant)}"), "id", true, 0, 1_000_000).ids
          ids.each do |id|
            2.times do |attempt|
              book = @calibre.book(id) || break
              break unless book.authors.includes?(variant)
              authors = book.authors.map { |a| a == variant ? canonical : a }.uniq
              change = Meta::Change.new("authors", JSON.parse(book.authors.to_json), JSON.parse(authors.to_json), "authors")
              changed += 1 unless apply(book, [change], job_id).empty?
              break
            rescue Writer::Conflict
              raise Writer::Conflict.new(@calibre.book(id).not_nil!) if attempt == 1
            end
          end
        end
      end
      changed
    end

    # Missing fields or messy names; books checked in the last 30 days
    # without anything left to retry are left out
    def incomplete : Array(Int64)
      @calibre.list("", Calibre::DETAIL_FIELDS).select do |b|
        next false if @log.settled?(b.id)
        b.identifiers["isbn"]?.nil? || b.publisher.nil? || b.pubdate.nil? || b.languages.empty? ||
          b.comments.nil? || Meta::Clean.messy?(b) || Meta::AuthorSort.wrong?(b)
      end.map(&.id)
    end
  end

  # Metadata runs, a queue of their own. A run over books can end with the
  # library-wide author pass: that step is the id 0 at the end of the job.
  class MetadataJobs < Jobs
    AUTHORS = 0_i64
    # an added book waits this long at most for its metadata run before it
    # is classified anyway
    CLASSIFY_WAIT = 30.minutes

    getter metadata : Metadata

    def initialize(db : DB::Database, calibre : Calibre, writer : Writer, @metadata : Metadata)
      super(db, calibre, writer, nil, "metadata_jobs")
    end

    # target: "incomplete" (default), "all", "authors", {ids} or {query}
    def submit_target(target : JSON::Any?) : Job
      return enqueue_books(@metadata.incomplete, true, "incomplete") if target.nil? || target.raw.nil?
      if s = target.as_s?
        case s
        when "incomplete" then return enqueue_books(@metadata.incomplete, true, s)
        when "all"        then return enqueue_books(@calibre.search("", "id", true, 0, 1_000_000).ids, true, s)
        when "authors"    then return enqueue_books([] of Int64, true, s)
        end
      end
      h = target.as_h? || raise Edit::Invalid.new("target", "incomplete, all, authors, {ids} or {query} expected")
      enqueue_books(ids(target), false, h.has_key?("ids") ? "ids" : "query")
    end

    def enqueue_books(ids : Array(Int64), authors : Bool, target : String) : Job
      ids.each { |id| @metadata.log.set_status(id, "queued") unless @metadata.log.status(id) == "queued" }
      enqueue(authors ? ids + [AUTHORS] : ids, {"target" => JSON::Any.new(target)})
    end

    def target(job : Job) : String
      job.changes["target"]?.try(&.as_s?) || ""
    end

    # Nightly run over the incomplete books at HH:MM local time
    def schedule(at : String)
      spawn do
        last = Time.local
        loop do
          sleep 30.seconds
          next unless CalibreHub.reconcile_due?(at, last)
          last = Time.local
          begin
            next if running?
            job = submit_target(JSON::Any.new("incomplete"))
            puts "metadata: nightly run #{job.id} over #{job.total - 1} books"
          rescue ex
            STDERR.puts "metadata: nightly run not started: #{ex.message}"
          end
        end
      end
    end

    # Books added get a metadata run: follows the event table with a
    # cursor of its own (meta metadata_event_seq)
    def watch_events(interval = 10.seconds)
      if cursor.nil?
        max = @db.query_one("select coalesce(max(id), 0) from events", as: Int64)
        @db.exec "insert or replace into meta (key, value) values ('metadata_event_seq', ?)", max.to_s
      end
      spawn do
        loop do
          begin
            follow_events
          rescue ex
            STDERR.puts "metadata: events: #{ex.message}"
          end
          sleep interval
        end
      end
    end

    def cursor : Int64?
      @db.query_one?("select value from meta where key = 'metadata_event_seq'", as: String).try(&.to_i64)
    end

    def follow_events
      return if Backlog.paused?(@db)
      from = cursor || 0_i64
      ids = [] of Int64
      last = from
      @db.query_each("select id, type, book_id from events where id > ? order by id limit 500", from) do |rs|
        last, type, book_id = rs.read(Int64, String, Int64)
        ids << book_id if type == "added"
      end
      return if last == from
      unless ids.empty?
        job = enqueue_books(ids.uniq, false, "added")
        puts "metadata: job #{job.id} for #{job.total} new books"
      end
      @db.exec "update meta set value = ? where key = 'metadata_event_seq'", last.to_s
    end

    # Classification of a new book waits until its metadata run is done or
    # failed (or took too long)
    def ready_for_classify?(event_id : Int64, book_id : Int64, created_at : Time) : Bool
      return true if Time.utc - created_at > CLASSIFY_WAIT
      (cursor || 0_i64) >= event_id && @metadata.log.status(book_id) != "queued"
    end

    # The book changed again while the sources were asked
    class Retry < Exception
    end

    protected def apply(job : Job, index : Int32, id : Int64, resumed : Bool)
      if id == AUTHORS
        n = @metadata.unify_authors(job.id)
        puts "metadata: job #{job.id}: #{n} books with unified author names" if n > 0
        return
      end
      begin
        @metadata.run(id, job.id)
      rescue Writer::Conflict
        # changed while the sources were asked: once more with the new state
        begin
          @metadata.run(id, job.id)
        rescue Writer::Conflict
          @metadata.log.set_status(id, "retry", job.id)
          raise Retry.new("changed in the meantime, tried again on the next run")
        end
      end
    rescue ex : Calibre::Unavailable
      raise Abort.new(ex.message)
    rescue ex : Retry
      raise ex
    rescue ex
      @metadata.log.set_status(id, ex.is_a?(Writer::NotFound) ? "done" : "failed", job.id) unless id == AUTHORS
      raise ex
    end
  end
end
