require "spec"
require "http/server"
require "file_utils"
require "../src/calibre_hub/cli"

alias Cli = CalibreHub::Cli

# A stub hub: canned answers per "METHOD /path", records the requests
private class Stub
  record Request, method : String, resource : String, body : String, headers : HTTP::Headers

  getter requests = [] of Request
  getter url : String
  @answers = {} of String => Array({Int32, String})

  def initialize
    @server = HTTP::Server.new do |ctx|
      req = ctx.request
      @requests << Request.new(req.method, req.resource, req.body.try(&.gets_to_end) || "", req.headers)
      key = "#{req.method} #{req.path}"
      list = @answers[key]?
      status, body = list ? (list.size > 1 ? list.shift : list.first) : {404, %({"error":"not found"})}
      ctx.response.status_code = status
      ctx.response.content_type = "application/json"
      ctx.response.print body
    end
    address = @server.bind_tcp("127.0.0.1", 0)
    @url = "http://127.0.0.1:#{address.port}"
    spawn { @server.listen }
  end

  # several calls queue answers, the last one repeats
  def on(method : String, path : String, body, status = 200)
    (@answers["#{method} #{path}"] ||= [] of {Int32, String}) << {status, body.is_a?(String) ? body : body.to_json}
    self
  end

  def close
    @server.close
  end
end

private def book(id = 1, title = "Dune", tags = ["sf"], modified = "2026-11-02T06:00:00.000000Z", **extra)
  h = {"id" => id, "title" => title, "authors" => ["Frank Herbert"], "tags" => tags, "series" => "Dune",
       "seriesIndex" => 1.0, "formats" => ["EPUB", "PDF"], "lastModified" => modified, "added" => nil,
       "pubdate" => "1965-08-01T12:00:00+00:00", "rating" => 8.0, "publisher" => nil,
       "identifiers" => {"isbn" => "123"}, "languages" => ["eng"], "custom" => {"kategorie" => "Roman.SF"},
       "comments" => "<p>Arrakis &amp; spice</p>"}
  extra.each { |k, v| h[k.to_s] = v }
  JSON.parse(h.to_json)
end

# runs the CLI against the stub: {exit code, stdout, stderr}
private def cli(stub : Stub?, *args, stdin = "", env = {} of String => String)
  stdout = IO::Memory.new
  err = IO::Memory.new
  e = {"CALIBRE_HUB_TOKEN" => "secret-token-0123456789", "HOME" => "/nonexistent"}
  e["CALIBRE_HUB_URL"] = stub.url if stub
  runner = Cli::Runner.new(stdout, err, IO::Memory.new(stdin), e.merge(env))
  runner.poll_interval = 10.milliseconds
  code = runner.run(args.to_a)
  {code, stdout.to_s, err.to_s}
end

private def with_stub(&)
  stub = Stub.new
  yield stub
ensure
  stub.try &.close
end

private def search_cmd
  Cli.command("search").not_nil!
end

describe Cli::Args do
  it "parses options in all spellings" do
    a = Cli::Args.new(search_cmd, ["title:x", "--tag", "a", "--tag=b", "--limit=5", "--json", "--", "--literal"])
    a.positional.should eq(["title:x", "--literal"])
    a.all("tag").should eq(["a", "b"])
    a["limit"]?.should eq("5")
    a.json?.should be_true
    d = Cli::Args.new(Cli.command("download").not_nil!, ["1", "-o", "x.epub"])
    d["output"]?.should eq("x.epub")
    Cli::Args.new(Cli.command("download").not_nil!, ["1", "-ox.epub"])["output"]?.should eq("x.epub")
  end

  it "rejects unknown options, missing values and bad choices" do
    expect_raises(Cli::Usage, "unknown option --bogus") { Cli::Args.new(search_cmd, ["--bogus"]) }
    expect_raises(Cli::Usage, "needs a value") { Cli::Args.new(search_cmd, ["--tag"]) }
    expect_raises(Cli::Usage, "must be one of") { Cli::Args.new(search_cmd, ["--sort", "size"]) }
    expect_raises(Cli::Usage, "takes no value") { Cli::Args.new(search_cmd, ["--json=1"]) }
  end
end

