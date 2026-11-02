require "spec"
require "kemal"
require "../src/calibre_hub/api"

# calibre-server with a few books: list, categories, search, set-fields
private class FakeLibrary
  getter books = {} of Int64 => Hash(String, JSON::Any)
  getter writes = [] of {Int64, JSON::Any}
  getter url : String

  def initialize
    @server = HTTP::Server.new do |ctx|
      path = ctx.request.path
      body = JSON.parse(ctx.request.body.try(&.gets_to_end).presence || "null")
      ctx.response.content_type = "application/json"
      case path
      when "/cdb/cmd/list/0"
        search = body[3].as_s
        ids = search.empty? ? @books.keys : search.scan(/id:(\d+)/).map(&.[1].to_i64).select { |id| @books.has_key?(id) }
        fields = body[0].as_a.map(&.as_s.sub('*', '#'))
        data = fields.to_h { |f| {f, ids.to_h { |id| {id.to_s, @books[id][f]? || JSON::Any.new(nil)} }} }
        ctx.response.print({result: {book_ids: ids, data: data}}.to_json)
      when "/cdb/cmd/list_categories/0"
        counts = Hash(String, Int32).new(0)
        @books.each_value { |b| b["#kategorie"]?.try(&.as_s?).try { |k| counts[k] += 1 } }
        cats = {"#kategorie" => counts.map { |k, n| {name: k, count: n} }}
        ctx.response.print({result: [cats, {} of String => String]}.to_json)
      when "/ajax/search"
        ids = @books.select { |_, b| b["#kategorie"]?.try(&.as_s?).nil? }.keys
        ctx.response.print({total_num: ids.size, book_ids: ids}.to_json)
      when .starts_with?("/cdb/set-fields/")
        id = path.split('/')[3].to_i64
        changes = body["changes"]
        @writes << {id, changes}
        changes.as_h.each { |k, v| @books[id][k] = v unless k == "last_modified" }
        ctx.response.print "{}"
      else
        ctx.response.status_code = 404
      end
    end
    address = @server.bind_tcp("127.0.0.1", 0)
    @url = "http://127.0.0.1:#{address.port}"
    spawn { @server.listen }
  end

  def add(id : Int64, title : String, kategorie : String? = nil, tags = [] of String, comments : String? = nil)
    @books[id] = {
      "title"         => JSON::Any.new(title),
      "authors"       => JSON.parse(%(["Ada Lovelace"])),
      "tags"          => JSON.parse(tags.to_json),
      "comments"      => JSON::Any.new(comments),
      "last_modified" => JSON::Any.new("2026-11-02T10:00:00+00:00"),
      "#kategorie"    => JSON::Any.new(kategorie),
    }
  end

  def calibre : CalibreHub::Calibre
    CalibreHub::Calibre.new(url, "hub", "pw", nil, ["kategorie"])
  end
end

# Ollama's /api/chat: answers by book title, or with a fixed status
private class FakeOllama
  getter requests = [] of JSON::Any
  property answers = {} of String => String
  property status = 200
  getter url : String

  def initialize
    @server = HTTP::Server.new do |ctx|
      body = JSON.parse(ctx.request.body.try(&.gets_to_end) || "null")
      @requests << body
      ctx.response.content_type = "application/json"
      if @status != 200
        ctx.response.status_code = @status
        ctx.response.print %({"error":"model \\"m\\" not found, try pulling it first"})
      else
        user = body["messages"][1]["content"].as_s
        title = user[/Title: (.*)/, 1]
        ctx.response.print({model: "m", message: {role: "assistant", content: @answers[title]? || "nonsense"}, done: true}.to_json)
      end
    end
    address = @server.bind_tcp("127.0.0.1", 0)
    @url = "http://127.0.0.1:#{address.port}"
    spawn { @server.listen }
  end

  def client(attempts = 2) : CalibreHub::Ollama
    CalibreHub::Ollama.new(url, "m", 5.seconds, attempts, 1.millisecond)
  end
end

private def answer(category, confidence = 0.9, reason = "passt")
  {category: category, confidence: confidence, reason: reason}.to_json
end

