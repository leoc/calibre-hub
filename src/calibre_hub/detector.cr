require "db"
require "sqlite3"
require "json"
require "./calibre"
require "./library_db"

module CalibreHub
  struct Event
    include JSON::Serializable

    getter type : String # added | changed | deleted
    @[JSON::Field(key: "bookId")]
    getter book_id : Int64
    # changed: {field: [old, new]}
    getter changes : Hash(String, Array(JSON::Any))?
    # added/changed: the book after the change; deleted: the last known state
    getter book : JSON::Any?
    getter at : Time

    def initialize(@type, @book_id, @changes = nil, @book = nil, @at = Time.utc)
    end
  end

  # Turns library changes into events, without scanning the whole library on
  # every change:
  # - poll: book ids from the trigger changelog in metadata.db since the cursor
  # - touch: ids the hub itself just wrote (immediate)
  # - reconcile: all ids with last_modified, full rows only where they differ;
  #   on start, nightly and whenever the changelog looks broken
  # Each path fetches the affected books and diffs them against the snapshot.
  class Detector
    IGNORED = %w(lastModified)
    # Bump when the Book JSON changes; the snapshot is then rebuilt silently
    # instead of reporting every book as changed.
    SNAPSHOT_VERSION = "5"
    BATCH            = 5000

    @library : DB::Database?

    def initialize(@calibre : Calibre, @db : DB::Database, metadata_db : String? = nil)
      @mutex = Mutex.new
      @library = metadata_db.try { |p| LibraryDB.open_read_only(p) }
      migrate
    end

    def initialized? : Bool
      meta("snapshot_version") == SNAPSHOT_VERSION
    end

    def library_db : DB::Database?
      @library
    end

    # New changelog entries -> events. Falls back to reconcile when the
    # changelog is missing or was reset.
    def poll : Array(Event)
      ldb = @library
      return [] of Event unless ldb
      return reconcile unless initialized?
      cursor = meta("changelog_seq").try(&.to_i64?) || 0_i64
      max = LibraryDB.max_seq(ldb)
      if max.nil? || max < cursor
        STDERR.puts "changelog missing or reset (cursor #{cursor}, max #{max.inspect}), reconciling"
        return reconcile
      end
      events = [] of Event
      loop do
        changes = LibraryDB.changes_since(ldb, cursor) || break
        break if changes.empty?
        events.concat apply(changes.map(&.book).uniq)
        cursor = changes.last.seq
        set_meta("changelog_seq", cursor.to_s)
      end
      events
    end

    # The hub changed these books itself: report right away
    def touch(ids : Array(Int64)) : Array(Event)
      return [] of Event unless initialized?
      apply(ids)
    end

    # Compare id + last_modified of all books with the snapshot, fetch only
    # the differing ones. First run builds the snapshot without events.
    def reconcile : Array(Event)
      @mutex.synchronize do
        started = Time.instant
        cursor = @library.try { |l| LibraryDB.max_seq(l) }
        if !initialized?
          @db.exec "delete from snapshot"
          # one list call is much cheaper than id searches for everything
          @calibre.list.each_slice(BATCH) { |books| store(books, [] of Event) }
          set_meta("snapshot_version", SNAPSHOT_VERSION)
          set_meta("changelog_seq", cursor.to_s) if cursor
          set_meta("reconciled_at", Time.utc.to_rfc3339)
          count = @db.query_one("select count(*) from snapshot", as: Int64)
          puts "reconciled: snapshot of #{count} books built in #{(Time.instant - started).total_seconds.round(1)} s"
          return [] of Event
        end
        current = @calibre.last_modified
        known = {} of Int64 => String
        @db.query_each("select id, lm from snapshot") { |rs| known[rs.read(Int64)] = rs.read(String) }
        stale = current.select { |id, lm| known[id]? != lm }.keys
        gone = known.keys - current.keys
        events = [] of Event
        (stale + gone).each_slice(BATCH) { |ids| events.concat apply_unlocked(ids) }
        set_meta("changelog_seq", cursor.to_s) if cursor
        set_meta("reconciled_at", Time.utc.to_rfc3339)
        puts "reconciled: #{current.size} books, #{stale.size + gone.size} fetched, #{events.size} events in #{(Time.instant - started).total_seconds.round(1)} s"
        events
      end
    end

    def diff(old : JSON::Any, new : JSON::Any) : Hash(String, Array(JSON::Any))
      changes = {} of String => Array(JSON::Any)
      keys = old.as_h.keys | new.as_h.keys
      keys.each do |k|
        next if IGNORED.includes?(k)
        if k == "custom"
          sub = diff(old["custom"]? || JSON::Any.new({} of String => JSON::Any),
            new["custom"]? || JSON::Any.new({} of String => JSON::Any))
          sub.each { |ck, v| changes["##{ck}"] = v }
          next
        end
        a = old[k]? || JSON::Any.new(nil)
        b = new[k]? || JSON::Any.new(nil)
        changes[k] = [a, b] unless a == b
      end
      changes
    end

    def meta(key : String) : String?
      @db.query_one?("select value from meta where key = ?", key, as: String)
    end

    def set_meta(key : String, value : String)
      @db.exec "insert or replace into meta (key, value) values (?, ?)", key, value
    end

    private def apply(ids : Array(Int64)) : Array(Event)
      @mutex.synchronize { apply_unlocked(ids) }
    end

    private def apply_unlocked(ids : Array(Int64)) : Array(Event)
      events = [] of Event
      ids.each_slice(BATCH) do |slice|
        books = @calibre.books(slice)
        found = books.map(&.id).to_set
        previous = snapshot(slice)
        batch = [] of Event
        books.each do |b|
          json = JSON.parse(b.to_json)
          if old = previous[b.id]?
            changes = diff(old, json)
            batch << Event.new("changed", b.id, changes: changes, book: json) unless changes.empty?
          else
            batch << Event.new("added", b.id, book: json)
          end
        end
        gone = slice.reject { |id| found.includes?(id) }
        gone.each do |id|
          previous[id]?.try { |old| batch << Event.new("deleted", id, book: old) }
        end
        store(books, batch, gone)
        events.concat batch
      end
      events
    end

    private def store(books : Array(Book), events : Array(Event), deleted = [] of Int64)
      @db.transaction do |tx|
        c = tx.connection
        events.each do |e|
          c.exec "insert into events (type, book_id, payload, created_at) values (?, ?, ?, ?)",
            e.type, e.book_id, e.to_json, e.at.to_unix
        end
        books.each do |b|
          c.exec "insert or replace into snapshot (id, data, lm) values (?, ?, ?)",
            b.id, b.to_json, b.last_modified.to_utc.to_rfc3339(fraction_digits: 6)
        end
        deleted.each { |id| c.exec "delete from snapshot where id = ?", id }
      end
    end

    private def snapshot(ids : Array(Int64)) : Hash(Int64, JSON::Any)
      h = {} of Int64 => JSON::Any
      return h if ids.empty?
      @db.query_each("select id, data from snapshot where id in (#{ids.join(",")})") do |rs|
        h[rs.read(Int64)] = JSON.parse(rs.read(String))
      end
      h
    end

    private def migrate
      @db.exec "create table if not exists meta (key text primary key, value text)"
      if meta("snapshot_version") != SNAPSHOT_VERSION
        @db.exec "drop table if exists snapshot"
      end
      @db.exec "create table if not exists snapshot (id integer primary key, data text not null, lm text not null)"
      @db.exec <<-SQL
        create table if not exists events (
          id integer primary key autoincrement,
          type text not null,
          book_id integer not null,
          payload text not null,
          created_at integer not null,
          done_at integer
        )
        SQL
      @db.exec <<-SQL
        create table if not exists deliveries (
          event_id integer not null,
          handler text not null,
          attempts integer not null default 0,
          next_attempt_at integer not null default 0,
          done_at integer,
          failed_at integer,
          last_error text,
          primary key (event_id, handler)
        )
        SQL
    end
  end
end
