require "db"
require "json"
require "./edit"

module CalibreHub
  # Reading progress per user, book and device in the state DB. A device
  # keeps one position per book (the last it reported); the newest one over
  # all devices is where the book continues.
  #
  # position is opaque to the hub and depends on the format: an EPUB CFI
  # (also MOBI/AZW3/CBZ through foliate-js), the page number for PDFs.
  # source tells who wrote it ("web" for the reader; KOReader sync will add
  # "koreader" with its own position strings, phase 2).
  class Progress
    MAX_POSITION =  4096
    MAX_DEVICE   =    64
    MAX_NAME     =    80
    FORMAT       = /\A[a-z0-9]{1,10}\z/
    SOURCES      = %w(web koreader)
    # how far back a position sent late (read offline) may date itself
    MAX_AGE = 30.days

    @[JSON::Serializable::Options(emit_nulls: true)]
    struct Entry
      include JSON::Serializable

      @[JSON::Field(key: "bookId")]
      getter book_id : Int64
      getter device : String
      @[JSON::Field(key: "deviceName")]
      getter device_name : String
      getter format : String
      getter position : String
      getter fraction : Float64
      getter source : String
      @[JSON::Field(key: "updatedAt")]
      getter updated_at : Time

      def initialize(@book_id, @device, @device_name, @format, @position, @fraction, @source, @updated_at)
      end
    end

    COLUMNS = "book_id, device, device_name, format, position, fraction, source, updated_at"

    def initialize(@db : DB::Database)
      @db.exec <<-SQL
        create table if not exists reading_progress (
          user text not null,
          book_id integer not null,
          device text not null,
          device_name text not null,
          format text not null,
          position text not null,
          fraction real not null,
          source text not null default 'web',
          updated_at integer not null,
          primary key (user, book_id, device)
        )
        SQL
      @db.exec "create index if not exists reading_progress_user on reading_progress (user, updated_at)"
    end

    # every device's position for the book, newest first
    def of(user : String, book_id : Int64) : Array(Entry)
      rows = [] of Entry
      @db.query_each("select #{COLUMNS} from reading_progress where user = ? and book_id = ?
                      order by updated_at desc, device", user, book_id) { |rs| rows << read(rs) }
      rows
    end

    # the newest position per book, for the progress bars on the covers
    def latest(user : String) : Array(Entry)
      rows = [] of Entry
      @db.query_each(<<-SQL, user) { |rs| rows << read(rs) }
        select #{COLUMNS} from (
          select *, row_number() over (partition by book_id order by updated_at desc, device) as n
          from reading_progress where user = ?
        ) where n = 1 order by updated_at desc
        SQL
      rows
    end

    # Stores the device's position; body: {format, position, fraction,
    # device, deviceName?, source?, age?}. The time is the hub's, so devices
    # with a wrong clock don't win. age (milliseconds, measured on the
    # device's own clock) dates a position read offline back to when it was
    # read, so it doesn't beat what other devices read in the meantime; it
    # never replaces a newer position of the same device.
    def save(user : String, book_id : Int64, body : Hash(String, JSON::Any), now = Time.utc) : Entry
      if unknown = body.keys.find { |k| !%w(format position fraction device deviceName source age).includes?(k) }
        raise Edit::Invalid.new(unknown, "unknown field")
      end
      device = string(body, "device", MAX_DEVICE)
      raise Edit::Invalid.new("device", "device id expected") if device.empty?
      name = body.has_key?("deviceName") ? string(body, "deviceName", MAX_NAME) : ""
      format = string(body, "format", 10).downcase
      raise Edit::Invalid.new("format", "format like epub or pdf expected") unless format.matches?(FORMAT)
      position = string(body, "position", MAX_POSITION)
      fraction = body["fraction"]?.try { |v| v.as_f? || v.as_i64?.try(&.to_f) } || raise Edit::Invalid.new("fraction", "number from 0 to 1 expected")
      raise Edit::Invalid.new("fraction", "number from 0 to 1 expected") unless 0.0 <= fraction <= 1.0
      source = body.has_key?("source") ? string(body, "source", 20) : "web"
      raise Edit::Invalid.new("source", "one of #{SOURCES.join(", ")}") unless SOURCES.includes?(source)
      name = device if name.empty?
      at = now - age(body)
      @db.exec <<-SQL, user, book_id, device, name, format, position, fraction, source, at.to_unix_ms
        insert into reading_progress (user, book_id, device, device_name, format, position, fraction, source, updated_at)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?)
        on conflict (user, book_id, device) do update set device_name = excluded.device_name,
          format = excluded.format, position = excluded.position, fraction = excluded.fraction,
          source = excluded.source, updated_at = excluded.updated_at
        where excluded.updated_at >= reading_progress.updated_at
        SQL
      @db.query_one("select #{COLUMNS} from reading_progress where user = ? and book_id = ? and device = ?",
        user, book_id, device) { |rs| read(rs) }
    end

    private def age(body) : Time::Span
      return Time::Span.zero unless v = body["age"]?
      ms = v.as_i64? || raise Edit::Invalid.new("age", "milliseconds from 0 expected")
      raise Edit::Invalid.new("age", "milliseconds from 0 expected") if ms < 0
      {ms.milliseconds, MAX_AGE}.min
    end

    private def string(body, key, max) : String
      v = body[key]?.try(&.as_s?) || raise Edit::Invalid.new(key, "string expected")
      v = v.strip
      raise Edit::Invalid.new(key, "at most #{max} characters") if v.size > max
      v
    end

    private def read(rs) : Entry
      Entry.new(rs.read(Int64), rs.read(String), rs.read(String), rs.read(String), rs.read(String),
        rs.read(Float64), rs.read(String), Time.unix_ms(rs.read(Int64)))
    end
  end
end