private def book(title = "Dune", tags = ["sf", "auto-kategorie"], comments : String? = "<p>Wüste &amp; <b>Würmer</b></p>") : CalibreHub::Book
  CalibreHub::Book.new(id: 1_i64, title: title, authors: ["Frank Herbert"], author_sort: nil, tags: tags,
    series: "Dune", series_index: 1.0, formats: [] of String, last_modified: Time::UNIX_EPOCH,
    timestamp: nil, pubdate: nil, rating: nil, publisher: "Chilton", identifiers: {} of String => String,
    languages: ["eng"], comments: comments, custom: {} of String => JSON::Any)
end

PATHS = ["Roman", "Roman.Krimi", "Roman.SF", "Sachbuch"]

private def setup(threshold = 0.85)
  library = FakeLibrary.new
  library.add(1, "Dune")
  library.add(2, "Mord", tags: ["krimi"])
  library.add(3, "Kochen")
  library.add(4, "Sortiert", kategorie: "Sachbuch")
  library.add(5, "Andere", kategorie: "Roman.Krimi")
  library.add(6, "Fern", kategorie: "Roman.SF")
  model = FakeOllama.new
  model.answers = {
    "Dune"     => answer("Roman/SF", 0.95, "Wüstenplanet"),
    "Mord"     => answer("Roman/Krimi", 0.6, "Mord im Titel"),
    "Kochen"   => answer("", 0.3, "nichts passt"),
    "Sortiert" => answer("Roman", 0.99),
  }
  writer = CalibreHub::Writer.new(library.calibre, nil, nil, "kategorie")
  db = DB.open("sqlite3://#{File.tempname("hub-classify", ".sqlite")}?max_pool_size=1")
  db.exec "create table if not exists meta (key text primary key, value text)"
  db.exec "create table if not exists events (id integer primary key autoincrement, type text not null, book_id integer not null, payload text not null, created_at integer not null, done_at integer)"
  c = CalibreHub::Classify.new(library.calibre, writer, "kategorie", CalibreHub::Suggestions.new(db), model.client, threshold)
  jobs = CalibreHub::ClassifyJobs.new(db, library.calibre, writer, c)
  {library, model, c, jobs, db}
end

private def wait_job(jobs, id) : CalibreHub::Jobs::Job
  200.times do
    job = jobs[id]?.not_nil!
    return job if job.status != "running"
    sleep 10.milliseconds
  end
  raise "job #{id} still running"
end

private def call(method, path, body = nil)
  io = IO::Memory.new
  request = HTTP::Request.new(method, path, HTTP::Headers{"X-Calibre-Hub" => "1"}, body)
  ctx = HTTP::Server::Context.new(request, HTTP::Server::Response.new(io))
  Kemal::RouteHandler::INSTANCE.call(ctx)
  ctx.response.close
  response = HTTP::Client::Response.from_io(IO::Memory.new(io.to_s))
  {response.status_code, JSON.parse(response.body)}
end

