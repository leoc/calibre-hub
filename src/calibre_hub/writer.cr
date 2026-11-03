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
    # a cover was set; covers don't show in events (only lastModified changes)
    property on_cover : Proc(Int64, Nil)?
    # books an uploaded one looks like a duplicate of (duplicates.cr)
    property similar : Proc(Int64, Array(Book))?

    def initialize(@calibre : Calibre, @detector : Detector?, @wake : Channel(Nil)?,
                   @category_column : String?)
    end

    # The book as calibre has it now (bulk jobs read it before a change, for undo)
    def book(id : Int64) : Book?
      @calibre.book(id)
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

    # Moves the book to calibre's trash; returns its last state
    def delete(id : Int64) : Book
      book = @calibre.book(id) || raise NotFound.new
      @calibre.remove([id])
      written([id])
      book
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

    # Runs ids the hub just wrote through the detector and wakes the dispatcher
    def written(ids : Array(Int64))
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
  # Bulk edits run as background jobs, one after another, in the order they
  # were submitted. Jobs live in the state DB, which is also the queue: a job
  # still running when the hub stopped is resumed on start with the book it
  # was at. Re-applying that book is harmless, every bulk change is
  # idempotent per book.
  #
  # Field changes remember each book's values before the change ("before")
  # and what they set ("after"), so POST /api/jobs/:id/undo can put them
  # back with a job of its own, but only where a field still has the value
  # the job set: a later change stays (and is named in the undo's errors).
  # Tags go back as a difference: the tags the job added are removed, the
  # ones it removed added, others stay.
  class Jobs
    CHANGES = %w(addTags removeTags kategorie series numberSeries authors publisher languages rating pubdate pubYear delete)
    # finished jobs kept for GET /api/jobs/:id
    KEEP = 50

    # Raised while applying a book: stops the whole job as failed, e.g. when
    # a service it needs is down
    class Abort < Exception
    end

    class Job
      include JSON::Serializable

      getter id : String
      property status : String = "running"
      property done : Int32 = 0
      getter total : Int32
      getter errors = [] of NamedTuple(bookId: Int64, error: String)
      # why the job stopped early (Abort)
      property error : String?
      @[JSON::Field(ignore: true)]
      getter ids : Array(Int64)
      @[JSON::Field(ignore: true)]
      getter changes : Hash(String, JSON::Any)
      # book id => its fields before the change, as PATCH fields (undo)
      @[JSON::Field(ignore: true)]
      getter before : Hash(String, Hash(String, JSON::Any))
      # book id => the same fields right after the change (undo checks them)
      @[JSON::Field(ignore: true)]
      getter after : Hash(String, Hash(String, JSON::Any))

      def initialize(@ids, @changes, @id = Random::Secure.hex(8), @status = "running", @done = 0,
                     @errors = [] of NamedTuple(bookId: Int64, error: String), @error = nil,
                     @before = {} of String => Hash(String, JSON::Any),
                     @after = {} of String => Hash(String, JSON::Any))
        @total = @ids.size
      end

      # The changes for the book at index i: numberSeries becomes that
      # book's seriesIndex (1..n in the order of the ids); an undo job puts
      # back each book's own values
      def changes_for(index : Int32) : Hash(String, JSON::Any)
        if restore = @changes["restore"]?.try(&.as_h?)
          return restore[@ids[index].to_s]?.try(&.as_h?) || {} of String => JSON::Any
        end
        return @changes unless @changes["numberSeries"]?.try(&.as_bool?)
        c = @changes.dup
        c.delete("numberSeries")
        c["seriesIndex"] = JSON::Any.new((index + 1).to_i64)
        c
      end
    end

    COLUMNS = "id, status, done, ids, changes, errors, error, before, after"
    # an undo left a field that changed after the job (not a failure)
    SKIPPED = "changed since, left as it is: "

    # book ids of a reading list for {query: {list: id}} or {query:
    # {listPath: "A/B"}} (with direct, listOwner: Api.list_members); raises
    # when the list is unknown
    property list_members : Proc(HTTP::Params, Array(Int64))?
    # for {query: {kategorie: …}} targets of queues that don't edit fields
    setter category_column : String?

    # table: the queue, one per kind of job (jobs run one after another
    # within a queue, queues in parallel)
    def initialize(@db : DB::Database, @calibre : Calibre, @writer : Writer, @category_column : String?,
                   @table = "jobs")
      @db.exec <<-SQL
        create table if not exists #{@table} (
          id text primary key,
          status text not null,
          done integer not null default 0,
          ids text not null,
          changes text not null,
          errors text not null default '[]',
          created_at integer not null,
          error text
        )
        SQL
      columns = [] of String
      @db.query_each("select name from pragma_table_info('#{@table}')") { |rs| columns << rs.read(String) }
      @db.exec "alter table #{@table} add column error text" unless columns.includes?("error")
      @db.exec "alter table #{@table} add column before text not null default '{}'" unless columns.includes?("before")
      # running when the hub (re)started: interrupted, maybe by a crash on
      # the book they were at
      @interrupted = Set(String).new
      @db.query_each("select id from #{@table} where status = 'running'") { |rs| @interrupted << rs.read(String) }
      @db.exec "alter table #{@table} add column after text not null default '{}'" unless columns.includes?("after")
      @wake = Channel(Nil).new(1)
      spawn { work }
    end

    def []?(id : String) : Job?
      @db.query_one?("select #{COLUMNS} from #{@table} where id = ?", id) do |rs|
        Jobs.read(rs)
      end
    end

    # Most recent job with its start time
    def last : {Job, Time}?
      @db.query_one?("select #{COLUMNS}, created_at from #{@table} order by created_at desc, rowid desc limit 1") do |rs|
        {Jobs.read(rs), Time.unix(rs.read(Int64))}
      end
    end

    def running? : Bool
      !@db.query_one?("select 1 from #{@table} where status = 'running' limit 1", as: Int64).nil?
    end

    # body: {target: {ids: [...]} | {query: {...}}, changes: {...}}
    def submit(body : Hash(String, JSON::Any)) : Job
      changes = body["changes"]?.try(&.as_h?) || raise Edit::Invalid.new("changes", "object expected")
      raise Edit::Invalid.new("changes", "nothing to change") if changes.empty?
      if bad = changes.keys.find { |k| !CHANGES.includes?(k) }
        raise Edit::Invalid.new(bad, "not allowed in bulk edits")
      end
      if changes.has_key?("delete")
        # moves the books to calibre's trash; not combined with edits
        raise Edit::Invalid.new("delete", "must be true and the only change") unless changes.size == 1 && changes["delete"].as_bool? == true
      else
        if number = changes.delete("numberSeries")
          raise Edit::Invalid.new("numberSeries", "true or false expected") if number.as_bool?.nil?
          if number.as_bool
            raise Edit::Invalid.new("numberSeries", "needs a series") unless changes["series"]?.try(&.as_s?).try(&.strip.presence)
            raise Edit::Invalid.new("numberSeries", "needs a list of ids, their order is the numbering") unless body["target"]?.try(&.as_h?).try(&.["ids"]?)
            changes["numberSeries"] = number
          end
          raise Edit::Invalid.new("changes", "nothing to change") if changes.empty?
        end
        if year = changes["pubYear"]?
          raise Edit::Invalid.new("pubYear", "only one of pubdate and pubYear") if changes.has_key?("pubdate")
          y = year.raw.nil? ? nil : (year.as_i64? || raise Edit::Invalid.new("pubYear", "year expected"))
          raise Edit::Invalid.new("pubYear", "year from 1 to 9999 expected") if y && !(1 <= y <= 9999)
        end
        # type errors now rather than once per book
        Edit.changes(changes.dup.tap(&.delete("numberSeries")).tap(&.delete("pubYear")), Jobs.blank, @category_column)
      end
      # moving a query's books to the trash: only as many as the client
      # confirmed
      enqueue(ids(body["target"]?, need_expect: changes.has_key?("delete")), changes)
    end

    protected def enqueue(ids : Array(Int64), changes : Hash(String, JSON::Any)) : Job
      job = Job.new(ids, changes)
      @db.exec "insert into #{@table} (id, status, done, ids, changes, created_at) values (?, ?, 0, ?, ?, ?)",
        job.id, job.status, job.ids.to_json, job.changes.to_json, Time.utc.to_unix
      select
      when @wake.send(nil)
      else
      end
      job
    end

    # the filters a {query} target may have (those of GET /api/books
    # without paging and sorting)
    QUERY_KEYS = %w(q kategorie tag author series list listPath listOwner direct)

    # The count a {query} target resolved to differs from the one the client
    # showed (expect): the library changed, or the query isn't what it meant
    class CountMismatch < Exception
      getter expected : Int64
      getter found : Int32

      def initialize(@expected, @found)
        super("the query matches #{@found} books, not #{@expected}")
      end
    end

    # target: {ids: [...]} or {query: {...}, all?: true, expect?: n}.
    # A query never falls back to the whole library by accident: unknown
    # filters are refused, a query without filters needs all: true, and
    # with expect the number of books it matches must be that one
    # (need_expect: required, e.g. to delete).
    def ids(target : JSON::Any?, need_expect = false) : Array(Int64)
      t = target.try(&.as_h?) || raise Edit::Invalid.new("target", "object expected")
      if list = t["ids"]?
        (list.as_a? || raise Edit::Invalid.new("target", "ids must be a list")).map do |v|
          v.as_i64? || raise Edit::Invalid.new("target", "ids must be numbers")
        end.uniq
      elsif query = t["query"]?.try(&.as_h?)
        expect = t["expect"]?.try { |e| e.as_i64? || raise Edit::Invalid.new("target", "expect must be a number") }
        raise Edit::Invalid.new("target", "expect (the number of books meant) required") if need_expect && expect.nil?
        all = t["all"]?.try { |a| a.as_bool?.tap { |b| raise Edit::Invalid.new("target", "all must be true or false") if b.nil? } } || false
        params = HTTP::Params.new
        query.each do |k, v|
          raise Edit::Invalid.new("target", "offset/limit not allowed") if {"offset", "limit", "sort", "order"}.includes?(k)
          raise Edit::Invalid.new("target", "unknown filter #{k}") unless QUERY_KEYS.includes?(k)
          next if v.raw.nil?
          (v.as_a? || [v]).each { |x| params.add(k, x.as_s? || x.to_s) }
        end
        if params["kategorie"]?.presence && @category_column.nil?
          raise Edit::Invalid.new("target", "kategorie: no category column configured")
        end
        ids = query_ids(params, all)
        raise CountMismatch.new(expect, ids.size) if expect && ids.size != expect
        ids
      else
        raise Edit::Invalid.new("target", "ids or query expected")
      end
    end

    private def query_ids(params : HTTP::Params, all : Bool) : Array(Int64)
      q = Api.query(params, @category_column)
      # the books of a reading list, filtered further by the rest
      if Api.list_query?(params)
        raise Edit::Invalid.new("target", "unknown list") if (l = params["list"]?.presence) && l.to_i64?.nil?
        members = list_members.try(&.call(params)) || raise Edit::Invalid.new("target", "unknown list")
        return members if q.empty?
        found = @calibre.search(q, "id", true, 0, 1_000_000).ids.to_set
        return members.select { |id| found.includes?(id) }
      end
      raise Edit::Invalid.new("target", "the query has no filter and would match every book; send all: true to mean that") if q.empty? && !all
      @calibre.search(q, "id", true, 0, 1_000_000).ids
    end

    # Runs queued jobs, oldest first, then waits for the next submit
    private def work
      loop do
        begin
          while job = next_job
            STDERR.puts "resuming job #{job.id} at #{job.done}/#{job.total}" if job.done > 0
            run(job)
          end
        rescue ex
          # the state DB failed; try again later instead of spinning
          STDERR.puts "#{@table}: #{ex.message}"
          sleep 10.seconds
          next
        end
        @wake.receive
      end
    end

    private def next_job : Job?
      @db.query_one?("select #{COLUMNS} from #{@table} where status = 'running' order by created_at, rowid limit 1") do |rs|
        Jobs.read(rs)
      end
    end

    # what a book of an interrupted job is marked with while it is tried
    # again; still there at the next start, the hub died on it twice
    INTERRUPTED = "the hub stopped while on this book"

    # Progress is saved after every book. The book an interrupted job was at
    # gets one more try; if the hub dies on it again (a file that crashes
    # it), the next start skips it as failed instead of looping.
    private def run(job : Job)
      begin
        job = prepare(job)
      rescue ex
        job.status = "failed"
        job.error = ex.message || ex.class.name
        STDERR.puts "#{@table}: job #{job.id} failed before its first book: #{job.error}"
        @db.exec "update #{@table} set status = ?, error = ? where id = ?", job.status, job.error, job.id
        return
      end
      interrupted = @interrupted.delete(job.id)
      resumed_at = job.done > 0 || interrupted ? job.done : nil
      (job.done...job.total).each do |i|
        id = job.ids[i]
        marker = {bookId: id, error: INTERRUPTED}
        if i == resumed_at && interrupted
          if job.errors.includes?(marker)
            STDERR.puts "#{@table}: job #{job.id} skips book #{id}, the hub stopped on it twice"
            job.done = i + 1
            @db.exec "update #{@table} set done = ?, errors = ? where id = ?", job.done, job.errors.to_json, job.id
            next
          end
          job.errors << marker
          @db.exec "update #{@table} set errors = ? where id = ?", job.errors.to_json, job.id
        end
        begin
          apply(job, i, id, i == resumed_at)
        rescue ex : Abort
          job.errors.delete(marker)
          job.error = ex.message
          STDERR.puts "#{@table}: job #{job.id} stopped at #{job.done}/#{job.total}: #{ex.message}"
          break
        rescue Writer::NotFound
          job.errors << {bookId: id, error: "not found"}
        rescue ex
          job.errors << {bookId: id, error: ex.message || ex.class.name}
        end
        job.errors.delete(marker)
        job.done = i + 1
        @db.exec "update #{@table} set done = ?, errors = ?, before = ?, after = ? where id = ?",
          job.done, job.errors.to_json, job.before.to_json, job.after.to_json, job.id
      end
      failed = job.errors.reject(&.[:error].starts_with?(SKIPPED)).map(&.[:bookId]).uniq.size
      job.status = (job.error || (failed == job.total && job.total > 0)) ? "failed" : "done"
      @db.exec "update #{@table} set status = ?, error = ? where id = ?", job.status, job.error, job.id
      @db.exec <<-SQL, KEEP
        delete from #{@table} where status != 'running' and rowid not in (
          select rowid from #{@table} where status != 'running' order by created_at desc, rowid desc limit ?)
        SQL
    end

    # Work a job does before its books (e.g. finding them); returns the
    # job with its ids. An exception stops the job as failed.
    protected def prepare(job : Job) : Job
      job
    end

    # One book of a job; resumed: the book the job was at when the hub stopped
    protected def apply(job : Job, index : Int32, id : Int64, resumed : Bool)
      if job.changes.has_key?("delete")
        begin
          @writer.delete(id)
        rescue ex : Writer::NotFound
          # deleted just before the hub stopped, progress not saved yet
          raise ex unless resumed
        end
      elsif job.changes.has_key?("restore")
        before = job.changes_for(index)
        return if before.empty?
        current = @writer.book(id) || raise Writer::NotFound.new
        set = job.changes["expect"]?.try(&.as_h?).try(&.[id.to_s]?).try(&.as_h?)
        body, skipped = Jobs.revert(before, set, current, @category_column)
        job.errors << {bookId: id, error: SKIPPED + skipped.join(", ")} unless skipped.empty? || (resumed && job.errors.any? { |e| e[:bookId] == id })
        @writer.update(id, body) unless body.empty?
      else
        changes = job.changes_for(index)
        return if changes.empty?
        current = @writer.book(id) || raise Writer::NotFound.new
        # resumed: the values read then may be ours already
        job.before[id.to_s] = Jobs.before(current, changes, @category_column) unless resumed && job.before.has_key?(id.to_s)
        updated = @writer.update(id, Jobs.with_year(changes, current))
        job.after[id.to_s] = Jobs.before(updated, changes, @category_column)
      end
    end

    # The PATCH that puts back the fields of before where they still have
    # the value the job set (set; nil for a job from before that was
    # recorded: everything goes back) and the fields left because they
    # changed since. Tags go back as a difference.
    def self.revert(before : Hash(String, JSON::Any), set : Hash(String, JSON::Any)?, current : Book,
                    category_column : String?) : {Hash(String, JSON::Any), Array(String)}
      return {before, [] of String} unless set
      now = Jobs.before(current, before, category_column)
      body = {} of String => JSON::Any
      skipped = [] of String
      done = Set(String).new
      before.each_key do |key|
        next if done.includes?(key)
        case key
        when "tags"
          done << key
          old = before["tags"].as_a.map(&.as_s)
          new = set["tags"]?.try(&.as_a.map(&.as_s)) || old
          (new - old).tap { |added| body["removeTags"] = JSON.parse(added.to_json) unless added.empty? }
          (old - new).tap { |removed| body["addTags"] = JSON.parse(removed.to_json) unless removed.empty? }
        when "series", "seriesIndex"
          # one field: a series with its number
          group = {"series", "seriesIndex"}
          group.each { |k| done << k }
          if group.all? { |k| now[k]? == set[k]? }
            group.each { |k| before[k]?.try { |v| body[k] = v } }
          else
            skipped << "series"
          end
        else
          done << key
          if now[key]? == set[key]?
            body[key] = before[key]
          else
            skipped << key
          end
        end
      end
      {body, skipped}
    end

    # pubYear: the year of the publication date, keeping month and day
    def self.with_year(changes : Hash(String, JSON::Any), book : Book) : Hash(String, JSON::Any)
      year = changes["pubYear"]? || return changes
      c = changes.dup
      c.delete("pubYear")
      c["pubdate"] = year.raw.nil? ? JSON::Any.new(nil) : JSON::Any.new("%04d-%s" % {year.as_i64, book.pubdate.try(&.to_utc.to_s("%m-%d")) || "01-01"})
      c
    end

    # What a change will overwrite, as the PATCH fields that put it back
    def self.before(book : Book, changes : Hash(String, JSON::Any), category_column : String?) : Hash(String, JSON::Any)
      b = {} of String => JSON::Any
      changes.each_key do |key|
        case key
        when "addTags", "removeTags", "tags" then b["tags"] = JSON.parse(book.tags.to_json)
        when "kategorie"
          b["kategorie"] = category_column.try { |c| book.custom[c]? }.try { |v| v.as_s? ? v : nil } || JSON::Any.new(nil)
        when "series", "seriesIndex"
          b["series"] = JSON::Any.new(book.series)
          book.series_index.try { |i| b["seriesIndex"] = JSON::Any.new(i) }
        when "authors"   then b["authors"] = JSON.parse(book.authors.to_json)
        when "publisher" then b["publisher"] = JSON::Any.new(book.publisher)
        when "languages" then b["languages"] = JSON.parse(book.languages.to_json)
        when "rating"    then b["rating"] = book.rating.try { |r| JSON::Any.new(r.round.to_i64) } || JSON::Any.new(nil)
        when "pubdate", "pubYear"
          b["pubdate"] = JSON::Any.new(book.pubdate.try(&.to_utc.to_s("%Y-%m-%d")))
        end
      end
      b
    end

    class NotUndoable < Exception
    end

    # Puts back what a finished field change overwrote, as a job of its own;
    # once only
    def undo(id : String) : Job
      job = self[id]? || raise NotUndoable.new("unknown job")
      raise NotUndoable.new("still running") if job.status == "running"
      raise NotUndoable.new("nothing to undo") if job.before.empty? || job.changes.has_key?("delete")
      ids = job.ids.select { |i| job.before.has_key?(i.to_s) }
      restore = JSON::Any.new(job.before.transform_values { |h| JSON::Any.new(h) })
      changes = {"restore" => restore}
      # what the job set, to leave what changed since (missing in jobs from
      # before it was recorded)
      changes["expect"] = JSON::Any.new(job.after.transform_values { |h| JSON::Any.new(h) }) unless job.after.empty?
      @db.exec "update #{@table} set before = '{}' where id = ?", job.id
      enqueue(ids, changes)
    end

    protected def self.read(rs) : Job
      id, status, done, ids, changes, errors, error, before, after = rs.read(String, String, Int32, String, String, String, String?, String, String)
      Job.new(Array(Int64).from_json(ids), Hash(String, JSON::Any).from_json(changes), id, status, done,
        Array(NamedTuple(bookId: Int64, error: String)).from_json(errors), error,
        Hash(String, Hash(String, JSON::Any)).from_json(before), Hash(String, Hash(String, JSON::Any)).from_json(after))
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
      @on_cover.try &.call(id)
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
