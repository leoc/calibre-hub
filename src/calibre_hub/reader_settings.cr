require "db"
require "json"
require "./edit"

module CalibreHub
  # How the browser reader shows books, per user and the same on every
  # device (state DB, one JSON object per user). Unset fields are the
  # defaults; a PUT changes only the fields it names.
  class ReaderSettings
    FONT_FAMILIES = %w(original serif sans literata atkinson source-serif inter)
    COLUMNS       = %w(auto 1 2)
    FLOWS         = %w(paginated scrolled)
    THEMES        = %w(light sepia dark eink)

    # field => default; numbers with their range
    DEFAULTS = {
      "fontFamily" => JSON::Any.new("original"),
      "fontSize"   => JSON::Any.new(100_i64),
      "lineHeight" => JSON::Any.new(1.5),
      "justify"    => JSON::Any.new(true),
      "hyphenate"  => JSON::Any.new(true),
      "margin"     => JSON::Any.new(6_i64),
      "maxWidth"   => JSON::Any.new(720_i64),
      "columns"    => JSON::Any.new("auto"),
      "flow"       => JSON::Any.new("paginated"),
      "animated"   => JSON::Any.new(true),
      "theme"      => JSON::Any.new("light"),
      "override"   => JSON::Any.new(false),
    }
    # percent of the browser's size
    FONT_SIZE = 50..300
    # times the font size
    LINE_HEIGHT = 1.0..2.5
    # percent of the page width on each side (foliate-js' gap)
    MARGIN = 0..20
    # px per column
    MAX_WIDTH = 400..2000

    def initialize(@db : DB::Database)
      @db.exec <<-SQL
        create table if not exists reader_settings (
          user text primary key,
          settings text not null,
          updated_at integer not null
        )
        SQL
    end

    # all fields, stored or default
    def of(user : String) : Hash(String, JSON::Any)
      stored = @db.query_one?("select settings from reader_settings where user = ?", user, as: String)
      saved = stored.try { |s| JSON.parse(s).as_h? } || {} of String => JSON::Any
      DEFAULTS.to_h { |k, v| {k, saved[k]?.try { |x| valid?(k, x) ? x : nil } || v} }
    end

    # Validates the given fields, stores them over the current ones and
    # returns all fields. Unknown fields and bad values raise Edit::Invalid.
    def save(user : String, body : Hash(String, JSON::Any), now = Time.utc) : Hash(String, JSON::Any)
      if unknown = body.keys.find { |k| !DEFAULTS.has_key?(k) }
        raise Edit::Invalid.new(unknown, "unknown field")
      end
      changes = body.to_h { |k, v| {k, check(k, v)} }
      merged = of(user).merge(changes)
      @db.exec <<-SQL, user, merged.to_json, now.to_unix_ms
        insert into reader_settings (user, settings, updated_at) values (?, ?, ?)
        on conflict (user) do update set settings = excluded.settings, updated_at = excluded.updated_at
        SQL
      merged
    end

    private def valid?(key, value) : Bool
      check(key, value)
      true
    rescue Edit::Invalid
      false
    end

    # the value as stored (numbers normalized), or Edit::Invalid
    private def check(key : String, v : JSON::Any) : JSON::Any
      case key
      when "fontFamily" then one_of(key, v, FONT_FAMILIES)
      when "columns"    then one_of(key, v, COLUMNS)
      when "flow"       then one_of(key, v, FLOWS)
      when "theme"      then one_of(key, v, THEMES)
      when "fontSize"   then integer(key, v, FONT_SIZE)
      when "margin"     then integer(key, v, MARGIN)
      when "maxWidth"   then integer(key, v, MAX_WIDTH)
      when "lineHeight"
        f = v.as_f? || v.as_i64?.try(&.to_f) || raise Edit::Invalid.new(key, "number from #{LINE_HEIGHT.begin} to #{LINE_HEIGHT.end} expected")
        raise Edit::Invalid.new(key, "number from #{LINE_HEIGHT.begin} to #{LINE_HEIGHT.end} expected") unless LINE_HEIGHT.includes?(f)
        JSON::Any.new(f.round(2))
      else
        # justify, hyphenate, animated, override
        b = v.as_bool?
        raise Edit::Invalid.new(key, "true or false expected") if b.nil?
        JSON::Any.new(b)
      end
    end

    private def one_of(key, v, allowed) : JSON::Any
      s = v.as_s?
      raise Edit::Invalid.new(key, "one of #{allowed.join(", ")}") unless s && allowed.includes?(s)
      JSON::Any.new(s)
    end

    private def integer(key, v, range) : JSON::Any
      i = v.as_i64? || v.as_f?.try { |f| f.to_i64 if f.finite? && f == f.round }
      raise Edit::Invalid.new(key, "whole number from #{range.begin} to #{range.end} expected") unless i && range.includes?(i)
      JSON::Any.new(i)
    end
  end
end