describe CalibreHub::Classifier do
  it "lists every node of the tree" do
    CalibreHub::Classifier.paths(["Roman.SF", "Sachbuch", "Roman.Krimi.Cosy"]).should eq(
      ["Roman", "Roman.Krimi", "Roman.Krimi.Cosy", "Roman.SF", "Sachbuch"])
  end

  it "turns HTML into plain text and cuts it at a word" do
    CalibreHub::Classifier.text("<p>Eins &amp; <b>zwei</b></p><script>x()</script>\n<p>drei</p>").should eq("Eins & zwei drei")
    CalibreHub::Classifier.text("aaa bbb ccc", 9).should eq("aaa bbb …")
    CalibreHub::Classifier.text(nil).should eq("")
  end

  it "builds the prompt from the book and the category paths" do
    messages = CalibreHub::Classifier.messages(book, PATHS)
    messages[0]["role"].should eq("system")
    messages[0]["content"].should contain("Never invent a category")
    user = messages[1]["content"]
    user.should eq(<<-TXT)
      Categories:
      - Roman
      - Roman/Krimi
      - Roman/SF
      - Sachbuch

      Book:
      Title: Dune
      Authors: Frank Herbert
      Series: Dune
      Tags: sf
      Publisher: Chilton
      Language: eng
      Description: Wüste & Würmer
      TXT
    CalibreHub::Classifier.messages(book(tags: [] of String, comments: nil), PATHS)[1]["content"].should_not contain("Tags:")
  end

  it "limits the answer to the tree with a JSON schema" do
    schema = CalibreHub::Classifier.schema(PATHS)
    schema["properties"]["category"]["enum"].should eq(JSON.parse(%(["Roman", "Roman/Krimi", "Roman/SF", "Sachbuch", ""])))
    schema["required"].should eq(JSON.parse(%(["category", "confidence", "reason"])))
  end

  it "parses and validates the answer" do
    a = CalibreHub::Classifier.parse(answer("Roman/SF", 0.9, " Wüste "), PATHS)
    a.should eq(CalibreHub::Classifier::Answer.new("Roman.SF", 0.9, "Wüste"))
    # dotted works too, confidence clamped, numbers as strings
    CalibreHub::Classifier.parse(%({"category": "Roman.SF", "confidence": 7, "reason": ""}), PATHS).confidence.should eq(1.0)
    CalibreHub::Classifier.parse(%({"category": "Roman / SF", "confidence": -0.5, "reason": ""}), PATHS).confidence.should eq(0.0)
    CalibreHub::Classifier.parse(%({"category": "Sachbuch", "confidence": "0.4", "reason": "x"}), PATHS).confidence.should eq(0.4)
    # no fit
    none = CalibreHub::Classifier.parse(answer("", 0.8), PATHS)
    none.category.should be_nil
    none.confidence.should eq(0.0)
    expect_raises(CalibreHub::Classifier::UnknownCategory, "Roman/Fantasy") do
      CalibreHub::Classifier.parse(answer("Roman/Fantasy"), PATHS)
    end
    expect_raises(CalibreHub::Classifier::BadAnswer, "no JSON") { CalibreHub::Classifier.parse("Roman/SF", PATHS) }
    expect_raises(CalibreHub::Classifier::BadAnswer, "category") { CalibreHub::Classifier.parse(%({"confidence": 1}), PATHS) }
    expect_raises(CalibreHub::Classifier::BadAnswer, "confidence") { CalibreHub::Classifier.parse(%({"category": "Roman"}), PATHS) }
    expect_raises(CalibreHub::Classifier::BadAnswer) { CalibreHub::Classifier.parse(%(["Roman"]), PATHS) }
  end

  it "applies only sure answers to books without a category" do
    sure = CalibreHub::Classifier::Answer.new("Roman", 0.85, "")
    unsure = CalibreHub::Classifier::Answer.new("Roman", 0.84, "")
    none = CalibreHub::Classifier::Answer.new(nil, 0.0, "")
    CalibreHub::Classifier.status(sure, 0.85, false).should eq("auto")
    CalibreHub::Classifier.status(sure, 0.85, true).should eq("pending")
    CalibreHub::Classifier.status(unsure, 0.85, false).should eq("pending")
    CalibreHub::Classifier.status(none, 0.0, false).should eq("none")
  end

  it "normalizes category input" do
    CalibreHub::Classifier.normalize("Roman/SF").should eq("Roman.SF")
    CalibreHub::Classifier.normalize("Roman › SF").should eq("Roman.SF")
    CalibreHub::Classifier.normalize("Roman.SF").should eq("Roman.SF")
    CalibreHub::Classifier.normalize("  ").should be_nil
  end
end

