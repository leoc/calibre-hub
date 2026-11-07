require "./intake"

module CalibreHub
  # The Eingang's filter „Schon in der Bibliothek“ and a look into a file.
  #
  # The proposals for books of the library stay where they are, in
  # import_repairs. Here they look like entries, by the negative
  # book id so they can't be taken for a file, and go through ImportRepair's
  # accept and reject: hand edits stay out and apply_book refuses a field
  # changed since the plan. There is no trash and no „wie in der Datei“ for a
  # book the library has.
  class Intake
    # the proposals behind the filter; without them it is empty
    property repair : ImportRepair?
    property recheck : RepairRecheck?

    # what the reader opens (frontend READER_FORMATS), in its order
    READABLE = %w(EPUB KEPUB AZW3 MOBI AZW FB2 CBZ PDF)

    # open: to decide here, so with something to write. A failed one stays to
    # say why. What writes nothing waits for a recheck (ImportRepair#recheck_list).
    LIBRARY_OPEN = "status in ('pending', 'failed') and decision is null and #{ImportRepair::WRITES}"

    private def library_sql(band : String?) : String
      [LIBRARY_OPEN, band_sql(band)].compact.join(" and ")
    end

    # Of a filter what „Alle N übernehmen“ takes: not what failed or is skipped
    private def library_takeable(band : String?) : String
      "#{library_sql(band)} and status = 'pending' and skipped = 0"
    end

    private def library_count(where : String) : Int64
      @db.query_one("select count(*) from import_repairs where #{where}", as: Int64)
    end

    private def library_left(band : String?)
      open = library_sql(band)
      {duplicates: 0_i64, failed: library_count("#{open} and status = 'failed'"),
       skipped: library_count("#{open} and status = 'pending' and skipped = 1")}
    end

    # the surest first as in #list, then by book
    LIBRARY_ORDER = "#{SURE} desc, book_id"

    # The list for the filter, as #list has it; after: the page behind this
    # place, a confidence and a book id
    def library_list(band : String? = nil, limit = 100, after : String? = nil) : JSON::Any
      repair = @repair
      repair.try(&.release)
      clause = library_sql(band)
      size = limit.clamp(1, MAX_LIMIT)
      total = repair ? library_count(clause) : 0_i64
      page = clause
      args = [] of DB::Any
      after.try do |a|
        sure, key = Intake.place(a)
        book = key.to_i64? || raise Edit::Invalid.new("after", "next of the page before expected")
        page = "#{clause} and (#{SURE} < ? or (#{SURE} = ? and book_id > ?))"
        args = [sure, sure, book] of DB::Any
      end
      rows = repair.try(&.proposals(page, args, size + 1, LIBRARY_ORDER)) || [] of ImportRepair::Proposal
      more = rows.size > size
      rows.pop if more
      books = @calibre.books(rows.map(&.book_id)).index_by(&.id)
      counts = Hash(String, Int64).new(0_i64)
      (Meta::Confidence::BANDS + ["none"]).each { |b| counts[b] = repair ? library_count(library_sql(b)) : 0_i64 }
      takeable = library_takeable(band)
      JSON.parse({enabled: true, progress: progress, total: total, counts: counts, next: more ? Intake.place(rows.last.confidence, rows.last.book_id) : nil,
                  takeable: repair ? library_count(takeable) : 0_i64,
                  unsure: repair ? library_count("#{takeable} and confidence < #{Meta::Confidence::REVIEW}") : 0_i64,
                  left: repair ? library_left(band) : {duplicates: 0_i64, failed: 0_i64, skipped: 0_i64},
                  skipped: skipped_count, last: repair ? @db.query_one("select coalesce(max(book_id), 0) from import_repairs", as: Int64) : 0_i64,
                  pending: pending_count, thresholds: thresholds, origins: origin_counts, recheck: recheck_state,
                  entries: rows.map { |p| library_entry(p, books[p.book_id]?) }}.to_json)
    end

    # the running recheck, null without one
    private def recheck_state
      r = @recheck || return nil
      job = r.last.try(&.[0]) || return nil
      return nil unless job.status == "running"
      {done: job.done, total: job.total, waiting: r.waiting?}
    end

    # A proposal as an entry: the book as it would be, the current title as
    # bookTitle. A book gone from the library has neither.
    private def library_entry(p : ImportRepair::Proposal, book : Book?)
      changes = p.changes.map { |c| Meta::Change.new(c.field, c.old, c.new, c.source) }
      proposed = Intake.from_values(Intake.changed_values(book || Backlog.book(p.book_id, "##{p.book_id}", [] of String), changes))
      {id: -p.book_id, path: p.file, name: p.file.empty? ? "" : File.basename(p.file), folder: nil, kind: "library",
       files: (book.try(&.formats) || [] of String).map { |f| {path: "", format: f.upcase, size: 0} },
       status: p.status == "failed" ? "failed" : "analysed", detail: nil, proposal: proposed, confidence: p.confidence,
       band: p.confidence.try { |c| Meta::Confidence.band(c) }, titleConfidence: p.title_confidence,
       authorsConfidence: p.authors_confidence, level: p.level, source: p.source, decided: p.decided, isbnSource: nil,
       notes: p.notes, action: "update", bookId: p.book_id, match: nil, sameAs: nil, addFormats: [] of String,
       cover: book ? "/api/books/#{p.book_id}/cover?size=thumb" : nil, analysedAt: Time.unix(p.at).to_rfc3339,
       skipped: p.skipped, error: p.detail, bookTitle: book.try(&.title)}
    end

    # One library entry for the drawer: old → new per field; a proposal
    # decided meanwhile is gone
    def library_detail(id : Int64) : JSON::Any?
      repair = @repair || return nil
      p = repair.proposals(LIBRARY_OPEN + " and book_id = ?", [id] of DB::Any).first? || return nil
      h = JSON.parse(library_entry(p, @calibre.book(id)).to_json).as_h
      h["changes"] = JSON.parse(p.changes.map { |c| {field: c.field, old: c.old, new: c.new, source: c.source} }.to_json)
      h["candidates"] = JSON.parse("[]")
      h["unsureTag"] = JSON::Any.new(Meta.unsure_tag)
      JSON::Any.new(h)
    end

    private def library_target?(target : Hash(String, JSON::Any)) : Bool
      return target["query"].as_h?.try(&.["library"]?.try(&.as_bool?)) || false if target["query"]?
      list = target["ids"]?.try(&.as_a?) || return false
      negative = list.count { |v| v.as_i64?.try(&.negative?) }
      raise Edit::Invalid.new("target", "files and library books don't mix") unless negative == 0 || negative == list.size
      negative > 0
    end

    # accept and reject by ImportRepair, skip and unskip at once. Nothing that
    # would touch a library book's files gets here.
    private def decide_library(body : Hash(String, JSON::Any), decision : String, target : Hash(String, JSON::Any)) : {Int32, JSON::Any}
      repair = @repair || raise Edit::Invalid.new("target", "no proposals here")
      raise Edit::Invalid.new("decision", "accept, skip, unskip or reject for a library book") unless decision.in?("accept", "skip", "unskip", "reject")
      %w(candidate title authors picks).each do |k|
        raise Edit::Invalid.new(k, "not for a library book") if body[k]?.try { |v| !v.raw.nil? }
      end
      repair.release
      ids = target["query"]? ? library_by_filter(target, decision) : library_by_ids(target)
      case decision
      when "accept"
        wanted = ids.empty? ? [] of Int64 : repair.proposals("status = 'pending' and book_id in (#{ids.join(",")})", [] of DB::Any).map(&.book_id)
        return {202, JSON.parse({jobId: nil, total: 0}.to_json)} if wanted.empty?
        result = repair.accept(wanted)
        {202, JSON.parse({jobId: result["job"]["id"], total: wanted.size}.to_json)}
      when "reject"
        {200, JSON.parse({total: repair.reject(ids)}.to_json)}
      else
        repair.skip(ids, decision == "skip")
        {200, JSON.parse({total: ids.size}.to_json)}
      end
    end

    # the ones still open
    private def library_by_ids(target : Hash(String, JSON::Any)) : Array(Int64)
      wanted = target["ids"].as_a.map { |v| -(v.as_i64? || raise Edit::Invalid.new("target", "ids must be numbers")) }.uniq
      return wanted if wanted.empty?
      found = [] of Int64
      wanted.each_slice(STORE_BATCH) do |slice|
        @db.query_each("select book_id from import_repairs where #{LIBRARY_OPEN} and book_id in (#{slice.join(",")})") { |rs| found << rs.read(Int64) }
      end
      found
    end

    private def library_by_filter(target : Hash(String, JSON::Any), decision : String) : Array(Int64)
      raise Edit::Invalid.new("target", "only accept takes a filter") unless decision == "accept"
      q = target["query"].as_h? || raise Edit::Invalid.new("target", "object expected")
      expect = target["expect"]?.try(&.as_i64?) || raise Edit::Invalid.new("target", "expect (the number of books meant) required")
      last = target["last"]?.try(&.as_i64?) || raise Edit::Invalid.new("target", "last expected")
      ids = [] of Int64
      @db.query_each("select book_id from import_repairs where #{library_takeable(q["band"]?.try(&.as_s?))} and book_id <= ? order by #{LIBRARY_ORDER}", last) { |rs| ids << rs.read(Int64) }
      raise Jobs::CountMismatch.new(expect, ids.size) unless ids.size == expect
      ids
    end

    # The file of an entry to read in, the wanted format or the reader's
    # first. Only a file the entry lists, inside a root (a link doesn't lead
    # out) and as analysed.
    def readable(id : Int64, format : String? = nil, formats = READABLE) : Backlog::BookFile?
      e = self[id]? || return nil
      files = e.files.select { |f| formats.includes?(f.format) }
      file = format ? files.find { |f| f.format == format.upcase } : files.min_by? { |f| formats.index(f.format) || formats.size }
      file || return nil
      real = File.realpath(file.path)
      inside = roots.any? do |r|
        root = File.realpath(r) rescue next false
        real.starts_with?(root.rstrip('/') + "/")
      end
      info = File.info(real)
      inside && info.file? && info.size == file.size && info.modification_time.to_unix == file.mtime ? file : nil
    rescue File::Error
      nil
    end
  end
end
