require "http/client"
require "html"
require "json"
require "uri"
require "digest/sha1"
require "./book"
require "./calibre"
require "./writer"

module CalibreHub
  # Prompt and answer of the category classifier. Pure, so the rules can be
  # tested without a model. Categories are dotted as calibre stores them
  # ("Sachbuch.Geschichte") but shown to the model as paths
  # ("Sachbuch/Geschichte"), like the web app does.
  module Classifier
    record Answer, category : String?, confidence : Float64, reason : String

    # The answer can't be used (no JSON, fields missing); worth asking again
    class BadAnswer < Exception
    end

    # The model named a category that isn't in the tree: discarded
    class UnknownCategory < Exception
    end

    MAX_DESCRIPTION = 1200
    MAX_REASON      =  300
    # never sent to the model: it says nothing about the book
    TAG            = "auto-kategorie"
    IGNORED_TAGS   = [TAG]
    MIN_CATEGORIES = 2

    SYSTEM = <<-TXT
      You sort the books of a private library into its existing category tree.
      Pick exactly one category from the list the user gives, written exactly
      as listed. Prefer the most specific category that fits; take a parent
      category only when none of its children fits. Never invent a category.
      If no category fits, answer with an empty category and confidence 0.
      confidence is your probability (0 to 1) that a librarian would file the
      book there; above 0.85 only when title, description or tags make it
      obvious. reason: one short sentence in German.
      Answer only with JSON: {"category": "...", "confidence": 0.0, "reason": "..."}
      TXT

    def self.label(dotted : String) : String
      dotted.split('.').join('/')
    end

    # "A/B", "A › B" and "A.B" all become "A.B"; nil when empty
    def self.normalize(input : String) : String?
      text = input.strip
      parts = text.split(text.matches?(/[\/›]/) ? /[\/›]/ : /\./).map(&.strip).reject(&.empty?)
      parts.empty? ? nil : parts.join('.')
    end

    # Every node of the tree, parents included, from calibre's dotted values
    def self.paths(values : Array(String)) : Array(String)
      set = Set(String).new
      values.each do |v|
        parts = v.split('.')
        (1..parts.size).each { |n| set << parts[0, n].join('.') }
      end
      set.to_a.sort
    end

    # changes when categories are added, renamed or removed
    def self.tree_hash(paths : Array(String)) : String
      Digest::SHA1.hexdigest(paths.sort.join('\n'))[0, 12]
    end

    # Book comments are HTML; the model gets plain text, cut at a word
    def self.text(html : String?, max = MAX_DESCRIPTION) : String
      return "" unless html
      plain = HTML.unescape(html.gsub(/<(script|style)\b.*?<\/\1>/im, " ").gsub(/<[^>]*>/, " "))
      plain = plain.gsub(/\s+/, " ").strip
      return plain if plain.size <= max
      cut = plain[0, max]
      cut = cut[0, cut.rindex(' ') || max]
      "#{cut.rstrip} …"
    end

    def self.messages(book : Book, paths : Array(String)) : Array(Hash(String, String))
      lines = ["Categories:"]
      paths.each { |p| lines << "- #{label(p)}" }
      lines << ""
      lines << "Book:"
      lines << "Title: #{book.title}"
      lines << "Authors: #{book.authors.join(", ")}" unless book.authors.empty?
      book.series.try { |s| lines << "Series: #{s}" }
      tags = book.tags.reject { |t| IGNORED_TAGS.includes?(t) }
      lines << "Tags: #{tags.join(", ")}" unless tags.empty?
      book.publisher.try { |p| lines << "Publisher: #{p}" }
      lines << "Language: #{book.languages.join(", ")}" unless book.languages.empty?
      description = text(book.comments)
      lines << "Description: #{description}" unless description.empty?
      [{"role" => "system", "content" => SYSTEM}, {"role" => "user", "content" => lines.join('\n')}]
    end

    # Ollama's structured output: the enum keeps the model inside the tree
    def self.schema(paths : Array(String)) : JSON::Any
      JSON.parse({
        type:       "object",
        properties: {
          category:   {type: "string", enum: paths.map { |p| label(p) } + [""]},
          confidence: {type: "number", minimum: 0, maximum: 1},
          reason:     {type: "string"},
        },
        required: %w(category confidence reason),
      }.to_json)
    end

    # category nil: the model found nothing that fits
    def self.parse(content : String, paths : Array(String)) : Answer
      json = JSON.parse(content) rescue raise BadAnswer.new("no JSON: #{content[0, 100]}")
      h = json.as_h? || raise BadAnswer.new("JSON object expected")
      raw = h["category"]?.try(&.as_s?) || raise BadAnswer.new("category missing")
      confidence = h["confidence"]?.try { |c| c.as_f? || c.as_i64?.try(&.to_f) || c.as_s?.try(&.to_f?) }
      raise BadAnswer.new("confidence missing") unless confidence
      confidence = 0.0 if confidence.nan?
      confidence = confidence.clamp(0.0, 1.0)
      reason = h["reason"]?.try(&.as_s?).try(&.strip) || ""
      reason = "#{reason[0, MAX_REASON]}…" if reason.size > MAX_REASON
      category = normalize(raw)
      if category && !paths.includes?(category)
        raise UnknownCategory.new("unknown category #{raw.inspect} discarded")
      end
      Answer.new(category, category ? confidence : 0.0, reason)
    end

    # auto: applied right away; only for books without a category
    def self.status(answer : Answer, threshold : Float64, has_category : Bool) : String
      return "none" unless answer.category
      !has_category && answer.confidence >= threshold ? "auto" : "pending"
    end
  end

  # Minimal client for Ollama's /api/chat
  class Ollama
    # Model not reachable or not answering; stops a classify job
    class Unavailable < Exception
    end

    getter model : String

    def initialize(endpoint : String, @model : String, @timeout : Time::Span = 5.minutes,
                   @attempts = 3, @backoff : Time::Span = 5.seconds)
      @uri = URI.parse(endpoint)
    end

    # The answer's content; retries timeouts, connection errors and 5xx
    def chat(messages, format : JSON::Any) : String
      body = {
        model:    @model,
        messages: messages,
        stream:   false,
        format:   format,
        options:  {temperature: 0, num_ctx: 4096},
      }.to_json
      path = "#{@uri.path.rstrip('/')}/api/chat"
      last = ""
      @attempts.times do |attempt|
        sleep @backoff * (2 ** (attempt - 1)) if attempt > 0
        begin
          client = HTTP::Client.new(@uri)
          client.connect_timeout = 5.seconds
          client.read_timeout = @timeout
          client.write_timeout = 30.seconds
          r = client.post(path, headers: HTTP::Headers{"Content-Type" => "application/json"}, body: body)
          if r.success?
            json = JSON.parse(r.body) rescue raise Classifier::BadAnswer.new("no JSON from #{path}")
            return json["message"]?.try(&.["content"]?).try(&.as_s?) || raise Classifier::BadAnswer.new("no message in answer")
          end
          error = (JSON.parse(r.body)["error"]?.try(&.as_s?) rescue nil) || r.body[0, 200]
          # e.g. 404 "model not found, try pulling it first": asking again won't help
          raise Unavailable.new("#{@model}: HTTP #{r.status_code} #{error}") if r.status_code < 500
          last = "HTTP #{r.status_code} #{error}"
        rescue ex : IO::Error | Socket::Error
          last = ex.message || ex.class.name
        ensure
          client.try &.close
        end
      end
      raise Unavailable.new("#{@model} at #{@uri}: #{last} (#{@attempts} attempts)")
    end
  end

  # The latest suggestion per book, in the state DB
  class Suggestions
    STATUSES = %w(pending auto applied rejected none)

    struct Suggestion
      include JSON::Serializable

      @[JSON::Field(key: "bookId")]
      getter book_id : Int64
      @[JSON::Field(emit_null: true)]
      getter category : String?
      getter confidence : Float64
      getter reason : String
      getter model : String
      getter at : Time
      getter status : String
      @[JSON::Field(ignore: true)]
      getter tree : String

      def initialize(@book_id, @category, @confidence, @reason, @model, @at, @status, @tree)
      end
    end

    def initialize(@db : DB::Database)
      @db.exec <<-SQL
        create table if not exists suggestions (
          book_id integer primary key,
          category text,
          confidence real not null,
          reason text not null,
          model text not null,
          at integer not null,
          status text not null,
          tree text not null
        )
        SQL
    end

    def []?(id : Int64) : Suggestion?
      @db.query_one?("select #{COLUMNS} from suggestions where book_id = ?", id) { |rs| read(rs) }
    end

    def list(status : String? = nil) : Array(Suggestion)
      list = [] of Suggestion
      if status
        @db.query_each("select #{COLUMNS} from suggestions where status = ? order by at desc, book_id", status) { |rs| list << read(rs) }
      else
        @db.query_each("select #{COLUMNS} from suggestions order by at desc, book_id") { |rs| list << read(rs) }
      end
      list
    end

    def count(status : String) : Int64
      @db.query_one("select count(*) from suggestions where status = ?", status, as: Int64)
    end

    def save(s : Suggestion)
      @db.exec "insert or replace into suggestions (#{COLUMNS}) values (?, ?, ?, ?, ?, ?, ?, ?)",
        s.book_id, s.category, s.confidence, s.reason, s.model, s.at.to_unix, s.status, s.tree
    end

    def set(id : Int64, status : String, category : String? = nil)
      if category
        @db.exec "update suggestions set status = ?, category = ? where book_id = ?", status, category, id
      else
        @db.exec "update suggestions set status = ? where book_id = ?", status, id
      end
    end

    def delete(id : Int64)
      @db.exec "delete from suggestions where book_id = ?", id
    end

    COLUMNS = "book_id, category, confidence, reason, model, at, status, tree"

    private def read(rs) : Suggestion
      Suggestion.new(rs.read(Int64), rs.read(String?), rs.read(Float64), rs.read(String), rs.read(String),
        Time.unix(rs.read(Int64)), rs.read(String), rs.read(String))
    end
  end

  # Suggests a category from the existing tree for a book, applies it when
  # the model is sure enough, and takes the user's decision on the rest.
  class Classify
    # Too few categories to choose from; the hub suggests nothing
    class TooFewCategories < Exception
      getter count : Int32

      def initialize(@count)
        super("too few categories (#{@count}), create at least #{Classifier::MIN_CATEGORIES} first")
      end
    end

    getter suggestions : Suggestions
    getter threshold : Float64
    getter column : String
    @paths_at : Time

    def initialize(@calibre : Calibre, @writer : Writer, @column : String, @suggestions : Suggestions,
                   @ollama : Ollama, @threshold : Float64 = 0.85, @answer_attempts = 2)
      @paths = [] of String
      @paths_at = Time::UNIX_EPOCH
    end

    def model : String
      @ollama.model
    end

    # Category paths (dotted), cached for a minute while a job runs
    def paths(fresh = false) : Array(String)
      return @paths if !fresh && Time.utc - @paths_at < 1.minute
      values = (@calibre.categories["##{@column}"]? || [] of NamedTuple(name: String, count: Int32)).map(&.[:name])
      @paths_at = Time.utc
      @paths = Classifier.paths(values)
    end

    def category(book : Book) : String?
      book.custom[@column]?.try(&.as_s?).presence
    end

    # Asks the model about one book and stores the answer. only_unsorted:
    # a book that got a category in the meantime is skipped (nil).
    def classify(id : Int64, only_unsorted = false) : Suggestions::Suggestion?
      book = @calibre.book(id) || raise Writer::NotFound.new
      has_category = !category(book).nil?
      return nil if only_unsorted && has_category
      tree = paths
      raise TooFewCategories.new(tree.size) if tree.size < Classifier::MIN_CATEGORIES
      answer = ask(book, tree)
      status = Classifier.status(answer, @threshold, has_category)
      s = Suggestions::Suggestion.new(id, answer.category, answer.confidence, answer.reason, model, Time.utc,
        status == "auto" ? "pending" : status, Classifier.tree_hash(tree))
      @suggestions.save(s)
      if status == "auto"
        # changed while the model thought (409): stays pending for review
        @writer.update(id, {"kategorie" => JSON::Any.new(answer.category), "addTags" => JSON.parse([Classifier::TAG].to_json),
                            "lastModified" => JSON::Any.new(book.version)})
        @suggestions.set(id, "auto")
      end
      @suggestions[id]?
    end

    # The user takes the suggestion, or another category
    def accept(id : Int64, override : String? = nil) : Suggestions::Suggestion
      s = @suggestions[id]? || raise Writer::NotFound.new
      category = if o = override
                   Classifier.normalize(o) || raise Edit::Invalid.new("category", "must not be empty")
                 else
                   s.category || raise Edit::Invalid.new("category", "no suggested category, name one")
                 end
      @writer.update(id, {"kategorie" => JSON::Any.new(category)})
      @suggestions.set(id, "applied", category)
      @suggestions[id]?.not_nil!
    end

    def reject(id : Int64) : Suggestions::Suggestion
      @suggestions[id]? || raise Writer::NotFound.new
      @suggestions.set(id, "rejected")
      @suggestions[id]?.not_nil!
    end

    # Unsorted books still worth asking: no open suggestion, and none
    # rejected or without a fit for the current tree
    def worth_asking?(id : Int64, tree : String) : Bool
      s = @suggestions[id]? || return true
      case s.status
      when "pending"          then false
      when "rejected", "none" then s.tree != tree
      else                         true
      end
    end

    private def ask(book : Book, tree : Array(String)) : Classifier::Answer
      messages = Classifier.messages(book, tree)
      schema = Classifier.schema(tree)
      error = nil
      @answer_attempts.times do
        begin
          return Classifier.parse(@ollama.chat(messages, schema), tree)
        rescue ex : Classifier::BadAnswer
          error = ex
        end
      end
      raise error.not_nil!
    end
  end

  # Classify runs: over the unsorted books (API, nightly), chosen books
  # (API) and newly added books (events). A queue of its own, so a long
  # run doesn't hold up bulk edits.
  class ClassifyJobs < Jobs
    getter classify : Classify

    def initialize(db : DB::Database, calibre : Calibre, writer : Writer, @classify : Classify)
      super(db, calibre, writer, @classify.column, "classify_jobs")
    end

    # target: "unsorted", {ids: [...]} or {query: {...}}
    def submit_target(target : JSON::Any?) : Job
      tree = @classify.paths(fresh: true)
      raise Classify::TooFewCategories.new(tree.size) if tree.size < Classifier::MIN_CATEGORIES
      if target.try(&.as_s?) == "unsorted"
        hash = Classifier.tree_hash(tree)
        ids = unsorted.select { |id| @classify.worth_asking?(id, hash) }
        enqueue(ids, {"onlyUnsorted" => JSON::Any.new(true)})
      else
        enqueue(ids(target), {} of String => JSON::Any)
      end
    end

    def unsorted : Array(Int64)
      @calibre.search("##{@classify.column}:false", "id", true, 0, 1_000_000).ids
    end

    # Nightly run over the unsorted books at HH:MM local time
    def schedule(at : String)
      spawn do
        last = Time.local
        loop do
          sleep 30.seconds
          next unless CalibreHub.reconcile_due?(at, last)
          last = Time.local
          begin
            next if running?
            job = submit_target(JSON::Any.new("unsorted"))
            puts "classify: nightly run #{job.id} over #{job.total} books"
          rescue ex
            STDERR.puts "classify: nightly run not started: #{ex.message}"
          end
        end
      end
    end

    # Books added without a category get classified: follows the event
    # table with a cursor of its own (meta classify_event_seq)
    def watch_events(interval = 10.seconds)
      if @db.query_one?("select value from meta where key = 'classify_event_seq'", as: String).nil?
        max = @db.query_one("select coalesce(max(id), 0) from events", as: Int64)
        @db.exec "insert or replace into meta (key, value) values ('classify_event_seq', ?)", max.to_s
      end
      spawn do
        loop do
          begin
            follow_events
          rescue ex
            STDERR.puts "classify: events: #{ex.message}"
          end
          sleep interval
        end
      end
    end

    def follow_events
      cursor = @db.query_one("select value from meta where key = 'classify_event_seq'", as: String).to_i64
      ids = [] of Int64
      last = cursor
      @db.query_each("select id, type, book_id, payload from events where id > ? order by id limit 500", cursor) do |rs|
        last, type, book_id, payload = rs.read(Int64, String, Int64, String)
        next unless type == "added"
        book = JSON.parse(payload)["book"]?
        ids << book_id unless book.try(&.["custom"]?).try(&.[@classify.column]?).try(&.as_s?).presence
      end
      return if last == cursor
      unless ids.empty?
        tree = @classify.paths(fresh: true)
        if tree.size < Classifier::MIN_CATEGORIES
          STDERR.puts "classify: #{ids.size} new books not classified, too few categories (#{tree.size})"
        else
          job = enqueue(ids.uniq, {"onlyUnsorted" => JSON::Any.new(true)})
          puts "classify: job #{job.id} for #{job.total} new books"
        end
      end
      @db.exec "update meta set value = ? where key = 'classify_event_seq'", last.to_s
    end

    protected def apply(job : Job, index : Int32, id : Int64, resumed : Bool)
      @classify.classify(id, only_unsorted: job.changes["onlyUnsorted"]?.try(&.as_bool?) || false)
    rescue ex : Ollama::Unavailable
      raise Abort.new("model unavailable: #{ex.message}")
    rescue ex : Calibre::Unavailable
      raise Abort.new(ex.message)
    rescue ex : Classify::TooFewCategories
      raise Abort.new(ex.message)
    end
  end
end
