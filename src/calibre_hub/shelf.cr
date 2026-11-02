require "json"
require "./edit"

module CalibreHub
  # Magic shelves: a reading list whose books come from a rule instead of
  # being added one by one. The rule is a list of conditions joined by AND
  # (match "all") or OR (match "any"), stored as JSON with the list and
  # turned into one calibre search:
  #
  #   {"match": "all", "conditions": [
  #     {"field": "tag", "value": "Krimi"},
  #     {"field": "language", "value": "deu", "not": true}]}
  #   -> (tags:"=Krimi") and (not (languages:"=deu"))
  #
  # Fields: tag, kategorie (incl. the categories below it; stored with dots
  # like calibre, "A/B" is taken as "A.B"), author, series, language
  # (calibre's code, "deu") and text (calibre search syntax as typed in the
  # search bar).
  module Shelf
    FIELDS         = %w(tag kategorie author series language text)
    MATCHES        = %w(all any)
    MAX_CONDITIONS =  20
    MAX_VALUE      = 500

    # A checked, normalized rule (match, conditions with field, value and
    # not only when true)
    def self.parse(value : JSON::Any, kategorie_column : String?) : JSON::Any
      h = value.as_h? || raise Edit::Invalid.new("rule", "object with match and conditions expected")
      h.each_key { |k| raise Edit::Invalid.new("rule", "unknown field #{k}") unless {"match", "conditions"}.includes?(k) }
      match = h["match"]?.try(&.as_s?) || "all"
      raise Edit::Invalid.new("rule", "match: one of #{MATCHES.join(", ")}") unless MATCHES.includes?(match)
      raw = h["conditions"]?.try(&.as_a?) || raise Edit::Invalid.new("rule", "conditions expected")
      raise Edit::Invalid.new("rule", "at least one condition") if raw.empty?
      raise Edit::Invalid.new("rule", "at most #{MAX_CONDITIONS} conditions") if raw.size > MAX_CONDITIONS
      conditions = raw.map do |c|
        ch = c.as_h? || raise Edit::Invalid.new("rule", "condition: object expected")
        ch.each_key { |k| raise Edit::Invalid.new("rule", "condition: unknown field #{k}") unless {"field", "value", "not"}.includes?(k) }
        field = ch["field"]?.try(&.as_s?)
        raise Edit::Invalid.new("rule", "field: one of #{FIELDS.join(", ")}") unless field && FIELDS.includes?(field)
        raise Edit::Invalid.new("rule", "kategorie: no category column") if field == "kategorie" && !kategorie_column
        v = (ch["value"]?.try(&.as_s?) || raise Edit::Invalid.new("rule", "value: string expected")).strip
        raise Edit::Invalid.new("rule", "value expected") if v.empty?
        raise Edit::Invalid.new("rule", "value: at most #{MAX_VALUE} characters") if v.size > MAX_VALUE
        raise Edit::Invalid.new("rule", "value: no control characters") if v.matches?(/[\x00-\x1f]/)
        v = v.split(/\s*[\/.]\s*/).reject(&.empty?).join('.') if field == "kategorie"
        neg = ch["not"]?
        raise Edit::Invalid.new("rule", "not: true or false expected") if neg && neg.as_bool?.nil? && !neg.raw.nil?
        cond = {"field" => JSON::Any.new(field), "value" => JSON::Any.new(v)}
        cond["not"] = JSON::Any.new(true) if neg.try(&.as_bool?)
        JSON::Any.new(cond)
      end
      JSON::Any.new({"match" => JSON::Any.new(match), "conditions" => JSON::Any.new(conditions)})
    end

    # The calibre search for a rule
    def self.query(rule : JSON::Any, kategorie_column : String?) : String
      joiner = rule["match"]?.try(&.as_s?) == "any" ? " or " : " and "
      parts = rule["conditions"].as_a.map do |c|
        v = c["value"].as_s
        term = case c["field"].as_s
               when "tag"       then %(tags:"=#{escape(v)}")
               when "kategorie" then %(##{kategorie_column || "kategorie"}:"=.#{escape(v)}")
               when "author"    then %(authors:"=#{escape(v)}")
               when "series"    then %(series:"=#{escape(v)}")
               when "language"  then %(languages:"=#{escape(v)}")
               else                  "(#{v})"
               end
        c["not"]?.try(&.as_bool?) ? "not (#{term})" : term
      end
      parts.size > 1 ? parts.map { |p| "(#{p})" }.join(joiner) : parts.first
    end

    def self.escape(value : String) : String
      value.gsub('\\', "\\\\").gsub('"', "\\\"")
    end
  end
end
