require "json"
require "./book"
require "./meta_rules"

module CalibreHub
  # Finding duplicates, without calibre-server (pure, so the rules can be
  # tested on their own). Two books are a pair when they share
  #   - isbn: an ISBN (identifiers, or one in a download-site title),
  #   - file: a format file with the same size and checksum,
  #   - title: an author (normalized like the author unification) and a
  #     title at least `threshold` alike (main titles, token sets; one title
  #     the start of the other counts 0.9). A book without a known author
  #     needs 0.9 at least.
  # A broken book (no files, or only files below TINY bytes: a download
  # leftover) pairs with a good one from BROKEN_THRESHOLD on and gets the
  # reason broken in every pair. Pairs join into groups (one book in two
  # pairs joins them).
  module Dedup
    DEFAULT_THRESHOLD = 0.85
    MIN_THRESHOLD     =  0.5
    # a book without a known author only matches this alike
    UNKNOWN_THRESHOLD = 0.9
    # a file below this size is broken
    TINY = 2048_i64
    # a broken book pairs with a good copy from this title similarity on
    BROKEN_THRESHOLD = 0.6
    # formats in order of preference for the book that stays
    FORMATS = %w(EPUB KEPUB AZW3 MOBI AZW FB2 PDF DJVU CBZ CBR DOCX ODT RTF HTMLZ TXT)
    KINDS   = %w(isbn file title broken)
    # fields the merge fills in the book that stays (PATCH names)
    FIELDS = %w(authors series seriesIndex publisher pubdate languages comments rating kategorie identifiers tags)

    # A format file; path: where it is in the library (nil: unknown)
    struct FileInfo
      getter format : String
      getter size : Int64
      getter path : String?

      def initialize(@format, @size, @path = nil)
      end

      def tiny? : Bool
        size < TINY
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "format", format
          json.field "size", size
          json.field "tiny", tiny?
        end
      end
    end

    # One reason two books are a pair; detail: the ISBN, the format, the similarity
    record Reason, kind : String, a : Int64, b : Int64, detail : String? do
      def to_json(json : JSON::Builder)
        json.object do
          json.field "kind", kind
          json.field "bookIds", [a, b]
          json.field "detail", detail
        end
      end
    end

    # A book prepared for comparing
    class Item
      getter book : Book
      # nil: the sizes are unknown (no library path)
      getter files : Array(FileInfo)?
      getter title : String
      getter title_key : String
      getter full_key : String
      getter main_tokens : Array(String)
      getter all_tokens : Array(String)
      getter author_keys : Set(String)
      getter isbns : Set(String)
      getter volume : String?
      # a standard (DIN, ISO …): editions and parts are different books
      getter norm : Meta::Norms::Norm?

      def initialize(@book : Book, @files : Array(FileInfo)? = nil)
        title = book.title
        authors = book.authors
        # Anna's Archive file names: "Title -- Author -- Edition -- Publisher -- ISBN -- hash -- Anna's Archive"
        parts = title.split(/\s+--\s+/)
        if parts.size >= 3
          title = parts[0]
          authors = [parts[1].strip] if Meta::Clean.unknown_authors?(authors) && !parts[1].strip.empty?
        end
        @title = Meta::Clean.strip_junk(title)
        main = Meta::Text.main_title(@title)
        @title_key = Meta::Text.key(main)
        @full_key = Meta::Text.key(@title)
        @main_tokens = Meta::Text.tokens(main)
        @all_tokens = Meta::Text.tokens(@title)
        @author_keys = authors.reject { |a| Meta::Clean.unknown_author?(a) }.map { |a| Meta::Authors.key(a) }.reject(&.empty?).to_set
        @isbns = Set(String).new
        book.identifiers.each { |k, v| Meta::Isbn.normalize(v).try { |i| @isbns << i } if k.downcase.starts_with?("isbn") }
        Meta::Isbn.scan(book.title).each { |i| @isbns << i }
        @volume = Meta::Text.volume(book.title)
        @norm = Meta::Norms.parse(book)
      end

      def id : Int64
        book.id
      end

      def subtitle? : Bool
        main_tokens.size < all_tokens.size
      end

      # no files, or only tiny ones
      def broken? : Bool
        return true if book.formats.empty?
        f = files || return false
        !f.empty? && f.all?(&.tiny?)
      end

      def tiny_formats : Array(String)
        files.try(&.select(&.tiny?).map(&.format)) || [] of String
      end

      def good_formats : Array(String)
        tiny = tiny_formats
        book.formats.reject { |f| tiny.includes?(f) }
      end
    end

    # 0..1: 1 for the same title (ignoring case, accents, punctuation), 0.95
    # when only one has a subtitle, 0.9 when one title starts with the other
    # (3 words at least), else the token overlap of the main titles (of the
    # whole titles when both have a subtitle)
    def self.similarity(a : Item, b : Item) : Float64
      return 0.0 if a.title_key.empty? || b.title_key.empty?
      return 1.0 if a.full_key == b.full_key
      short, long = a.all_tokens.size <= b.all_tokens.size ? {a, b} : {b, a}
      prefix = short.all_tokens.size >= 3 && long.all_tokens[0, short.all_tokens.size] == short.all_tokens
      if a.subtitle? && b.subtitle?
        return 0.9 if prefix
        return dice(a.all_tokens, b.all_tokens)
      end
      return 0.95 if a.title_key == b.title_key
      return 0.9 if prefix
      dice(a.main_tokens, b.main_tokens)
    end

    def self.dice(a : Array(String), b : Array(String)) : Float64
      sa, sb = a.to_set, b.to_set
      return 0.0 if sa.empty? || sb.empty?
      2.0 * (sa & sb).size / (sa.size + sb.size)
    end

    # The same title and the same authors after normalization, not one
    # author in common or a title a subtitle apart: what may go without a
    # person looking at it. A book without a known author is never that.
    def self.same_book?(a : Item, b : Item) : Bool
      return false if a.title_key.empty? || a.author_keys.empty?
      a.full_key == b.full_key && a.author_keys == b.author_keys && !different_parts?(a, b)
    end

    # Volume 1 and 2, two numbers of one series, two editions of a
    # standard are never the same book
    def self.different_parts?(a : Item, b : Item) : Bool
      return true if (va = a.volume) && (vb = b.volume) && va != vb
      if (na = a.norm) && (nb = b.norm)
        return true if {na.id, na.draft, na.corrigendum} != {nb.id, nb.draft, nb.corrigendum}
      end
      sa, sb = a.book.series, b.book.series
      if sa && sb && Meta::Text.key(sa) == Meta::Text.key(sb)
        return a.book.series_index != b.book.series_index
      end
      false
    end

    # The title reason of a pair, nil when the titles don't match
    def self.title_reason(a : Item, b : Item, threshold : Float64) : Array(Reason)
      return [] of Reason if different_parts?(a, b)
      s = similarity(a, b)
      reasons = [] of Reason
      shared = !(a.author_keys & b.author_keys).empty?
      unknown = a.author_keys.empty? || b.author_keys.empty?
      if (shared && s >= threshold) || (unknown && s >= Math.max(threshold, UNKNOWN_THRESHOLD))
        reasons << Reason.new("title", a.id, b.id, s.round(2).to_s)
      end
      if a.broken? != b.broken? && s >= BROKEN_THRESHOLD && (shared || unknown)
        reasons << Reason.new("broken", a.id, b.id, (a.broken? ? a : b).id.to_s)
      end
      reasons
    end

    # checksum of a file (nil when unreadable); only asked for files whose
    # format and size another file has too
    alias Checksum = Proc(FileInfo, String?)

    # All pairs with their reasons; ignored: pairs {a, b} (a < b) marked as
    # no duplicates
    def self.pairs(items : Array(Item), threshold = DEFAULT_THRESHOLD, checksum : Checksum? = nil,
                   ignored = Set({Int64, Int64}).new) : Hash({Int64, Int64}, Array(Reason))
      threshold = threshold.clamp(MIN_THRESHOLD, 1.0)
      by_id = items.index_by(&.id)
      found = {} of {Int64, Int64} => Array(Reason)
      add = ->(r : Reason) do
        key = r.a < r.b ? {r.a, r.b} : {r.b, r.a}
        return if r.a == r.b || ignored.includes?(key)
        list = found[key] ||= [] of Reason
        list << r unless list.any? { |x| x.kind == r.kind }
      end

      # the same ISBN
      by_isbn = Hash(String, Array(Item)).new { |h, k| h[k] = [] of Item }
      items.each { |i| i.isbns.each { |isbn| by_isbn[isbn] << i } }
      by_isbn.each do |isbn, list|
        list.each_combination(2) { |(a, b)| add.call(Reason.new("isbn", a.id, b.id, isbn)) } if list.size > 1
      end

      # the same file: format and size first, the checksum only then
      if checksum
        by_size = Hash({String, Int64}, Array({Item, FileInfo})).new { |h, k| h[k] = [] of {Item, FileInfo} }
        items.each { |i| i.files.try &.each { |f| by_size[{f.format.upcase, f.size}] << {i, f} unless f.tiny? } }
        by_size.each do |(format, _), list|
          next if list.size < 2
          sums = list.compact_map { |i, f| checksum.call(f).try { |s| {i, s} } }
          sums.group_by(&.[1]).each_value do |same|
            same.map(&.[0]).uniq.each_combination(2) { |(a, b)| add.call(Reason.new("file", a.id, b.id, format)) }
          end
        end
      end

      # titles: books sharing an author; books without a known author
      # against every book sharing the first title word
      compared = Set({Int64, Int64}).new
      compare = ->(a : Item, b : Item) do
        return if a.id == b.id
        key = a.id < b.id ? {a.id, b.id} : {b.id, a.id}
        return unless compared.add?(key)
        title_reason(a, b, threshold).each { |r| add.call(r) }
      end
      by_author = Hash(String, Array(Item)).new { |h, k| h[k] = [] of Item }
      by_word = Hash(String, Array(Item)).new { |h, k| h[k] = [] of Item }
      items.each do |i|
        i.author_keys.each { |k| by_author[k] << i }
        i.all_tokens.first?.try { |w| by_word[w] << i }
      end
      by_author.each_value { |list| list.each_combination(2) { |(a, b)| compare.call(a, b) } if list.size > 1 }
      items.each do |i|
        next unless i.author_keys.empty?
        i.all_tokens.first?.try { |w| by_word[w].each { |o| compare.call(i, o) } }
      end

      # a broken book next to a good one, whatever paired them
      found.each do |(a, b), reasons|
        ia, ib = by_id[a], by_id[b]
        if ia.broken? != ib.broken? && reasons.none? { |r| r.kind == "broken" }
          reasons << Reason.new("broken", a, b, (ia.broken? ? ia : ib).id.to_s)
        end
      end
      found
    end

    # Groups of book ids (each sorted), joined over shared books
    def self.groups(pairs : Hash({Int64, Int64}, Array(Reason))) : Array(Array(Int64))
      parent = {} of Int64 => Int64
      find = ->(x : Int64) do
        while (p = parent[x]?) && p != x
          x = p
        end
        x
      end
      pairs.each_key do |(a, b)|
        ra, rb = find.call(a), find.call(b)
        parent[Math.max(ra, rb)] = Math.min(ra, rb) if ra != rb
      end
      ids = pairs.keys.flat_map { |(a, b)| [a, b] }.uniq
      ids.group_by { |i| find.call(i) }.values.map(&.sort).sort_by(&.first)
    end

    # How good a copy is, compared field by field (higher wins): not broken,
    # the most complete metadata, the best format, the most formats
    def self.quality(item : Item, has_cover : Bool?, category_column : String? = nil) : Array(Int32)
      b = item.book
      complete = [
        !Meta::Clean.unknown_authors?(b.authors),
        b.identifiers.has_key?("isbn"),
        !b.publisher.nil?,
        !b.pubdate.nil?,
        !b.languages.empty?,
        !b.comments.to_s.strip.empty?,
        !b.series.nil?,
        has_cover == true,
        b.tags.any? { |t| t != Meta::TAG },
        !category_column.nil? && !b.custom[category_column]?.try(&.as_s?).to_s.empty?,
        !(b.title.includes?(" -- ") || Meta::Clean.junk?(b.title)),
      ].count(&.itself)
      good = item.good_formats
      best = good.map { |f| FORMATS.index(f.upcase) || FORMATS.size }.min? || FORMATS.size + 1
      [item.broken? ? 0 : 1, complete, FORMATS.size + 1 - best, good.size]
    end

    # The book that stays: the best copy, the oldest on a tie
    def self.keep(items : Array(Item), covers : Hash(Int64, Bool), category_column : String? = nil) : Int64
      items.sort_by { |i| quality(i, covers[i.id]?, category_column).map { |x| -x } + [i.id.to_i32] }.first.id
    end

    # A date calibre keeps as local midnight (23:00 UTC) as that day
    def self.day(t : Time?) : String?
      t.try { |x| x = x.to_utc; (x.hour >= 20 ? x + 4.hours : x).to_s("%F") }
    end

    # A field as the merge log and the PATCH body show it
    def self.value(b : Book, field : String, category_column : String? = nil) : JSON::Any
      case field
      when "authors"     then JSON.parse(b.authors.to_json)
      when "series"      then JSON::Any.new(b.series)
      when "seriesIndex" then JSON::Any.new(b.series ? b.series_index : nil)
      when "publisher"   then JSON::Any.new(b.publisher)
      when "pubdate"     then JSON::Any.new(day(b.pubdate))
      when "languages"   then JSON.parse(b.languages.to_json)
      when "comments"    then JSON::Any.new(b.comments.presence)
      when "rating"      then JSON::Any.new(b.rating.try(&.round.to_i64).try { |r| r == 0 ? nil : r })
      when "kategorie"   then JSON::Any.new(category_column.try { |c| b.custom[c]?.try(&.as_s?).presence })
      when "identifiers" then JSON.parse(b.identifiers.to_json)
      when "tags"        then JSON.parse(b.tags.to_json)
      else                    JSON::Any.new(nil)
      end
    end

    private def self.empty?(v : JSON::Any) : Bool
      v.raw.nil? || v.as_a?.try(&.empty?) || v.as_h?.try(&.empty?) || false
    end

    # What the others add to the book that stays: empty fields filled from
    # the first other that has them (series with its number), authors only
    # instead of unknown ones; identifiers and tags joined (the keeper's
    # value wins, the metadata cleanup's marker tag stays out). PATCH body.
    def self.fill(keep : Book, others : Array(Book), category_column : String? = nil) : Hash(String, JSON::Any)
      body = {} of String => JSON::Any
      others.each do |o|
        if Meta::Clean.unknown_authors?(keep.authors) && !body.has_key?("authors") && !Meta::Clean.unknown_authors?(o.authors)
          body["authors"] = value(o, "authors")
        end
        if keep.series.nil? && !body.has_key?("series") && o.series
          body["series"] = value(o, "series")
          body["seriesIndex"] = value(o, "seriesIndex")
        end
        %w(publisher pubdate languages comments rating).each do |f|
          next if body.has_key?(f) || !empty?(value(keep, f))
          v = value(o, f)
          body[f] = v unless empty?(v)
        end
        if category_column && !body.has_key?("kategorie") && empty?(value(keep, "kategorie", category_column))
          v = value(o, "kategorie", category_column)
          body["kategorie"] = v unless empty?(v)
        end
      end
      ids = keep.identifiers.dup
      others.each { |o| o.identifiers.each { |k, v| ids[k] = v unless ids.has_key?(k) } }
      body["identifiers"] = JSON.parse(ids.to_json) if ids.size > keep.identifiers.size
      tags = keep.tags.dup
      others.each do |o|
        o.tags.each do |t|
          next if t == Meta::TAG
          tags << t unless tags.any? { |x| x.downcase == t.downcase }
        end
      end
      body["tags"] = JSON.parse(tags.to_json) if tags.size > keep.tags.size
      body
    end
  end
end
