require "json"
require "./book"
require "./sanitizer"

module CalibreHub
  # Turns a PATCH body into calibre set-fields changes. Pure, so the rules
  # can be tested without calibre-server.
  module Edit
    class Invalid < Exception
      getter field : String

      def initialize(@field : String, message : String)
        super(message)
      end
    end

    FIELDS = %w(title authors series seriesIndex tags addTags removeTags kategorie comments
      publisher pubdate languages rating identifiers lastModified)
    DATE = /\A\d{4}-\d{2}-\d{2}\z/

    def self.changes(body : Hash(String, JSON::Any), current : Book, category_column : String?) : Hash(String, JSON::Any)
      if unknown = body.keys.find { |k| !FIELDS.includes?(k) }
        raise Invalid.new(unknown, "unknown field")
      end
      if body.has_key?("tags") && (body.has_key?("addTags") || body.has_key?("removeTags"))
        raise Invalid.new("tags", "tags cannot be combined with addTags/removeTags")
      end

      result = {} of String => JSON::Any
      body.each do |key, value|
        case key
        when "title"
          result["title"] = JSON::Any.new(text(key, value, required: true).not_nil!)
        when "authors"
          list = strings(key, value)
          raise Invalid.new(key, "at least one author") if list.empty?
          result["authors"] = json(list)
        when "series"
          result["series"] = JSON::Any.new(text(key, value))
        when "seriesIndex"
          n = value.as_f? || value.as_i64?.try(&.to_f) || raise Invalid.new(key, "number expected")
          raise Invalid.new(key, "must not be negative") if n < 0
          result["series_index"] = JSON::Any.new(n)
        when "tags"
          result["tags"] = json(strings(key, value))
        when "kategorie"
          column = category_column || raise Invalid.new(key, "no category column configured")
          result["##{column}"] = JSON::Any.new(text(key, value))
        when "comments"
          result["comments"] = JSON::Any.new(text(key, value).try { |html| Sanitizer.clean(html).presence })
        when "publisher"
          result["publisher"] = JSON::Any.new(text(key, value))
        when "pubdate"
          date = text(key, value)
          raise Invalid.new(key, "YYYY-MM-DD expected") if date && !date.matches?(DATE)
          # noon keeps the day stable in every time zone, as calibre does
          result["pubdate"] = JSON::Any.new(date.try { |d| "#{d}T12:00:00+00:00" })
        when "languages"
          result["languages"] = json(strings(key, value))
        when "rating"
          r = value.raw.nil? ? 0_i64 : (value.as_i64? || raise Invalid.new(key, "integer 0-10 expected"))
          raise Invalid.new(key, "integer 0-10 expected") unless 0 <= r <= 10
          result["rating"] = r == 0 ? JSON::Any.new(nil) : JSON::Any.new(r)
        when "identifiers"
          h = value.as_h? || raise Invalid.new(key, "object expected")
          ids = h.transform_values { |v| v.as_s? || raise Invalid.new(key, "string values expected") }
          result["identifiers"] = json(ids.reject { |k, v| k.strip.empty? || v.strip.empty? })
        end
      end

      if body.has_key?("addTags") || body.has_key?("removeTags")
        add = body["addTags"]?.try { |v| strings("addTags", v) } || [] of String
        remove = (body["removeTags"]?.try { |v| strings("removeTags", v) } || [] of String).map(&.downcase).to_set
        tags = current.tags.reject { |t| remove.includes?(t.downcase) }
        add.each { |t| tags << t unless tags.any? { |x| x.downcase == t.downcase } }
        result["tags"] = json(tags)
      end
      result
    end

    # lastModified as read; nil means last write wins
    def self.conflict?(body : Hash(String, JSON::Any), current : Book) : Bool
      given = body["lastModified"]? || return false
      raise Invalid.new("lastModified", "string expected") unless given.as_s?
      current.version != given.as_s
    end

    private def self.text(key, value : JSON::Any, required = false) : String?
      if value.raw.nil?
        raise Invalid.new(key, "must not be empty") if required
        return nil
      end
      s = value.as_s? || raise Invalid.new(key, "string expected")
      s = s.strip
      raise Invalid.new(key, "must not be empty") if required && s.empty?
      s.presence
    end

    private def self.strings(key, value : JSON::Any) : Array(String)
      list = value.as_a? || raise Invalid.new(key, "list of strings expected")
      list.map { |v| v.as_s?.try(&.strip) || raise Invalid.new(key, "list of strings expected") }.reject(&.empty?).uniq
    end

    private def self.json(value) : JSON::Any
      JSON.parse(value.to_json)
    end
  end
end