describe CalibreHub::Ollama do
  it "sends the chat with the schema and returns the content" do
    model = FakeOllama.new
    model.answers["Dune"] = answer("Roman/SF")
    content = model.client.chat(CalibreHub::Classifier.messages(book, PATHS), CalibreHub::Classifier.schema(PATHS))
    content.should eq(answer("Roman/SF"))
    r = model.requests.first
    r["model"].should eq("m")
    r["stream"].should eq(false)
    r["format"]["type"].should eq("object")
    r["options"]["temperature"].should eq(0)
  end

  it "retries server errors and gives up as unavailable" do
    model = FakeOllama.new
    model.status = 503
    expect_raises(CalibreHub::Ollama::Unavailable, "3 attempts") do
      model.client(3).chat([] of Hash(String, String), JSON::Any.new(nil))
    end
    model.requests.size.should eq(3)
  end

  it "doesn't retry a missing model" do
    model = FakeOllama.new
    model.status = 404
    expect_raises(CalibreHub::Ollama::Unavailable, "try pulling it first") do
      model.client(3).chat([] of Hash(String, String), JSON::Any.new(nil))
    end
    model.requests.size.should eq(1)
  end

  it "counts a refused connection as unavailable" do
    expect_raises(CalibreHub::Ollama::Unavailable) do
      CalibreHub::Ollama.new("http://127.0.0.1:1", "m", 1.second, 2, 1.millisecond).chat([] of Hash(String, String), JSON::Any.new(nil))
    end
  end
end

describe CalibreHub::Classify do
  it "applies a sure suggestion with the tag and keeps the rest for review" do
    library, _, c, _, _ = setup
    s = c.classify(1).not_nil!
    s.status.should eq("auto")
    s.category.should eq("Roman.SF")
    s.reason.should eq("Wüstenplanet")
    s.model.should eq("m")
    library.books[1]["#kategorie"].should eq("Roman.SF")
    library.books[1]["tags"].should eq(JSON.parse(%(["auto-kategorie"])))

    c.classify(2).not_nil!.status.should eq("pending")
    library.books[2]["#kategorie"].as_s?.should be_nil
    c.classify(3).not_nil!.status.should eq("none")
    # has a category: never overwritten, only suggested
    c.classify(4).not_nil!.status.should eq("pending")
    library.books[4]["#kategorie"].should eq("Sachbuch")
    c.classify(4, only_unsorted: true).should be_nil
  end

  it "accepts, overrides and rejects" do
    library, _, c, _, _ = setup
    c.classify(2)
    c.accept(2).status.should eq("applied")
    library.books[2]["#kategorie"].should eq("Roman.Krimi")
    library.books[2]["tags"].should eq(JSON.parse(%(["krimi"])))
    c.accept(2, "Sachbuch/Neu").category.should eq("Sachbuch.Neu")
    library.books[2]["#kategorie"].should eq("Sachbuch.Neu")
    c.classify(3)
    expect_raises(CalibreHub::Edit::Invalid, "name one") { c.accept(3) }
    c.reject(3).status.should eq("rejected")
    expect_raises(CalibreHub::Writer::NotFound) { c.accept(99) }
  end

  it "suggests nothing with too few categories" do
    library, model, c, jobs, _ = setup
    library.books[4]["#kategorie"] = JSON::Any.new(nil)
    library.books[5]["#kategorie"] = JSON::Any.new(nil)
    library.books[6]["#kategorie"] = JSON::Any.new(nil)
    expect_raises(CalibreHub::Classify::TooFewCategories) { jobs.submit_target(JSON::Any.new("unsorted")) }
    library.books[5]["#kategorie"] = JSON::Any.new("Roman")
    expect_raises(CalibreHub::Classify::TooFewCategories, "(1)") { c.paths(fresh: true); c.classify(1) }
    model.requests.should be_empty
  end
end

