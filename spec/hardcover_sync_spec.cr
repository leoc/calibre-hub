require "spec"
require "../src/calibre_hub/hardcover_sync"

private alias Sync = CalibreHub::HardcoverSync

# calibre-server's list, enough for the sync
private class FakeCalibre
  getter books = {} of Int64 => Hash(String, JSON::Any)
  getter url : String

  def initialize
    @server = HTTP::Server.new do |ctx|
      body = JSON.parse(ctx.request.body.try(&.gets_to_end).presence || "null")
      ctx.response.content_type = "application/json"
      fields = body[0].as_a.map(&.as_s)
      ids = @books.keys
      data = fields.to_h { |f| {f, ids.to_h { |id| {id.to_s, @books[id][f]? || JSON::Any.new(nil)} }} }
      ctx.response.print({result: {book_ids: ids, data: data}}.to_json)
    end
    @url = "http://127.0.0.1:#{@server.bind_tcp("127.0.0.1", 0).port}"
    spawn { @server.listen }
  end

  def add(id : Int64, title : String, authors : Array(String), isbn : String? = nil, languages = [] of String)
    @books[id] = {
      "title"       => JSON::Any.new(title),
      "authors"     => JSON.parse(authors.to_json),
      "identifiers" => JSON.parse((isbn ? {"isbn" => isbn} : {} of String => String).to_json),
      "languages"   => JSON.parse(languages.to_json),
    }
  end

  def calibre : CalibreHub::Calibre
    CalibreHub::Calibre.new(url, "hub", "pw", nil, [] of String)
  end
end