describe Cli::Runner do
  it "normalizes categories and lists" do
    Cli::Runner.kategorie("Fachbuch/Software").should eq("Fachbuch.Software")
    Cli::Runner.kategorie("A.B/ C ").should eq("A.B.C")
    Cli::Runner.list(" a, b,,a ").should eq(["a", "b"])
    Cli::Runner.id("#12").should eq(12)
    expect_raises(Cli::Usage) { Cli::Runner.id("x") }
  end

  it "builds the PATCH body from edit options" do
    argv = %w(1 --title T --authors A,B --series= --index 2.5 --kategorie A/B --pubdate 2020-05-01
      --rating 8 --identifier isbn=9 --identifier asin= --comments-file -)
    args = Cli::Args.new(Cli.command("edit").not_nil!, argv)
    c = Cli::Runner.edit_changes(args, IO::Memory.new("<p>Hi</p>\n"))
    c["title"].should eq("T")
    c["authors"].as_a.should eq(["A", "B"])
    c["series"].raw.should be_nil
    c["seriesIndex"].should eq(2.5)
    c["kategorie"].should eq("A.B")
    c["pubdate"].should eq("2020-05-01")
    c["rating"].should eq(8)
    c["comments"].should eq("<p>Hi</p>")
    Cli::Runner.identifiers(JSON.parse(%({"asin":"x","doi":"y"})), c["identifier"].as_a.map(&.as_s))
      .should eq(JSON.parse(%({"doi":"y","isbn":"9"})))
  end

  it "validates edit values locally" do
    edit = Cli.command("edit").not_nil!
    expect_raises(Cli::Usage, "0-10") { Cli::Runner.edit_changes(Cli::Args.new(edit, ["1", "--rating", "11"]), IO::Memory.new) }
    expect_raises(Cli::Usage, "YYYY") { Cli::Runner.edit_changes(Cli::Args.new(edit, ["1", "--pubdate", "1.5.2020"]), IO::Memory.new) }
    expect_raises(Cli::Usage, "TYPE=VALUE") { Cli::Runner.edit_changes(Cli::Args.new(edit, ["1", "--identifier", "isbn"]), IO::Memory.new) }
  end

  it "builds bulk changes" do
    args = Cli::Args.new(Cli.command("bulk").not_nil!, ["--ids", "1,2", "--add-tags", "a,b", "--kategorie", "X/Y", "--series", "S", "--number-series"])
    Cli::Runner.bulk_changes(args).to_json.should eq(%({"addTags":["a","b"],"kategorie":"X.Y","series":"S","numberSeries":true}))
  end

  it "names downloaded files after author and title" do
    Cli::Runner.file_name(book(title: "A/B: C"), "epub").should eq("Frank Herbert - A_B_ C.epub")
  end
end

describe Cli::Output do
  it "prints aligned tables and cuts long cells" do
    io = IO::Memory.new
    Cli::Output.table(io, ["ID", "Title", "Tags"], [["1", "Dune", "sf"], ["12", "A very long title", "x"]], [nil, 8])
    io.to_s.should eq("ID  Title     Tags\n1   Dune      sf\n12  A very …  x\n")
  end

  it "formats values and comments" do
    Cli::Output.value(JSON.parse(%(["a","b"]))).should eq("a, b")
    Cli::Output.value(JSON.parse("null")).should eq("-")
    Cli::Output.value(JSON.parse("3.0")).should eq("3")
    Cli::Output.plain("<p>One &amp; two</p><p>Three<br>four</p><ul><li>x</li></ul>").should eq("One & two\nThree\nfour\n- x")
  end

  it "keeps escape sequences from the library out of the terminal" do
    Cli::Output.value(JSON::Any.new("Titel\e]52;c;aGk=\a")).should eq("Titel]52;c;aGk=")
    Cli::Output.plain("<p>a\e[2Jb\u009b</p>").should eq("a[2Jb")
    Cli::Output.clean("Bücher\tund\nmehr").should eq("Bücher\tund\nmehr")
  end

  it "shows a book" do
    io = IO::Memory.new
    Cli::Output.book(io, book)
    text = io.to_s
    text.should start_with("#1  Dune\n")
    text.should contain("Series:      Dune [1]")
    text.should contain("Kategorie:   Roman.SF")
    text.should contain("Rating:      8/10")
    text.should end_with("\nArrakis & spice\n")
  end
end

