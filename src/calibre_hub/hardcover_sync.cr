require "db"
require "sqlite3"
require "json"
require "./calibre"
require "./progress"
require "./meta_sources"

module CalibreHub
  # Hardcover sync, one direction (hub -> Hardcover), through the token
  # and client of the metadata source (Meta::Hardcover):
  #
  # - Books of the library get their Hardcover book (and edition) in the
  #   background, a batch per run: first from the user's own Hardcover
  #   library (ISBN, then title and author), then by ISBN, then by a title
  #   and author search. Kept in the state DB (hardcover_books), a book not
  #   found is looked up again after RECHECK or when its ISBN, title or
  #   author changes. Read-only.
  # - The reading progress of one hub user becomes the book's status and
  #   pages on Hardcover: from READING_FROM "Currently Reading" with the
  #   pages read, from read_at "Read" with the date. Only books without a
  #   status or with "Want to Read"/"Currently Reading" are changed; "Read",
  #   "Paused", "Did Not Finish" and "Ignored" are left alone. Ratings,
  #   reviews and lists are never written.
  #
  # A book with one of the private tags ("Private", "privat") is left out:
  # nothing about it is sent, not even for matching. Tagged after it was
  # synced, what the hub added on Hardcover is deleted again (a user book
  # it created, reads it added); a user book that was there before (e.g.
  # imported) is kept and set private instead, its earlier privacy is
  # restored when the tag goes again. Then the book syncs as usual.
  #
  # Without write it is a dry run: the planned writes are logged once per
  # progress change, nothing is sent; switched to write, they are planned
  # again and sent.
  class HardcoverSync
    WANT_TO_READ = 1
    READING      = 2
    READ         = 3
    STATUS       = {1 => "Want to Read", 2 => "Currently Reading", 3 => "Read", 4 => "Paused",
                    5 => "Did Not Finish", 6 => "Ignored"}
    # statuses the sync may change (none, too)
    CHANGEABLE = {WANT_TO_READ, READING}
    # from here a book counts as being read (a peek isn't)
    READING_FROM = 0.02
    # a book not found is looked up again after
    RECHECK = 30.days
    # privacy_settings: 1 Public, 2 Followers only, 3 Private
    PRIVATE = 3

    record Match, book : Int64?, edition : Int64?, pages : Int32?, method : String
    record Read, id : Int64, started_at : String?, finished_at : String?, pages : Int32?
    record UserBook, id : Int64, book : Int64, status : Int32, edition : Int64?, pages : Int32?, reads : Array(Read),
      privacy : Int32? = nil
    # one mutation; text for the log
    record Action, query : String, variables : Hash(String, JSON::Any), text : String
    # a book of the user's Hardcover library, for matching
    record Own, book : Int64, edition : Int64?, pages : Int32?, isbns : Array(String), title : String, authors : Array(String)

    EDITION_QUERY = "query($isbn: String!) { editions(where: {_or: [{isbn_13: {_eq: $isbn}}, {isbn_10: {_eq: $isbn}}]}, limit: 5) { id pages book { id pages } } }"
    BOOKS_QUERY   = "query($ids: [Int!]) { books(where: {id: {_in: $ids}}) { id pages editions(order_by: {users_count: desc}, limit: 50) { id pages language { code3 } } } }"
    OWN_QUERY     = "query { me { user_books(order_by: {id: asc}) { book_id edition { id pages isbn_13 isbn_10 } book { title pages contributions { author { name } contribution } } } } }"
    USER_BOOKS    = "query($ids: [Int!]) { me { user_books(where: {book_id: {_in: $ids}}) { id book_id status_id privacy_setting_id edition { id pages } book { pages } " \
                    "user_book_reads(order_by: {id: desc}) { id started_at finished_at progress_pages } } } }"
    INSERT_USER_BOOK = "mutation($object: UserBookCreateInput!) { insert_user_book(object: $object) { id error } }"
    UPDATE_USER_BOOK = "mutation($id: Int!, $object: UserBookUpdateInput!) { update_user_book(id: $id, object: $object) { id error } }"
    INSERT_READ      = "mutation($id: Int!, $read: DatesReadInput!) { insert_user_book_read(user_book_id: $id, user_book_read: $read) { id error } }"
    UPDATE_READ      = "mutation($id: Int!, $read: DatesReadInput!) { update_user_book_read(id: $id, object: $read) { id error } }"
    DELETE_USER_BOOK = "mutation($id: Int!) { delete_user_book(id: $id) { id } }"
    DELETE_READ      = "mutation($id: Int!) { delete_user_book_read(id: $id) { id error } }"

    getter? write : Bool
    @private_tags : Set(String)

    def initialize(@db : DB::Database, @calibre : Calibre, @progress : Progress, @hardcover : Meta::Hardcover,
                   @user : String, @write = false, @read_at = 0.98, @batch = 100, @interval = 15.minutes,
                   private_tags : Array(String) = %w(Private privat))
      @private_tags = private_tags.map(&.strip.downcase).to_set
      @db.exec <<-SQL
        create table if not exists hardcover_books (
          book_id integer primary key,
          hc_book_id integer,
          hc_edition_id integer,
          pages integer,
          method text not null,
          key text not null,
          checked_at integer not null
        )
        SQL
      @db.exec <<-SQL
        create table if not exists hardcover_sync (
          book_id integer primary key,
          hc_book_id integer not null,
          status integer,
          pages integer,
          progress_at integer not null,
          synced_at integer not null,
          dry_run integer not null
        )
        SQL
      # what the hub added on Hardcover (kind user_book or read), so a
      # private book can be taken back without touching the rest
      @db.exec <<-SQL
        create table if not exists hardcover_created (
          kind text not null,
          hc_id integer not null,
          book_id integer not null,
          primary key (kind, hc_id)
        )
        SQL
      # private books taken back (or planned in a dry run); privacy: the
      # user book's setting before it was set private
      @db.exec <<-SQL
        create table if not exists hardcover_private (
          book_id integer primary key,
          hc_book_id integer,
          user_book_id integer,
          privacy integer,
          at integer not null,
          dry_run integer not null
        )
        SQL
      @own = nil.as(Array(Own)?)
    end

    def start
      spawn do
        loop do
          begin
            run
          rescue ex
            STDERR.puts "hardcover sync failed: #{ex.message}"
          end
          sleep @interval
        end
      end
    end

    # progress first (its books mapped on demand), then a batch of books
    # to map; {books mapped, books synced}
    def run(now = Time.utc) : {Int32, Int32}
      return {0, 0} unless @hardcover.available?(now)
      @own = nil
      all = @calibre.list("", %w(title authors identifiers languages tags)).index_by(&.id)
      books = all.reject { |_, b| private?(b) }
      take_back(all.values.select { |b| private?(b) })
      release(books)
      synced = sync_progress(books, now)
      mapped = 0
      due(books, now).first(@batch).each do |b|
        break unless @hardcover.available?(now)
        map(b, now)
        mapped += 1
      rescue ex : Meta::SourceError
        log "mapping #{b.id} failed: #{ex.message}"
      end
      {mapped, synced}
    end

    # the book's Hardcover book, looked up when unknown or changed
    def match(book : Book, now = Time.utc) : Match?
      row = @db.query_one?("select hc_book_id, hc_edition_id, pages, method, key, checked_at from hardcover_books where book_id = ?",
        book.id, as: {Int64?, Int64?, Int64?, String, String, Int64})
      if row && row[4] == HardcoverSync.key(book) && (row[0] || now.to_unix - row[5] < RECHECK.total_seconds)
        return row[0] ? Match.new(row[0], row[1], row[2].try(&.to_i32), row[3]) : nil
      end
      m = map(book, now)
      m.book ? m : nil
    end

    # books never looked up, changed since, or not found long enough ago
    def due(books : Hash(Int64, Book), now = Time.utc) : Array(Book)
      known = {} of Int64 => {String, Bool, Int64}
      @db.query_each("select book_id, key, hc_book_id is not null, checked_at from hardcover_books") do |rs|
        known[rs.read(Int64)] = {rs.read(String), rs.read(Int64) == 1, rs.read(Int64)}
      end
      books.values.sort_by(&.id).reverse!.select do |b|
        k = known[b.id]?
        k.nil? || k[0] != HardcoverSync.key(b) || (!k[1] && now.to_unix - k[2] >= RECHECK.total_seconds)
      end
    end

    def private?(book : Book) : Bool
      book.tags.any? { |t| @private_tags.includes?(t.strip.downcase) }
    end

    # Private books with something written to Hardcover: delete what the
    # hub created, set a user book that was there before private
    private def take_back(books : Array(Book))
      return if books.empty?
      written = Set(Int64).new
      @db.query_each("select book_id from hardcover_sync where dry_run = 0 union select book_id from hardcover_created") { |rs| written << rs.read(Int64) }
      done = {} of Int64 => Bool
      @db.query_each("select book_id, dry_run from hardcover_private") { |rs| done[rs.read(Int64)] = rs.read(Int64) == 1 }
      books.each do |b|
        next unless written.includes?(b.id)
        next if done.has_key?(b.id) && !(done[b.id] && @write)
        take_back(b)
      rescue ex : Meta::SourceError
        log "#{b.id} private, taking it back failed: #{ex.message}"
      end
    end

    private def take_back(book : Book)
      hc = @db.query_one?("select hc_book_id from hardcover_sync where book_id = ?", book.id, as: Int64) ||
           @db.query_one?("select hc_book_id from hardcover_books where book_id = ?", book.id, as: Int64?)
      created_ub = Set(Int64).new
      created_reads = Set(Int64).new
      @db.query_each("select kind, hc_id from hardcover_created where book_id = ?", book.id) do |rs|
        (rs.read(String) == "user_book" ? created_ub : created_reads) << rs.read(Int64)
      end
      ub = hc ? fetch_user_books([hc])[hc]? : nil
      label = "#{book.id} (private, Hardcover #{hc})"
      actions = HardcoverSync.take_back_actions(ub, created_ub, created_reads)
      privacy = ub && !created_ub.includes?(ub.id) ? ub.privacy : nil
      if @write
        actions.each { |a| apply(a, label) }
        @db.exec "delete from hardcover_created where book_id = ?", book.id
        @db.exec "delete from hardcover_sync where book_id = ?", book.id
      else
        actions.each { |a| log "dry run: #{label}: would #{a.text}" }
      end
      log "#{label}: nothing on Hardcover to take back" if actions.empty?
      # set private already (an earlier run): keep the privacy from before
      if privacy == PRIVATE
        privacy = @db.query_one?("select privacy from hardcover_private where book_id = ?", book.id, as: Int64?).try(&.to_i32)
      end
      @db.exec "insert or replace into hardcover_private (book_id, hc_book_id, user_book_id, privacy, at, dry_run) values (?, ?, ?, ?, ?, ?)",
        book.id, hc, ub.try(&.id), privacy, Time.utc.to_unix, @write ? 0 : 1
    end

    # reads the hub added, then a user book it created; a user book that
    # was there before is set private
    def self.take_back_actions(ub : UserBook?, created_ub : Set(Int64), created_reads : Set(Int64)) : Array(Action)
      ub || return [] of Action
      if created_ub.includes?(ub.id)
        ub.reads.map { |r| Action.new(DELETE_READ, {"id" => JSON::Any.new(r.id)}, "delete read #{r.id}") } +
          [Action.new(DELETE_USER_BOOK, {"id" => JSON::Any.new(ub.id)}, "delete user book #{ub.id} (added by the hub)")]
      else
        actions = ub.reads.select { |r| created_reads.includes?(r.id) }.map do |r|
          Action.new(DELETE_READ, {"id" => JSON::Any.new(r.id)}, "delete read #{r.id} (added by the hub)")
        end
        unless ub.privacy == PRIVATE
          actions << Action.new(UPDATE_USER_BOOK, {"id" => JSON::Any.new(ub.id), "object" => JSON::Any.new({"privacy_setting_id" => JSON::Any.new(PRIVATE.to_i64)})},
            "set user book #{ub.id} private (it was there before the hub)")
        end
        actions
      end
    end

    # Books no longer private: an earlier privacy restored, then they sync
    # as usual
    private def release(books : Hash(Int64, Book))
      rows = [] of {Int64, Int64?, Int64?, Int64?, Bool}
      @db.query_each("select book_id, hc_book_id, user_book_id, privacy, dry_run from hardcover_private") do |rs|
        rows << {rs.read(Int64), rs.read(Int64?), rs.read(Int64?), rs.read(Int64?), rs.read(Int64) == 1}
      end
      rows.each do |id, hc, ub_id, privacy, dry|
        book = books[id]? || next
        label = "#{id} \"#{book.title}\" (no longer private, Hardcover #{hc})"
        if ub_id && privacy && privacy != PRIVATE && !dry
          a = Action.new(UPDATE_USER_BOOK, {"id" => JSON::Any.new(ub_id), "object" => JSON::Any.new({"privacy_setting_id" => JSON::Any.new(privacy)})},
            "restore privacy #{privacy} of user book #{ub_id}")
          if @write
            apply(a, label)
          else
            log "dry run: #{label}: would #{a.text}"
            next
          end
        end
        @db.exec "delete from hardcover_private where book_id = ?", id
      rescue ex : Meta::SourceError
        log "#{id} no longer private, restoring failed: #{ex.message}"
      end
    end

    # what a match depends on: the ISBN, else title and first author
    def self.key(book : Book) : String
      isbn(book) || "#{Meta::Text.key(book.title)}|#{book.authors.first?.try { |a| Meta::Text.key(a) }}"
    end

    def self.isbn(book : Book) : String?
      book.identifiers["isbn"]?.try { |i| Meta::Isbn.normalize(i) }
    end

    private def map(book : Book, now : Time) : Match
      m = lookup(book)
      @db.exec "insert or replace into hardcover_books (book_id, hc_book_id, hc_edition_id, pages, method, key, checked_at) values (?, ?, ?, ?, ?, ?, ?)",
        book.id, m.book, m.edition, m.pages, m.method, HardcoverSync.key(book), now.to_unix
      if m.book
        log "#{book.id} \"#{book.title}\" is Hardcover book #{m.book} (#{m.method})"
      end
      m
    end

    private def lookup(book : Book) : Match
      isbn = HardcoverSync.isbn(book)
      if m = HardcoverSync.own_match(own, isbn, book.title, book.authors)
        return m
      end
      if isbn && (data = @hardcover.graphql(EDITION_QUERY, {"isbn" => isbn}))
        m = HardcoverSync.edition_match(data)
        return m if m
      end
      author = book.authors.first?
      if author && !book.title.empty?
        q = Meta::Query.new(book.title, author, Meta::Lang.list(book.languages))
        found = @hardcover.graphql(Meta::Hardcover::SEARCH_QUERY, {"q" => "#{book.title} #{author}"})
        ids = found ? Meta::Hardcover.hits(found, q).first(3) : [] of Int64
        if !ids.empty? && (data = @hardcover.graphql(BOOKS_QUERY, {"ids" => ids}))
          m = HardcoverSync.search_match(data, q, ids)
          return m if m
        end
      end
      Match.new(nil, nil, nil, "none")
    end

    # the user's Hardcover library, once per run
    private def own : Array(Own)
      @own ||= @hardcover.graphql(OWN_QUERY, {} of String => String).try { |d| HardcoverSync.parse_own(d) } || [] of Own
    end

    def self.parse_own(data : JSON::Any) : Array(Own)
      me = data["me"]?.try(&.as_a?).try(&.first?) || return [] of Own
      (me["user_books"]?.try(&.as_a?) || [] of JSON::Any).compact_map do |ub|
        book = int(ub, "book_id") || next
        e = ub["edition"]?.try { |x| x.as_h? ? x : nil }
        b = ub["book"]?.try { |x| x.as_h? ? x : nil }
        isbns = e ? [str(e, "isbn_13"), str(e, "isbn_10")].compact.compact_map { |i| Meta::Isbn.normalize(i) } : [] of String
        Own.new(book, e.try { |x| int(x, "id") }, e.try { |x| int(x, "pages").try(&.to_i32) } || b.try { |x| int(x, "pages").try(&.to_i32) },
          isbns, b.try { |x| str(x, "title") } || "", b ? Meta::Hardcover.authors(b) : [] of String)
      end
    end

    # by ISBN (also an ISBN-10 for the ISBN-13), else a very similar title
    # by the same author
    def self.own_match(own : Array(Own), isbn : String?, title : String, authors : Array(String)) : Match?
      if isbn
        if o = own.find(&.isbns.includes?(isbn))
          return Match.new(o.book, o.edition, o.pages, "own-isbn")
        end
      end
      return nil if title.empty? || authors.empty?
      o = own.find do |x|
        !x.title.empty? && !x.authors.empty? && Meta::Text.similarity(title, x.title) >= 0.9 &&
          Meta::Score.authors(authors, x.authors) >= 0.8
      end
      o.try { |x| Match.new(x.book, x.edition, x.pages, "own-title") }
    end

    def self.edition_match(data : JSON::Any) : Match?
      (data["editions"]?.try(&.as_a?) || [] of JSON::Any).each do |e|
        book = e["book"]?.try { |b| b.as_h? ? b : nil } || next
        id = int(book, "id") || next
        return Match.new(id, int(e, "id"), (int(e, "pages") || int(book, "pages")).try(&.to_i32), "isbn")
      end
      nil
    end

    # the first hit with an edition in the book's language (unknown: German
    # for a German-looking title, else English), like the metadata source
    def self.search_match(data : JSON::Any, q : Meta::Query, ids : Array(Int64)) : Match?
      books = data["books"]?.try(&.as_a?) || return nil
      wanted = q.languages.presence || (Meta::Lang.german_title?(q.title) ? ["deu"] : ["eng"])
      books = books.sort_by { |b| ids.index(int(b, "id") || 0_i64) || ids.size }
      books.each do |b|
        id = int(b, "id") || next
        own = (b["editions"]?.try(&.as_a?) || [] of JSON::Any).select do |e|
          code = e["language"]?.try { |l| l.as_h? ? str(l, "code3") : nil }
          code && !(Meta::Lang.list([code]) & wanted).empty?
        end
        next if own.empty?
        edition = own.size == 1 ? own.first : nil
        pages = edition.try { |e| int(e, "pages") } || int(b, "pages")
        return Match.new(id, edition.try { |e| int(e, "id") }, pages.try(&.to_i32), "search")
      end
      nil
    end

    # the books whose progress changed since their last sync (in this mode)
    private def sync_progress(books : Hash(Int64, Book), now : Time) : Int32
      last = {} of Int64 => {Int64, Bool}
      @db.query_each("select book_id, progress_at, dry_run from hardcover_sync") do |rs|
        last[rs.read(Int64)] = {rs.read(Int64), rs.read(Int64) == 1}
      end
      changed = @progress.latest(@user).select do |e|
        l = last[e.book_id]?
        books.has_key?(e.book_id) && (l.nil? || l[0] < e.updated_at.to_unix_ms || (l[1] && @write))
      end
      return 0 if changed.empty?
      matched = changed.compact_map do |e|
        m = match(books[e.book_id], now)
        m ? {e, m} : nil
      rescue ex : Meta::SourceError
        log "mapping #{e.book_id} failed: #{ex.message}"
        nil
      end
      return 0 if matched.empty?
      user_books = fetch_user_books(matched.compact_map(&.[1].book))
      synced = 0
      matched.each do |e, m|
        sync(books[e.book_id], e, m, user_books[m.book]?)
        synced += 1
      rescue ex : Meta::SourceError
        log "#{e.book_id} failed: #{ex.message}"
      end
      synced
    end

    private def fetch_user_books(ids : Array(Int64)) : Hash(Int64, UserBook)
      data = @hardcover.graphql(USER_BOOKS, {"ids" => ids}) || raise Meta::SourceError.new("hardcover: no answer")
      HardcoverSync.parse_user_books(data).index_by(&.book)
    end

    def self.parse_user_books(data : JSON::Any) : Array(UserBook)
      me = data["me"]?.try(&.as_a?).try(&.first?) || return [] of UserBook
      (me["user_books"]?.try(&.as_a?) || [] of JSON::Any).compact_map do |ub|
        id = int(ub, "id") || next
        book = int(ub, "book_id") || next
        e = ub["edition"]?.try { |x| x.as_h? ? x : nil }
        b = ub["book"]?.try { |x| x.as_h? ? x : nil }
        reads = (ub["user_book_reads"]?.try(&.as_a?) || [] of JSON::Any).compact_map do |r|
          rid = int(r, "id") || next
          Read.new(rid, str(r, "started_at"), str(r, "finished_at"), int(r, "progress_pages").try(&.to_i32))
        end
        pages = e.try { |x| int(x, "pages") } || b.try { |x| int(x, "pages") }
        UserBook.new(id, book, int(ub, "status_id").try(&.to_i32) || 0, e.try { |x| int(x, "id") }, pages.try(&.to_i32), reads,
          int(ub, "privacy_setting_id").try(&.to_i32))
      end
    end

    private def sync(book : Book, e : Progress::Entry, m : Match, ub : UserBook?)
      hc = m.book || return
      date = e.updated_at.in(Time::Location.load_local).to_s("%Y-%m-%d")
      desired = HardcoverSync.desired(e.fraction, @read_at)
      pages = ub.try(&.pages) || m.pages
      progress_pages = desired && pages ? HardcoverSync.pages_read(e.fraction, pages, desired) : nil
      label = "#{book.id} \"#{book.title}\" (Hardcover #{hc})"
      status = HardcoverSync.status_action(ub, m, desired)
      if status && @write
        id = apply(status, label)
        created(book.id, "user_book", id) if status.query == INSERT_USER_BOOK
        # Hardcover may add a read itself for a new status
        ub = fetch_user_books([hc])[hc]? || id.try { |i| UserBook.new(i, hc, desired.not_nil!, m.edition, pages, [] of Read) }
      elsif status
        log "dry run: #{label}: would #{status.text}"
        ub ||= UserBook.new(0, hc, desired.not_nil!, m.edition, pages, [] of Read)
      end
      if ub && desired
        if status || CHANGEABLE.includes?(ub.status)
          if read = HardcoverSync.read_action(ub, desired, progress_pages, ub.edition || m.edition, date)
            if @write
              rid = apply(read, label)
              created(book.id, "read", rid) if read.query == INSERT_READ
            else
              log "dry run: #{label}: would #{read.text}"
            end
          end
        elsif ub.status != desired
          log "#{label}: kept #{STATUS[ub.status]? || ub.status} on Hardcover"
        end
      end
      @db.exec "insert or replace into hardcover_sync (book_id, hc_book_id, status, pages, progress_at, synced_at, dry_run) values (?, ?, ?, ?, ?, ?, ?)",
        book.id, hc, desired, progress_pages, e.updated_at.to_unix_ms, Time.utc.to_unix, @write ? 0 : 1
    end

    private def created(book_id : Int64, kind : String, id : Int64?)
      id.try { |i| @db.exec "insert or replace into hardcover_created (kind, hc_id, book_id) values (?, ?, ?)", kind, i, book_id }
    end

    # the mutation's id; raises on an error, so the book is tried again
    private def apply(action : Action, label : String) : Int64?
      data = @hardcover.graphql(action.query, action.variables) || raise Meta::SourceError.new("hardcover: token rejected")
      result = data.as_h.values.first?
      if error = result.try { |r| r.as_h? ? str(r, "error") : nil }
        raise Meta::SourceError.new("hardcover: #{action.text}: #{error}")
      end
      log "#{label}: #{action.text}"
      result.try { |r| r.as_h? ? int(r, "id") : nil }
    end

    def self.desired(fraction : Float64, read_at : Float64) : Int32?
      if fraction >= read_at
        READ
      elsif fraction >= READING_FROM
        READING
      end
    end

    def self.pages_read(fraction : Float64, pages : Int32, status : Int32) : Int32
      status == READ ? pages : (fraction * pages).round.to_i.clamp(1, pages)
    end

    # nil: nothing to change (or not ours to change)
    def self.status_action(ub : UserBook?, m : Match, desired : Int32?) : Action?
      desired || return nil
      book = m.book || return nil
      if ub.nil?
        object = {"book_id" => JSON::Any.new(book), "status_id" => JSON::Any.new(desired.to_i64)}
        m.edition.try { |e| object["edition_id"] = JSON::Any.new(e) }
        return Action.new(INSERT_USER_BOOK, {"object" => JSON::Any.new(object)}, "add as #{STATUS[desired]}")
      end
      return nil unless CHANGEABLE.includes?(ub.status) && ub.status != desired
      Action.new(UPDATE_USER_BOOK, {"id" => JSON::Any.new(ub.id), "object" => JSON::Any.new({"status_id" => JSON::Any.new(desired.to_i64)})},
        "set #{STATUS[ub.status]? || ub.status} -> #{STATUS[desired]}")
    end

    # the open read (not finished) gets the pages, or the finish date; a
    # new one when there is none
    def self.read_action(ub : UserBook, desired : Int32?, pages : Int32?, edition : Int64?, date : String) : Action?
      desired || return nil
      open = ub.reads.find { |r| r.finished_at.nil? }
      read = {} of String => JSON::Any
      if desired == READ
        return nil if open.nil? && ub.reads.any? { |r| r.finished_at == date }
        read["finished_at"] = JSON::Any.new(date)
      elsif open
        return nil if pages.nil? || open.pages == pages
      else
        read["started_at"] = JSON::Any.new(date)
      end
      pages.try { |p| read["progress_pages"] = JSON::Any.new(p.to_i64) }
      edition.try { |e| read["edition_id"] = JSON::Any.new(e) }
      text = desired == READ ? "finished #{date}" : "#{open ? "" : "started #{date}, "}#{pages ? "page #{pages}" : "no page count"}"
      if open
        Action.new(UPDATE_READ, {"id" => JSON::Any.new(open.id), "read" => JSON::Any.new(read)}, "update read #{open.id}: #{text}")
      else
        Action.new(INSERT_READ, {"id" => JSON::Any.new(ub.id), "read" => JSON::Any.new(read)}, "add read: #{text}")
      end
    end

    def self.int(o : JSON::Any, key : String) : Int64?
      v = o[key]?
      v.try { |x| x.as_i64? || x.as_f?.try(&.to_i64) || x.as_s?.try(&.to_i64?) }
    end

    def self.str(o : JSON::Any, key : String) : String?
      o[key]?.try(&.as_s?).try(&.strip).presence
    end

    private def int(o, key)
      HardcoverSync.int(o, key)
    end

    private def str(o, key)
      HardcoverSync.str(o, key)
    end

    private def log(text : String)
      STDERR.puts "hardcover sync: #{text}"
    end
  end
end