# Hardcover's GraphQL for the queries and mutations the sync sends, with
# the user's library as state
private class FakeHardcover
  getter url : String
  getter mutations = [] of {String, JSON::Any}
  getter queries = [] of String
  # book id -> user book {id, status_id, edition_id, reads: [{id, started_at, finished_at, progress_pages}]}
  getter user_books = {} of Int64 => Hash(String, JSON::Any)
  # isbn -> {edition id, pages, book id}
  getter editions = {} of String => {Int64, Int32?, Int64}
  # the user's library for matching: {book id, isbn, title, author}
  getter own = [] of {Int64, String?, String, String}
  # Hardcover itself adds a read for a new "Currently Reading"
  property auto_read = false
  @next = 500_i64

  def initialize
    @server = HTTP::Server.new do |ctx|
      body = JSON.parse(ctx.request.body.not_nil!.gets_to_end)
      query = body["query"].as_s
      vars = body["variables"]
      ctx.response.content_type = "application/json"
      if query.starts_with?("mutation")
        name = query[/\{\s*(\w+)\(/, 1]
        @mutations << {name, vars}
        ctx.response.print({data: {name => mutate(name, vars)}}.to_json)
      else
        @queries << query
        ctx.response.print({data: answer(query, vars)}.to_json)
      end
    end
    @url = "http://127.0.0.1:#{@server.bind_tcp("127.0.0.1", 0).port}/hc"
    spawn { @server.listen }
  end

  def answer(query, vars)
    if query.includes?("user_books(order_by")
      {me: [{user_books: own.map { |b, isbn, title, author|
        {book_id: b, edition: isbn ? {id: b + 1, pages: 300, isbn_13: isbn, isbn_10: nil} : nil,
         book: {title: title, pages: nil, contributions: [{author: {name: author}, contribution: nil}]}}
      }}]}
    elsif query.includes?("user_books(where")
      ids = vars["ids"].as_a.map(&.as_i64)
      {me: [{user_books: @user_books.select { |b, _| ids.includes?(b) }.map { |b, ub|
        pages = editions.values.find { |e| e[0] == ub["edition_id"].as_i64? }.try(&.[1]) || 200
        {id: ub["id"], book_id: b, status_id: ub["status_id"], edition: {id: ub["edition_id"], pages: pages}, book: {pages: nil},
         user_book_reads: ub["reads"].as_a.reverse}
      }}]}
    elsif query.includes?("editions(where")
      e = editions[vars["isbn"].as_s]?
      {editions: e ? [{id: e[0], pages: e[1], book: {id: e[2], pages: nil}}] : [] of Nil}
    elsif query.includes?("search(")
      hits = vars["q"].as_s.starts_with?("Effortless") ? [{document: {id: "427508", title: "Effortless", author_names: ["Greg McKeown"]}}] : [] of Nil
      {search: {results: {hits: hits}}}
    elsif query.includes?("books(where")
      {books: [{id: 427508, pages: 256, editions: [{id: 1, pages: 256, language: {code3: "eng"}}, {id: 2, pages: 300, language: {code3: "deu"}}]}]}
    else
      raise "unexpected query #{query}"
    end
  end

  def mutate(name, vars)
    case name
    when "insert_user_book"
      o = vars["object"]
      id = (@next += 1)
      reads = auto_read ? [{"id" => (@next += 1), "started_at" => nil, "finished_at" => nil, "progress_pages" => nil}] : [] of Nil
      @user_books[o["book_id"].as_i64] = {"id" => JSON::Any.new(id), "status_id" => o["status_id"],
                                          "edition_id" => o["edition_id"]? || JSON::Any.new(nil), "reads" => JSON.parse(reads.to_json)}
      {id: id, error: nil}
    when "update_user_book"
      ub = @user_books.values.find { |u| u["id"] == vars["id"] }.not_nil!
      ub["status_id"] = vars["object"]["status_id"]
      {id: vars["id"], error: nil}
    when "insert_user_book_read"
      ub = @user_books.values.find { |u| u["id"] == vars["id"] }.not_nil!
      read = vars["read"].as_h.merge({"id" => JSON::Any.new(@next += 1)})
      ub["reads"] = JSON::Any.new(ub["reads"].as_a + [JSON::Any.new(read)])
      {id: @next, error: nil}
    when "update_user_book_read"
      ub = @user_books.values.find { |u| u["reads"].as_a.any? { |r| r["id"] == vars["id"] } }.not_nil!
      ub["reads"] = JSON::Any.new(ub["reads"].as_a.map { |r| r["id"] == vars["id"] ? JSON::Any.new(r.as_h.merge(vars["read"].as_h)) : r })
      {id: vars["id"], error: nil}
    else
      raise "unexpected mutation #{name}"
    end
  end

  def status(book : Int64) : Int64?
    @user_books[book]?.try(&.["status_id"].as_i64)
  end

  def reads(book : Int64) : Array(JSON::Any)
    @user_books[book]["reads"].as_a
  end
end

private def with_sync(write = false, &)
  path = File.tempname("hub-hardcover", ".sqlite")
  db = DB.open("sqlite3://#{path}?max_pool_size=1")
  calibre = FakeCalibre.new
  hc = FakeHardcover.new
  http = CalibreHub::Meta::Http.new(Time::Span.zero, 5.seconds)
  client = CalibreHub::Meta::Hardcover.new(http, "token", hc.url)
  progress = CalibreHub::Progress.new(db)
  sync = ->(w : Bool) { Sync.new(db, calibre.calibre, progress, client, "arthur", w) }
  yield sync, calibre, hc, progress, db
ensure
  db.try &.close
  File.delete?(path) if path
end

private def read_at(fraction : Float64, progress : CalibreHub::Progress, book : Int64, now : Time)
  progress.save("arthur", book, JSON.parse({format: "epub", position: "epubcfi(/6/2)", fraction: fraction, device: "web-1"}.to_json).as_h, now)
end

private def ub(status : Int32, reads = [] of Sync::Read) : Sync::UserBook
  Sync::UserBook.new(7_i64, 42_i64, status, 9_i64, 300, reads)
end

private MATCH = Sync::Match.new(42_i64, 9_i64, 300, "isbn")

describe CalibreHub::HardcoverSync do
  it "derives status and pages from the progress" do
    Sync.desired(0.01, 0.98).should be_nil
    Sync.desired(0.3, 0.98).should eq(Sync::READING)
    Sync.desired(0.98, 0.98).should eq(Sync::READ)
    Sync.pages_read(0.5, 300, Sync::READING).should eq(150)
    Sync.pages_read(0.001, 300, Sync::READING).should eq(1)
    Sync.pages_read(0.99, 300, Sync::READ).should eq(300)
  end

  it "only changes no status, Want to Read and Currently Reading" do
    add = Sync.status_action(nil, MATCH, Sync::READING).not_nil!
    add.query.should contain("insert_user_book(")
    add.variables["object"].should eq(JSON.parse(%({"book_id": 42, "status_id": 2, "edition_id": 9})))
    Sync.status_action(ub(1), MATCH, Sync::READING).not_nil!.text.should eq("set Want to Read -> Currently Reading")
    Sync.status_action(ub(2), MATCH, Sync::READ).not_nil!.variables["object"]["status_id"].should eq(3)
    Sync.status_action(ub(2), MATCH, Sync::READING).should be_nil
    # set on Hardcover by hand: Read (no re-read from the hub), Paused, DNF, Ignored
    {3, 4, 5, 6}.each { |s| Sync.status_action(ub(s), MATCH, Sync::READING).should be_nil }
    Sync.status_action(nil, MATCH, nil).should be_nil
  end

  it "keeps the pages in the open read and finishes it" do
    open = Sync::Read.new(70_i64, "2026-10-01", nil, 20)
    a = Sync.read_action(ub(2, [open]), Sync::READING, 150, 9_i64, "2026-11-02").not_nil!
    a.query.should contain("update_user_book_read(")
    a.variables["id"].should eq(70)
    a.variables["read"].should eq(JSON.parse(%({"progress_pages": 150, "edition_id": 9})))
    Sync.read_action(ub(2, [Sync::Read.new(70_i64, nil, nil, 150)]), Sync::READING, 150, 9_i64, "2026-11-02").should be_nil
    a = Sync.read_action(ub(2), Sync::READING, 150, nil, "2026-11-02").not_nil!
    a.query.should contain("insert_user_book_read(")
    a.variables["read"].should eq(JSON.parse(%({"started_at": "2026-11-02", "progress_pages": 150})))
    a = Sync.read_action(ub(3, [open]), Sync::READ, 300, 9_i64, "2026-11-02").not_nil!
    a.variables["read"].should eq(JSON.parse(%({"finished_at": "2026-11-02", "progress_pages": 300, "edition_id": 9})))
    # finished on that day already
    Sync.read_action(ub(3, [Sync::Read.new(70_i64, nil, "2026-11-02", 300)]), Sync::READ, 300, 9_i64, "2026-11-02").should be_nil
  end

  it "matches from the user's library, then by ISBN, then by a search" do
    data = JSON.parse(%({"me": [{"user_books": [
      {"book_id": 1, "edition": {"id": 11, "pages": 250, "isbn_13": "9780593135648", "isbn_10": null}, "book": {"title": "Effortless", "pages": null, "contributions": [{"author": {"name": "Greg McKeown"}, "contribution": null}]}},
      {"book_id": 2, "edition": null, "book": {"title": "Desintegriert euch!", "pages": 240, "contributions": [{"author": {"name": "Max Czollek"}, "contribution": "Author"}]}}]}]}))
    own = Sync.parse_own(data)
    Sync.own_match(own, "9780593135648", "x", [] of String).should eq(Sync::Match.new(1_i64, 11_i64, 250, "own-isbn"))
    Sync.own_match(own, nil, "Desintegriert euch", ["Max Czollek"]).should eq(Sync::Match.new(2_i64, nil, 240, "own-title"))
    Sync.own_match(own, nil, "Desintegriert euch", ["Someone Else"]).should be_nil
    Sync.edition_match(JSON.parse(%({"editions": [{"id": 5, "pages": null, "book": {"id": 6, "pages": 99}}]}))).should eq(Sync::Match.new(6_i64, 5_i64, 99, "isbn"))
    books = JSON.parse(%({"books": [{"id": 8, "pages": 256, "editions": [{"id": 81, "pages": 250, "language": {"code3": "eng"}}]}]}))
    q = CalibreHub::Meta::Query.new("Effortless", "Greg McKeown", ["eng"])
    Sync.search_match(books, q, [8_i64]).should eq(Sync::Match.new(8_i64, 81_i64, 250, "search"))
    Sync.search_match(books, CalibreHub::Meta::Query.new("Effortless", "Greg McKeown", ["deu"]), [8_i64]).should be_nil
  end

  it "maps the library in the background and looks up misses again later" do
    with_sync do |sync, calibre, hc|
      calibre.add(1, "Unbekannt", ["Niemand"])
      calibre.add(2, "Der Herr der Ringe", ["J.R.R. Tolkien"], isbn: "978-3-608-93828-9")
      calibre.add(3, "Effortless", ["Greg McKeown"], languages: ["eng"])
      calibre.add(4, "Small Giants", ["Bo Burlingham"], isbn: "9781591841494")
      calibre.add(5, "Gibt es nicht", ["Niemand"])
      hc.own << {215061_i64, "9781591841494", "Small Giants", "Bo Burlingham"}
      hc.editions["9783608938289"] = {900001_i64, 1200, 900000_i64}
      now = Time.utc
      s = sync.call(false)
      s.run(now).should eq({5, 0})
      s.match(calibre.calibre.books([2_i64]).first, now).should eq(Sync::Match.new(900000_i64, 900001_i64, 1200, "isbn"))
      s.match(calibre.calibre.books([3_i64]).first, now).should eq(Sync::Match.new(427508_i64, 1_i64, 256, "search"))
      s.match(calibre.calibre.books([4_i64]).first, now).should eq(Sync::Match.new(215061_i64, 215062_i64, 300, "own-isbn"))
      s.match(calibre.calibre.books([1_i64]).first, now).should be_nil
      hc.mutations.should be_empty
      # nothing due until the miss is old or a book changes
      queries = hc.queries.size
      s.run(now + 1.hour).should eq({0, 0})
      calibre.add(1, "Unbekannt", ["Niemand"], isbn: "9783608938289")
      s.run(now + 2.hours).should eq({1, 0})
      s.match(calibre.calibre.books([1_i64]).first, now).not_nil!.book.should eq(900000)
      hc.queries.size.should be > queries
      # the miss again after RECHECK
      s.run(now + 31.days).should eq({1, 0})
    end
  end

  it "logs the planned writes in a dry run and sends them once switched to write" do
    with_sync do |sync, calibre, hc, progress, db|
      calibre.add(2, "Der Herr der Ringe", ["J.R.R. Tolkien"], isbn: "9783608938289")
      hc.editions["9783608938289"] = {900001_i64, 1200, 900000_i64}
      now = Time.utc
      read_at(0.25, progress, 2, now)
      sync.call(false).run(now).should eq({0, 1})
      hc.mutations.should be_empty
      db.query_one("select dry_run from hardcover_sync where book_id = 2", as: Int64).should eq(1)
      # planned once per progress change
      sync.call(false).run(now).should eq({0, 0})

      w = sync.call(true)
      w.run(now).should eq({0, 1})
      hc.mutations.map(&.[0]).should eq(%w(insert_user_book insert_user_book_read))
      hc.status(900000).should eq(2)
      hc.reads(900000).first["progress_pages"].should eq(300)
      w.run(now).should eq({0, 0})

      # further on: the open read gets the pages
      read_at(0.5, progress, 2, now + 1.minute)
      w.run(now + 1.minute).should eq({0, 1})
      hc.mutations.last[0].should eq("update_user_book_read")
      hc.reads(900000).size.should eq(1)
      hc.reads(900000).first["progress_pages"].should eq(600)

      # at the end: Read, the read finished
      read_at(0.99, progress, 2, now + 2.minutes)
      w.run(now + 2.minutes)
      hc.mutations.last(2).map(&.[0]).should eq(%w(update_user_book update_user_book_read))
      hc.status(900000).should eq(3)
      hc.reads(900000).first["finished_at"].as_s.should match(/\A\d{4}-\d{2}-\d{2}\z/)

      # read again in the hub: Read on Hardcover stays
      count = hc.mutations.size
      read_at(0.1, progress, 2, now + 3.minutes)
      w.run(now + 3.minutes).should eq({0, 1})
      hc.mutations.size.should eq(count)
    end
  end

  it "uses the read Hardcover added itself and leaves hand-set statuses alone" do
    with_sync do |sync, calibre, hc, progress|
      calibre.add(2, "Der Herr der Ringe", ["J.R.R. Tolkien"], isbn: "9783608938289")
      calibre.add(3, "Effortless", ["Greg McKeown"], languages: ["eng"])
      hc.editions["9783608938289"] = {900001_i64, 1200, 900000_i64}
      hc.auto_read = true
      hc.user_books[427508_i64] = {"id" => JSON::Any.new(77_i64), "status_id" => JSON::Any.new(5_i64),
                                   "edition_id" => JSON::Any.new(nil), "reads" => JSON.parse("[]")}
      now = Time.utc
      read_at(0.25, progress, 2, now)
      read_at(0.25, progress, 3, now)
      sync.call(true).run(now).should eq({0, 2})
      hc.mutations.map(&.[0]).should eq(%w(insert_user_book update_user_book_read))
      hc.reads(900000).size.should eq(1)
      # Did Not Finish stays
      hc.status(427508).should eq(5)
    end
  end
end