describe "hub CLI" do
  it "prints help and rejects unknown commands" do
    code, stdo, _ = cli(nil, "--help")
    code.should eq(0)
    stdo.should contain("search")
    code, stdo, _ = cli(nil, "edit", "--help")
    code.should eq(0)
    stdo.should contain("--comments-file PATH")
    code, _, err = cli(nil, "frobnicate")
    code.should eq(1)
    err.should contain("unknown command")
  end

  it "points to hub tui where the TUI isn't linked (calibre-hub cli)" do
    code, _, err = cli(nil, "tui")
    code.should eq(1)
    err.should contain("hub tui")
  end

  it "searches with filters and the token" do
    with_stub do |s|
      s.on("GET", "/api/books", {total: 3, offset: 0, limit: 2, books: [book, book(2, "Dune Messiah")]})
      s.on("GET", "/api/config", {fastTags: [] of String, categoryColumn: "kategorie"})
      code, stdo, _ = cli(s, "search", "title:dune", "--kategorie", "Roman/SF", "--tag", "sf", "--limit", "2", "--sort", "added")
      code.should eq(0)
      req = s.requests.first
      req.headers["Authorization"].should eq("Bearer secret-token-0123456789")
      HTTP::Params.parse(req.resource.partition('?')[2]).to_s.should eq("q=title%3Adune&kategorie=Roman.SF&tag=sf&sort=added&limit=2")
      stdo.lines[0].split(/\s{2,}/).should eq(["ID", "Title", "Authors", "Series", "Kategorie", "Tags"])
      stdo.lines[2].should start_with("2   Dune Messiah")
      stdo.lines.last.should eq("1-2 of 3 books (--offset 2 for more)")
      code, stdo, _ = cli(s, "search", "--json")
      JSON.parse(stdo)["total"].should eq(3)
    end
  end

  it "maps errors to exit codes" do
    with_stub do |s|
      s.on("GET", "/api/books", {error: "login required"}, 401)
      s.on("GET", "/api/books/9", {error: "not found"}, 404)
      s.on("GET", "/api/categories", {error: "calibre-server unavailable"}, 502)
      cli(s, "search")[0].should eq(4)
      code, stdo, err = cli(s, "show", "9", "--json")
      code.should eq(2)
      err.should contain("book 9 not found")
      JSON.parse(stdo)["exitCode"].should eq(2)
      cli(s, "categories")[0].should eq(5)
      cli(s, "show")[0].should eq(1)
    end
    cli(nil, "search", env: {"CALIBRE_HUB_URL" => "http://127.0.0.1:1"})[0].should eq(5)
    code, _, err = cli(nil, "search", env: {"CALIBRE_HUB_TOKEN" => ""})
    code.should eq(4)
    err.should contain("no API token")
  end

  it "reads the token from a file" do
    path = File.tempname("token")
    File.write(path, "file-token-0123456789\n")
    with_stub do |s|
      s.on("GET", "/api/categories", {kategorie: [] of String, tags: [{name: "sf", count: 2}], authors: [] of String, series: [] of String, languages: [] of String})
      code, stdo, _ = cli(s, "categories", "tags", env: {"CALIBRE_HUB_TOKEN" => "", "CALIBRE_HUB_TOKEN_FILE" => path})
      code.should eq(0)
      s.requests.first.headers["Authorization"].should eq("Bearer file-token-0123456789")
      stdo.should eq("Count  Name\n2      sf\n")
    end
  ensure
    File.delete?(path) if path
  end

  it "edits with the version it read and shows conflicts" do
    with_stub do |s|
      s.on("GET", "/api/books/1", book)
      s.on("PATCH", "/api/books/1", book(title: "Neu"))
      code, stdo, _ = cli(s, "edit", "1", "--title", "Neu", "--kategorie", "A/B", "--identifier", "asin=X")
      code.should eq(0)
      stdo.should start_with("#1  Neu")
      body = JSON.parse(s.requests.last.body)
      body["lastModified"].should eq("2026-11-02T06:00:00.000000Z")
      body["kategorie"].should eq("A.B")
      body["identifiers"].should eq(JSON.parse(%({"isbn":"123","asin":"X"})))
    end
    with_stub do |s|
      s.on("GET", "/api/books/1", book)
      s.on("PATCH", "/api/books/1", {error: "changed in the meantime", book: book(title: "Anders", modified: "2026-11-02T07:00:00.000000Z")}, 409)
      code, _, err = cli(s, "edit", "1", "--title", "Neu")
      code.should eq(3)
      err.should contain("conflict: book 1 was changed")
      err.lines.find(&.starts_with?("title")).not_nil!.split(/\s{2,}/).should eq(["title", "Dune", "Anders", "Neu"])
      code, stdo, _ = cli(s, "edit", "1", "--title", "Neu", "--json")
      code.should eq(3)
      JSON.parse(stdo)["current"]["title"].should eq("Anders")
    end
  end

  it "requires a change for edit" do
    cli(nil, "edit", "1")[0].should eq(1)
  end

  it "tags several books and reports failures" do
    with_stub do |s|
      s.on("PATCH", "/api/books/1", book(tags: ["sf", "leseliste"]))
      s.on("PATCH", "/api/books/2", book(2, "Zwei", tags: ["leseliste"]))
      code, stdo, err = cli(s, "tag", "add", "1", "2", "3", "leseliste")
      code.should eq(2)
      s.requests.map(&.body).uniq.should eq([%({"addTags":["leseliste"]})])
      stdo.should match(/^1\s+Dune\s+sf, leseliste$/m)
      err.should contain("#3: not found")
      cli(s, "tag", "rm", "1", "leseliste")[0].should eq(0)
      s.requests.last.body.should eq(%({"removeTags":["leseliste"]}))
      cli(s, "tag", "put", "1", "x")[0].should eq(1)
    end
  end

  it "uploads files and shows duplicates" do
    dir = File.tempname("upload")
    Dir.mkdir(dir)
    file = File.join(dir, "Buch.epub")
    File.write(file, "epub-data")
    with_stub do |s|
      s.on("POST", "/api/books", {upload: {id: "u1", name: "Buch.epub", status: "checking"}}, 202)
      s.on("POST", "/api/books", {upload: {id: "u2", name: "Buch.epub", status: "checking"}}, 202)
      s.on("GET", "/api/intake/uploads/u1", {id: "u1", name: "Buch.epub", status: "checking"})
      s.on("GET", "/api/intake/uploads/u1", {id: "u1", name: "Buch.epub", status: "imported", book: book(5, "Buch")})
      s.on("GET", "/api/intake/uploads/u2", {id: "u2", name: "Buch.epub", status: "duplicate", entryId: 7, duplicates: [book(1)], titles: [] of String})
      code, stdo, _ = cli(s, "upload", file, "--tag", "a,b", "--kategorie", "A/B")
      code.should eq(0)
      stdo.should contain("added as #5 Buch")
      req = s.requests.find! { |r| r.method == "POST" }
      req.headers["Content-Length"].should eq(req.body.bytesize.to_s)
      req.body.should contain(%(filename="Buch.epub"))
      req.body.should contain("epub-data")
      req.body.should contain("A.B")
      code, _, err = cli(s, "upload", file)
      code.should eq(3)
      err.should contain("duplicate, waits in the Eingang, not added (--force adds it anyway)")
      err.should contain("#1  Dune (Frank Herbert)")
      code, stdo, _ = cli(s, "upload", file, File.join(dir, "missing.epub"), "--json")
      code.should eq(3)
      JSON.parse(stdo).as_a.map(&.["status"]).should eq(["duplicate", "error"])
    end
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "says when an upload waits in the Eingang, or isn't through yet" do
    dir = File.tempname("upload")
    Dir.mkdir(dir)
    file = File.join(dir, "Buch.epub")
    File.write(file, "epub-data")
    with_stub do |s|
      s.on("POST", "/api/books", {upload: {id: "u1", name: "Buch.epub", status: "checking"}}, 202)
      s.on("GET", "/api/intake/uploads/u1", {id: "u1", status: "waiting", entryId: 7, confidence: 75, threshold: 90})
      code, stdo, _ = cli(s, "upload", file)
      code.should eq(0)
      stdo.should contain("waits in the Eingang, 75 % sure")
    end
    with_stub do |s|
      s.on("POST", "/api/books", {upload: {id: "u1", name: "Buch.epub", status: "checking"}}, 202)
      code, stdo, _ = cli(s, "upload", file, "--wait", "0")
      code.should eq(0)
      stdo.should contain("in the Eingang, the analysis isn't through yet")
    end
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "adds a format right away" do
    dir = File.tempname("upload")
    Dir.mkdir(dir)
    file = File.join(dir, "Buch.pdf")
    File.write(file, "pdf-data")
    with_stub do |s|
      s.on("POST", "/api/books", {book: book(5, "Buch")}, 200)
      code, stdo, _ = cli(s, "upload", file, "--add-format-to", "5")
      code.should eq(0)
      stdo.should contain("format added to #5 Buch")
    end
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "runs bulk jobs and waits for them" do
    with_stub do |s|
      s.on("POST", "/api/books/bulk", {jobId: "j1", total: 3}, 202)
      s.on("GET", "/api/jobs/j1", {id: "j1", status: "running", done: 1, total: 3, errors: [] of String})
      s.on("GET", "/api/jobs/j1", {id: "j1", status: "done", done: 3, total: 3, errors: [{bookId: 3, error: "not found"}]})
      cli(s, "bulk", "--ids", "1,2,3", "--add-tags", "x")[0].should eq(1) # no --yes without a terminal
      cli(s, "bulk", "--query", "x", "--series", "S", "--number-series", "--yes")[0].should eq(1)
      cli(s, "bulk", "--ids", "1", "--number-series", "--yes")[0].should eq(1)
      s.requests.should be_empty
      code, stdo, _ = cli(s, "bulk", "--ids", "1,2,3", "--add-tags", "x", "--series", "S", "--number-series", "--yes")
      code.should eq(2)
      JSON.parse(s.requests.first.body).should eq(JSON.parse(%({"target":{"ids":[1,2,3]},"changes":{"addTags":["x"],"series":"S","numberSeries":true}})))
      s.requests.count(&.resource.==("/api/jobs/j1")).should eq(2)
      stdo.should contain("done: 2 of 3 books changed, 1 failed:")
      stdo.should contain("3   not found")
    end
    with_stub do |s|
      s.on("GET", "/api/books", {total: 2, offset: 0, limit: 1, books: [book]})
      s.on("POST", "/api/books/bulk", {jobId: "j2", total: 2}, 202)
      s.on("GET", "/api/jobs/j2", {id: "j2", status: "done", done: 2, total: 2, errors: [] of String})
      code, stdo, _ = cli(s, "bulk", "--query", "tags:x", "--kategorie", "", "--yes", "--json")
      code.should eq(0)
      JSON.parse(s.requests[1].body).should eq(JSON.parse(%({"target":{"query":{"q":"tags:x"},"expect":2},"changes":{"kategorie":null}})))
      JSON.parse(stdo)["status"].should eq("done")
    end
  end

  it "manages reading lists by id or name" do
    with_stub do |s|
      leseliste = {id: 1, name: "Leseliste", description: "Für den Boox", owner: "arthur", visibility: "private",
                   sync: true, favorite: true, isDefault: true, count: 2, editable: true}
      urlaub = {id: 2, name: "Urlaub", description: "", owner: "arthur", visibility: "readable",
                sync: false, favorite: false, isDefault: false, count: 0, editable: true}
      s.on("GET", "/api/lists", [leseliste, urlaub])
      s.on("GET", "/api/config", {categoryColumn: "kategorie"})
      code, stdo, _ = cli(s, "list", "ls")
      code.should eq(0)
      stdo.lines[1].split(/\s{2,}/).should eq(["1", "Leseliste", "2", "default, sync, favorite"])
      stdo.lines[2].split(/\s{2,}/).should eq(["2", "Urlaub", "0", "readable"])

      s.on("GET", "/api/books", {total: 2, offset: 0, limit: 50, books: [book, book(2, "Dune Messiah")]})
      code, stdo, _ = cli(s, "list", "show", "leseliste", "--sort", "title")
      code.should eq(0)
      stdo.lines[0].should eq("Leseliste (#1, 2 books, default, sync, favorite)")
      stdo.should contain("Dune Messiah")
      HTTP::Params.parse(s.requests.find! { |r| r.resource.starts_with?("/api/books?") }.resource.partition('?')[2]).to_s.should eq("list=1&sort=title")
      cli(s, "list", "show", "Nirgends")[0].should eq(2)

      s.on("POST", "/api/lists", urlaub.merge({id: 3, name: "Krimis"}), 201)
      code, stdo, _ = cli(s, "list", "create", "Krimis", "--sync", "--default", "--visibility", "readable")
      code.should eq(0)
      stdo.should eq("created list #3 Krimis\n")
      JSON.parse(s.requests.last.body).should eq(JSON.parse(%({"name":"Krimis","visibility":"readable","sync":true,"isDefault":true})))

      s.on("POST", "/api/lists/2/books", {list: urlaub.merge({count: 1}), added: [5]})
      code, stdo, err = cli(s, "list", "add", "Urlaub", "5", "6")
      code.should eq(0)
      JSON.parse(s.requests.last.body).should eq(JSON.parse(%({"bookIds":[5,6]})))
      stdo.should eq("1 book added to Urlaub (now 1)\n")
      err.should contain("already in the list or unknown: 6")
      s.on("POST", "/api/lists/2/books/remove", {list: urlaub, removed: [5]})
      cli(s, "list", "rm", "2", "5")[1].should eq("1 book removed from Urlaub (now 0)\n")

      # deleting asks unless --yes
      cli(s, "list", "delete", "Urlaub")[0].should eq(1)
      s.on("DELETE", "/api/lists/2", {list: urlaub})
      cli(s, "list", "delete", "Urlaub", "--yes")[1].should eq("deleted list Urlaub\n")
      cli(s, "list", "frob")[0].should eq(1)
    end
  end

  it "shows nested lists as a tree and by path" do
    with_stub do |s|
      l = ->(id : Int32, name : String, count : Int32, total : Int32, owner : String) do
        {id: id, name: name, description: "", owner: owner, visibility: owner == "arthur" ? "private" : "readable",
         sync: false, favorite: false, isDefault: false, count: count, totalCount: total, editable: owner == "arthur"}
      end
      s.on("GET", "/api/lists", [l.call(1, "Urlaub", 1, 3, "arthur"), l.call(2, "Urlaub/2026", 2, 2, "arthur"),
                                 l.call(3, "Reise/Meer", 1, 1, "arthur"), l.call(4, "Krimis", 0, 0, "tilli")])
      s.on("GET", "/api/config", {categoryColumn: "kategorie"})
      code, stdo, _ = cli(s, "list", "ls", "--tree")
      code.should eq(0)
      stdo.lines[1..].map(&.rstrip).should eq([
        "-   Reise/          -      -      -",
        "3    Meer           1      1      -",
        "1   Urlaub          1      3      -",
        "2    2026           2      2      -",
        "4   Krimis (tilli)  0      0      readable, read-only",
      ])

      s.on("GET", "/api/books", {total: 1, offset: 0, limit: 50, books: [book]})
      code, stdo, _ = cli(s, "list", "show", "urlaub / 2026", "--direct")
      code.should eq(0)
      stdo.lines[0].should eq("Urlaub/2026 (#2, 2 books)")
      HTTP::Params.parse(s.requests.reverse.find! { |r| r.resource.starts_with?("/api/books?") }.resource.partition('?')[2]).to_s.should eq("list=2&direct=1")
      code, stdo, _ = cli(s, "list", "show", "Urlaub")
      stdo.lines[0].should eq("Urlaub (#1, 1 book, 3 with sublists (shown))")
      # a level without a list of its own
      code, stdo, _ = cli(s, "list", "show", "reise")
      code.should eq(0)
      stdo.lines[0].should eq("Reise/ (no list of its own, the books of its sublists)")
      HTTP::Params.parse(s.requests.reverse.find! { |r| r.resource.starts_with?("/api/books?") }.resource.partition('?')[2]).to_s.should eq("listPath=Reise&listOwner=arthur")
      cli(s, "list", "show", "Rei")[0].should eq(2)
    end
  end

  it "downloads a book file" do
    dir = File.tempname("download")
    Dir.mkdir(dir)
    with_stub do |s|
      s.on("GET", "/api/books/1", book)
      s.on("GET", "/api/books/1/download/epub", "EPUBDATA")
      target = File.join(dir, "d.epub")
      code, _, _ = cli(s, "download", "1", "-o", target)
      code.should eq(0)
      File.read(target).should eq("EPUBDATA")
      cli(s, "download", "1", "--format", "mobi")[0].should eq(2)
    end
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "prints shell completions" do
    _, fish, _ = cli(nil, "completion", "fish")
    fish.should contain("complete -c hub -n '__fish_seen_subcommand_from search' -l sort -x -a 'title author added modified published series rating'")
    fish.should contain("complete -c calibre-hub -n '__fish_seen_subcommand_from cli; and __fish_seen_subcommand_from upload' -F")
    _, bash, _ = cli(nil, "completion", "bash", "--prog", "hub")
    bash.should contain("complete -F _calibre_hub_hub hub")
    bash.should_not contain("calibre-hub\n")
  end
