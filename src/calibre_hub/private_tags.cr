require "db"
require "json"
require "./edit"

module CalibreHub
  # Private tags: tags a user puts on books for themselves, kept in the
  # hub's state DB per user and book, never in calibre (whose tags every
  # user shares). Nobody else sees them, also not an admin. A tag keeps the
  # spelling it has already for the user: "krimi" next to "Krimi" is
  # "Krimi". A deleted book's tags are kept aside and come back when it is
  # restored from the trash; a duplicate merge gives the keeper the tags of
  # the books merged into it.
  class PrivateTags
    MAX_TAG   =    100
    MAX_TAGS  =     50
    MAX_BOOKS = 10_000

    record Count, name : String, count : Int64 do
      include JSON::Serializable
    end

    def initialize(@db : DB::Database)
      @db.exec "create table if not exists meta (key text primary key, value text)"
      @db.exec <<-SQL
        create table if not exists private_tags (
          owner text not null,
          book_id integer not null,
          tag text not null collate nocase,
          added_at integer not null,
          primary key (owner, book_id, tag)
        )
        SQL
      @db.exec "create index if not exists private_tags_owner_tag on private_tags (owner, tag)"
      @db.exec "create index if not exists private_tags_book on private_tags (book_id)"
      # tags of deleted books, given back when the book is restored
      @db.exec <<-SQL
        create table if not exists private_tags_deleted (
          owner text not null,
          book_id integer not null,
          tag text not null collate nocase,
          added_at integer not null,
          primary key (owner, book_id, tag)
        )
        SQL
      # the detector's table, here too so this works on its own (specs)
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
    end

    # The user's tags with the number of books, by name
    def counts(user : String) : Array(Count)
      rows = [] of Count
      @db.query_each("select min(tag), count(*) from private_tags where owner = ? group by tag order by tag", user) do |rs|
        rows << Count.new(rs.read(String), rs.read(Int64))
      end
      rows.sort_by { |c| c.name.downcase }
    end

    # The user's tags of each book, by name
    def of(user : String, book_ids : Array(Int64)) : Hash(Int64, Array(String))
      result = {} of Int64 => Array(String)
      book_ids.each { |b| result[b] = [] of String }
      book_ids.uniq.each_slice(500) do |slice|
        @db.query_each("select book_id, tag from private_tags where owner = ? and book_id in (#{slice.join(",")})
                        order by tag", user) do |rs|
          b, t = rs.read(Int64, String)
          result[b] << t
        end
      end
      result
    end

    # The books that have all of the tags (for the user); empty tags: nil
    def books(user : String, tags : Array(String)) : Set(Int64)?
      tags = tags.map(&.strip).reject(&.empty?).uniq(&.downcase)
      return nil if tags.empty?
      ids = Set(Int64).new
      @db.query_each("select book_id from private_tags where owner = ? and tag in (#{(["?"] * tags.size).join(",")})
                      group by book_id having count(*) = ?", args: [user] + tags + [tags.size]) do |rs|
        ids << rs.read(Int64)
      end
      ids
    end

    # Adds and removes tags on books; returns the ids of the books that
    # changed. A tag both added and removed is a 400.
    def change(user : String, book_ids : Array(Int64), add : Array(String), remove : Array(String)) : Array(Int64)
      add = clean(add, "add")
      remove = clean(remove, "remove")
      raise Edit::Invalid.new("add", "nothing to change") if add.empty? && remove.empty?
      if both = add.find { |t| remove.any? { |r| same?(r, t) } }
        raise Edit::Invalid.new("add", "#{both} is both added and removed")
      end
      book_ids = book_ids.uniq
      raise Edit::Invalid.new("target", "at most #{MAX_BOOKS} books at once") if book_ids.size > MAX_BOOKS
      changed = Set(Int64).new
      now = Time.utc.to_unix_ms
      @db.transaction do |tx|
        c = tx.connection
        add = add.map { |t| spelling(c, user, t) }
        book_ids.each do |b|
          add.each do |t|
            c.exec "insert or ignore into private_tags (owner, book_id, tag, added_at) values (?, ?, ?, ?)", user, b, t, now
            changed << b if c.scalar("select changes()").as(Int64) > 0
          end
          remove.each do |t|
            c.exec "delete from private_tags where owner = ? and book_id = ? and tag = ?", user, b, t
            changed << b if c.scalar("select changes()").as(Int64) > 0
          end
        end
      end
      changed.to_a.sort
    end

    # The book's tags become these (for the user); returns them
    def set(user : String, book_id : Int64, tags : Array(String)) : Array(String)
      tags = clean(tags, "tags")
      now = Time.utc.to_unix_ms
      @db.transaction do |tx|
        c = tx.connection
        keep = tags.map { |t| spelling(c, user, t, book_id) }
        old = [] of String
        c.query_each("select tag from private_tags where owner = ? and book_id = ?", user, book_id) { |rs| old << rs.read(String) }
        old.each do |t|
          c.exec "delete from private_tags where owner = ? and book_id = ? and tag = ?", user, book_id, t unless keep.any? { |k| same?(k, t) }
        end
        keep.each do |t|
          c.exec "insert or ignore into private_tags (owner, book_id, tag, added_at) values (?, ?, ?, ?)", user, book_id, t, now
        end
      end
      of(user, [book_id])[book_id]
    end

    # A book was deleted: its tags are kept aside for a restore
    def book_deleted(book_id : Int64)
      @db.transaction do |tx|
        c = tx.connection
        c.exec "insert or replace into private_tags_deleted (owner, book_id, tag, added_at)
                select owner, book_id, tag, added_at from private_tags where book_id = ?", book_id
        c.exec "delete from private_tags where book_id = ?", book_id
      end
    end

    # A deleted book came back with a new id: its tags with it
    def book_restored(old_id : Int64, new_id : Int64)
      book_deleted(old_id)
      @db.transaction do |tx|
        c = tx.connection
        c.exec "insert or ignore into private_tags (owner, book_id, tag, added_at)
                select owner, ?, tag, added_at from private_tags_deleted where book_id = ?", new_id, old_id
        c.exec "delete from private_tags_deleted where book_id = ?", old_id
      end
    end

    # A duplicate merge: into gets every user's tags of from (from keeps
    # them, so they come back with it when the merge is undone)
    def merge_book(from : Int64, into : Int64)
      @db.exec "insert or ignore into private_tags (owner, book_id, tag, added_at)
                select owner, ?, tag, added_at from private_tags where book_id = ?", into, from
    end

    # Follows the event queue (cursor private_tags_event_seq): deleted
    # books' tags are put aside
    def watch_events(interval = 5.seconds)
      if @db.query_one?("select value from meta where key = 'private_tags_event_seq'", as: String).nil?
        max = @db.query_one("select coalesce(max(id), 0) from events", as: Int64)
        @db.exec "insert or replace into meta (key, value) values ('private_tags_event_seq', ?)", max.to_s
      end
      spawn do
        loop do
          begin
            follow_events
          rescue ex
            STDERR.puts "private tags: events: #{ex.message}"
          end
          sleep interval
        end
      end
    end

    def follow_events
      cursor = @db.query_one("select value from meta where key = 'private_tags_event_seq'", as: String).to_i64
      rows = [] of {Int64, String, Int64}
      @db.query_each("select id, type, book_id from events where id > ? order by id limit 500", cursor) do |rs|
        rows << rs.read(Int64, String, Int64)
      end
      return if rows.empty?
      rows.each { |_, type, book_id| book_deleted(book_id) if type == "deleted" }
      @db.exec "update meta set value = ? where key = 'private_tags_event_seq'", rows.last[0].to_s
    end

    # Tags from a JSON value: a list of strings, each trimmed
    def self.list(value : JSON::Any?, field : String) : Array(String)
      return [] of String if value.nil? || value.raw.nil?
      (value.as_a? || raise Edit::Invalid.new(field, "list of tags expected")).map do |t|
        t.as_s? || raise Edit::Invalid.new(field, "list of tags expected")
      end
    end

    private def clean(tags : Array(String), field : String) : Array(String)
      tags = tags.map(&.strip).reject(&.empty?).uniq(&.downcase)
      raise Edit::Invalid.new(field, "at most #{MAX_TAGS} tags at once") if tags.size > MAX_TAGS
      tags.each do |t|
        raise Edit::Invalid.new(field, "a tag has at most #{MAX_TAG} characters") if t.size > MAX_TAG
        raise Edit::Invalid.new(field, "no control characters") if t.matches?(/[\x00-\x1f]/)
        # like calibre's tags, so a comma-separated list stays one
        raise Edit::Invalid.new(field, "no commas in a tag") if t.includes?(',')
      end
      tags
    end

    # The spelling the user has for the tag already (on another book)
    private def spelling(c, user : String, tag : String, except : Int64 = -1_i64) : String
      c.query_one?("select tag from private_tags where owner = ? and tag = ? and book_id != ? limit 1", user, tag, except, as: String) || tag
    end

    private def same?(a : String, b : String) : Bool
      a.compare(b, case_insensitive: true) == 0
    end
  end
end