describe CalibreHub::ClassifyJobs do
  it "classifies the unsorted books once per tree" do
    library, _, c, jobs, _ = setup
    job = jobs.submit_target(JSON::Any.new("unsorted"))
    job.total.should eq(3)
    done = wait_job(jobs, job.id)
    done.status.should eq("done")
    done.errors.should be_empty
    c.suggestions.list.map { |s| {s.book_id, s.status} }.sort.should eq([{1_i64, "auto"}, {2_i64, "pending"}, {3_i64, "none"}])
    # pending and no-fit books aren't asked again for the same tree
    jobs.submit_target(JSON::Any.new("unsorted")).total.should eq(0)
    library.books[4]["#kategorie"] = JSON::Any.new("Sachbuch.Kochen")
    jobs.submit_target(JSON::Any.new("unsorted")).total.should eq(1)
  end

  it "stops the run when the model is down" do
    _, model, _, jobs, _ = setup
    model.status = 500
    job = wait_job(jobs, jobs.submit_target(JSON.parse(%({"ids": [1, 2, 3]}))).id)
    job.status.should eq("failed")
    job.done.should eq(0)
    job.error.not_nil!.should contain("model unavailable")
    jobs.last.not_nil![0].id.should eq(job.id)
  end

  it "records bad and unknown answers per book" do
    _, model, c, jobs, _ = setup
    model.answers["Dune"] = answer("Roman/Fantasy")
    model.answers["Mord"] = "kein JSON"
    job = wait_job(jobs, jobs.submit_target(JSON.parse(%({"ids": [1, 2, 3]}))).id)
    job.status.should eq("done")
    job.errors.map(&.[:bookId]).should eq([1, 2])
    job.errors[0][:error].should contain("discarded")
    c.suggestions[1]?.should be_nil
    c.suggestions[3]?.not_nil!.status.should eq("none")
  end

  it "classifies books added without a category" do
    _, _, c, jobs, db = setup
    db.exec "insert into events (type, book_id, payload, created_at) values ('added', 9, '{}', 0)"
    jobs.watch_events(1.hour)
    sleep 10.milliseconds
    # the cursor starts after what was there
    db.exec %(insert into events (type, book_id, payload, created_at) values ('changed', 1, '{}', 0))
    db.exec %(insert into events (type, book_id, payload, created_at) values ('added', 2, '{"book": {"custom": {"kategorie": null}}}', 0))
    db.exec %(insert into events (type, book_id, payload, created_at) values ('added', 5, '{"book": {"custom": {"kategorie": "Roman.Krimi"}}}', 0))
    jobs.follow_events
    job = wait_job(jobs, jobs.last.not_nil![0].id)
    job.total.should eq(1)
    c.suggestions[2]?.not_nil!.status.should eq("pending")
    jobs.follow_events
    jobs.last.not_nil![0].id.should eq(job.id)
  end
end

describe "classify routes" do
  it "lists, accepts and rejects suggestions" do
    library, _, c, jobs, _ = setup
    CalibreHub.classify_routes(jobs, library.calibre)

    status, body = call("POST", "/api/classify", %({"target": "unsorted"}))
    status.should eq(202)
    body["total"].should eq(3)
    wait_job(jobs, body["jobId"].as_s)
    call("POST", "/api/classify", %({"target": 3}))[0].should eq(400)

    status, body = call("GET", "/api/classify/status")
    status.should eq(200)
    body["enabled"].should eq(true)
    body["model"].should eq("m")
    body["pending"].should eq(1)
    body["categories"].should eq(4)
    body["lastRun"]["status"].should eq("done")
    body["lastRun"]["startedAt"].as_s?.should_not be_nil

    status, body = call("GET", "/api/suggestions?status=pending")
    status.should eq(200)
    body.as_a.size.should eq(1)
    body[0]["bookId"].should eq(2)
    body[0]["category"].should eq("Roman.Krimi")
    body[0]["confidence"].should eq(0.6)
    body[0]["book"]["title"].should eq("Mord")
    call("GET", "/api/suggestions?status=x")[0].should eq(400)
    call("GET", "/api/suggestions/1")[1]["status"].should eq("auto")
    call("GET", "/api/suggestions/77")[0].should eq(404)

    status, body = call("POST", "/api/suggestions/2/accept", %({"category": "Roman/SF"}))
    status.should eq(200)
    body["status"].should eq("applied")
    library.books[2]["#kategorie"].should eq("Roman.SF")
    call("POST", "/api/suggestions/3/accept")[0].should eq(400)
    call("POST", "/api/suggestions/3/reject")[1]["status"].should eq("rejected")
    call("POST", "/api/suggestions/77/reject")[0].should eq(404)

    c.classify(4)
    status, body = call("POST", "/api/suggestions/accept", %({"bookIds": [4, 77]}))
    status.should eq(200)
    body["accepted"][0]["bookId"].should eq(4)
    body["errors"].should eq(JSON.parse(%([{"bookId": 77, "error": "not found"}])))
    library.books[4]["#kategorie"].should eq("Roman")
    call("POST", "/api/suggestions/accept", %({"bookIds": "x"}))[0].should eq(400)
  end
end