end

describe "hub eingang" do
  it "shows what is in the list, by source" do
    with_stub do |s|
      s.on("GET", "/api/intake", {enabled: true, progress: {state: "analysing", done: 12, total: 14, analysed: 11, current: "a.pdf"},
                                  origins: {inbox: 10, upload: 2}, thresholds: {inbox: nil, upload: 90}, pending: 3})
      code, stdo, _ = cli(s, "eingang")
      code.should eq(0)
      stdo.should contain("eingang: 14 books, 11 analysed, analysis analysing")
      stdo.should contain("at a.pdf")
      stdo.should contain("from: inbox 10, upload 2")
      stdo.should contain("taken by itself: inbox off, upload from 90")
      stdo.should contain("3 decided, on their way")
    end
  end

  it "plans the library's books" do
    with_stub do |s|
      s.on("POST", "/api/import/repair/recheck", {books: 3, job: {id: "j1"}}, 202)
      cli(s, "eingang", "analysis", "off")[0].should eq(1)
      cli(s, "eingang", "recheck")[1].should contain("recheck: 3 books")
      cli(s, "eingang", "nonsense")[0].should eq(1)
    end
  end
end

describe "hub import" do
  it "says where the old ways went" do
    with_stub do |s|
      code, _, err = cli(s, "import", "alt")
      code.should eq(1)
      err.should contain("through the Eingang")
      cli(s, "import", "repair")[0].should eq(1)
      cli(s, "import", "quality")[0].should eq(1)
    end
  end

  it "keeps the old names of hub eingang's" do
    with_stub do |s|
      s.on("GET", "/api/intake", {enabled: true, progress: {state: "idle", done: 1, total: 1, analysed: 1, current: nil},
                                  origins: {inbox: 1}, thresholds: {inbox: 90}, pending: 0})
      s.on("GET", "/api/import/cleanups", [{id: "c1", createdAt: "2026-11-03T08:00:00Z", total: 3, job: {status: "done"}, undoJob: nil}])
      code, stdo, _ = cli(s, "import", "status")
      code.should eq(0)
      stdo.should contain("eingang: 1 books, 1 analysed, analysis idle")
      stdo.should contain("cleanup c1  2026-11-03T08:00:00Z  3 books  done")
    end
  end

  it "cleans up inbox imports and undoes it" do
    entry = {bookId: 120, title: "A", folders: ["Defaults", "Algebra"], kategorie: "Defaults.Algebra",
             tags: ["Algebra", "Defaults"], removeTags: ["Algebra", "Defaults"], clearKategorie: true}
    with_stub do |s|
      cli(s, "import", "cleanup")[0].should eq(1)
      s.on("POST", "/api/import/cleanup", {dryRun: true, total: 1, entries: [entry]})
      code, stdo, _ = cli(s, "import", "cleanup", "--min-id", "114")
      code.should eq(0)
      JSON.parse(s.requests.last.body).should eq(JSON.parse(%({"minId":114,"dryRun":true})))
      stdo.should contain("Defaults.Algebra")
      stdo.should contain("1 books, dry run")
      s.on("POST", "/api/import/cleanups/c1/undo", {id: "c1", entries: [entry], undoJob: {id: "u1"}})
      s.on("GET", "/api/jobs/u1", {id: "u1", status: "done", done: 1, total: 1, errors: [] of String})
      code, stdo, _ = cli(s, "import", "undo", "c1", "--apply")
      code.should eq(0)
      stdo.should contain("undo of c1: done, 1 books")
    end
  end

  it "starts a recheck of the books no plan got to" do
    with_stub do |s|
      s.on("POST", "/api/import/repair/recheck", {books: 12, job: {id: "j1", status: "running", done: 0, total: 12, errors: [] of String}})
      code, stdo, _ = cli(s, "import", "repair", "recheck", "--run", "abc")
      code.should eq(0)
      JSON.parse(s.requests.last.body).should eq(JSON.parse(%({"run":"abc"})))
      stdo.should contain("recheck: 12 books, job j1")
    end
  end
end
