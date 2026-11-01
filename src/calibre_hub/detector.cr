require "db"
require "sqlite3"
require "json"

module CalibreHub
  struct Event
    include JSON::Serializable

    getter type : String # added | changed | deleted
    getter book_id : Int64
    # changed: {field: [old, new]}; added/deleted: full book
    getter changes : Hash(String, Array(JSON::Any))?
    getter book : JSON::Any?
    getter at : Time

    def initialize(@type, @book_id, @changes = nil, @book = nil, @at = Time.utc)
    end
  end

  # Compares the full library against the last snapshot and records the
  # differences as events. Always a full scan: last_modified only has second
  # resolution in places and mixes time zones, so it is not a safe cursor.
  # Fine for a personal library (a few thousand rows per scan).
  class Detector
    IGNORED = %w(last_modified)

    def initialize(@calibre : Calibre, @db : DB::Database)
      migrate
    end

    def scan : Array(Event)
      current = @calibre.list.to_h { |b| {b.id, JSON.parse(b.to_json)} }
      previous = snapshot
      first_run = previous.empty? && !initialized?

      events = [] of Event
      unless first_run
        current.each do |id, book|
          if old = previous[id]?
            changes = diff(old, book)
            events << Event.new("changed", id, changes: changes) unless changes.empty?
          else
            events << Event.new("added", id, book: book)
          end
        end
        (previous.keys - current.keys).each do |id|
          events << Event.new("deleted", id, book: previous[id])
        end
      end

      @db.transaction do |tx|
        cnn = tx.connection
        events.each do |e|
          cnn.exec "insert into events (type, book_id, payload, created_at) values (?, ?, ?, ?)",
            e.type, e.book_id, e.to_json, e.at.to_unix
        end
        cnn.exec "delete from snapshot"
        current.each { |id, book| cnn.exec "insert into snapshot (id, data) values (?, ?)", id, book.to_json }
        cnn.exec "insert or replace into meta (key, value) values ('initialized', '1')"
      end
      events
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

    private def snapshot : Hash(Int64, JSON::Any)
      h = {} of Int64 => JSON::Any
      @db.query_each("select id, data from snapshot") do |rs|
        h[rs.read(Int64)] = JSON.parse(rs.read(String))
      end
      h
    end

    private def initialized? : Bool
      !@db.query_one?("select value from meta where key = 'initialized'", as: String).nil?
    end

    private def migrate
      @db.exec "create table if not exists meta (key text primary key, value text)"
      @db.exec "create table if not exists snapshot (id integer primary key, data text not null)"
      @db.exec <<-SQL
        create table if not exists events (
          id integer primary key autoincrement,
          type text not null,
          book_id integer not null,
          payload text not null,
          created_at integer not null,
          attempts integer not null default 0,
          next_attempt_at integer,
          done_at integer,
          last_error text
        )
        SQL
    end
  end
end
