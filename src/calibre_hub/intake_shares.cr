require "./intake"

module CalibreHub
  # What the Eingang's bar and filters show, in one read and whatever the
  # filters are, so the bar stands still while Arthur filters.
  #
  # Every entry is in exactly one kind, the first of these that fits, and the
  # list's filters (#filter_sql) cut the same way: what a number says is what
  # the list then shows. Skipped comes first, so a skipped duplicate counts
  # nowhere else.
  class Intake
    SHARE_KIND = "case when skipped = 1 then 'skipped' when #{SURE_SQL} then 'sure' " \
                 "when action = 'add' then 'new' else 'duplicates' end"
    SHARE_BAND = "case when confidence is null then 'none' when confidence >= #{Meta::Confidence::BULK} then 'bulk' " \
                 "when confidence >= #{Meta::Confidence::REVIEW} then 'review' else 'unsure' end"
    SHARE_KINDS = %w(new sure duplicates skipped)
    # calibre answers over HTTP, the page asks every few seconds
    BOOKS_FOR = 1.minute

    @books : Int32? = nil
    @books_at : Time::Instant? = nil

    private def no_bands : Hash(String, Int64)
      (Meta::Confidence::BANDS + ["none"]).to_h { |b| {b, 0_i64} }
    end

    # kinds: entries per kind and band, of the source when there is one, and
    # the proposals for the library's books, which have none. So have waiting
    # (files found, not analysed yet, of all sources) and books (the library's,
    # null while calibre doesn't answer).
    def shares(origin : String? = nil)
      kinds = SHARE_KINDS.to_h { |k| {k, no_bands} }
      clause = ["decision is null", origin_sql(origin)].compact.join(" and ")
      @db.query_each("select #{SHARE_KIND}, #{SHARE_BAND}, count(*) from intake_entries where #{clause} group by 1, 2") do |rs|
        kind, band = rs.read(String), rs.read(String)
        kinds[kind][band] = rs.read(Int64)
      end
      kinds["library"] = library_bands
      {kinds: kinds, waiting: @left, books: book_count}
    end

    private def library_bands : Hash(String, Int64)
      bands = no_bands
      bands.each_key { |b| bands[b] = library_count(library_sql(b)) } if @repair
      bands
    end

    # The list doesn't wait for calibre, which may take its time: once there is
    # a number the next one comes behind it.
    private def book_count : Int32?
      at = @books_at
      return @books if at && Time.instant - at < BOOKS_FOR
      @books_at = Time.instant
      return refresh_books unless @books
      spawn { refresh_books }
      @books
    end

    # the last number while calibre is away: the Eingang works without it
    private def refresh_books : Int32?
      @books = @calibre.search("", "id", true, 0, 1).total
    rescue Calibre::Error | IO::Error
      @books
    end
  end
end
