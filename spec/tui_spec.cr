require "spec"
require "file_utils"
require "../src/calibre_hub/tui"

# headless: no terminal, fixed colours (no escape sequences in views)
Lipgloss.color_profile = Lipgloss::ColorProfile::Ascii
Lipgloss.dark_background = true

alias Tui = CalibreHub::Tui

# A hub with `count` books: every tenth is "Dune …", the first 50 have
# no category
private class FakeSource < Tui::Source
  getter requests = [] of HTTP::Params
  property fail = false
  property lists_json = %([{"id":1,"name":"Leseliste","parent":null,"leaf":"Leseliste","count":2,"isDefault":true},
    {"id":2,"name":"Reise/Meer","parent":"Reise","leaf":"Meer","count":1}])

  def initialize(@count = 150)
  end

  def book(i : Int32) : JSON::Any
    JSON.parse({
      id: i, title: i % 10 == 0 ? "Dune #{i}" : "Book #{i}", authors: ["Author #{i % 7}"],
      tags: i.odd? ? ["leseliste"] : ["sf"], series: i % 5 == 0 ? "Saga" : nil, seriesIndex: 2.0,
      formats: ["EPUB"], custom: {kategorie: i <= 50 ? nil : "Fach.Software"}, languages: ["deu"],
      comments: "<p>About <b>book</b> #{i}.</p><ul><li>one</li><li>two</li></ul>",
      identifiers: {isbn: "978#{i}"}, lists: [1], added: "2026-01-02T03:04:05Z",
      pubdate: "0101-01-01T00:00:00Z", publisher: "Verlag #{i}", rating: 8.0,
    }.to_json)
  end

  def books(params : HTTP::Params) : JSON::Any
    @requests << params
    raise "hub down" if @fail
    q = params["q"]? || ""
    ids = (1..@count).to_a
    ids.select! { |i| i % 10 == 0 } if q.includes?("dune")
    ids.select! { |i| i <= 50 } if q.includes?("#kategorie:false")
    ids.select!(&.odd?) if params.fetch_all("tag").includes?("leseliste")
    ids.reverse! if params["order"]? == "desc"
    offset = params["offset"]?.try(&.to_i) || 0
    limit = params["limit"]?.try(&.to_i) || 50
    page = ids[offset, limit]? || [] of Int32
    # like the API: lists leave out the description
    books = page.map { |i| book(i).as_h.reject("comments") }
    JSON.parse({total: ids.size, offset: offset, limit: limit, books: books}.to_json)
  end

  getter book_requests = [] of Int64

  def book(id : Int64) : JSON::Any
    @book_requests << id
    current(id)
  end

  def categories : JSON::Any
    JSON.parse(%({"kategorie":[{"name":"Fach","path":"Fach","count":100,"children":[
      {"name":"Software","path":"Fach.Software","count":100,"children":[]}]}],
      "tags":[{"name":"leseliste","count":75},{"name":"sf","count":75}],
      "authors":#{(0..11).map { |i| {name: "Author #{i}", count: 20 - i} }.to_json},
      "series":[{"name":"Saga","count":30}],"languages":[{"name":"deu","count":150}]}))
  end

  def config : JSON::Any
    JSON.parse(%({"fastTags":["leseliste"],"categoryColumn":"kategorie","classify":false,"metadata":false}))
  end

  def lists : JSON::Any
    JSON.parse(@lists_json)
  end

  # --- writes: recorded, applied to the fake's books ----------------------

  getter writes = [] of {String, JSON::Any}
  # changed fields per book on top of book(i)
  getter changed = {} of Int64 => Hash(String, JSON::Any)
  # the next PATCH answers 409 with the book changed meanwhile
  property conflict_next = false
  property fail_writes = false
  getter jobs = {} of String => JSON::Any
  property job_polls_running = 0

  private def record(what : String, body) : Nil
    @writes << {what, JSON.parse(body.to_json)}
    raise CalibreHub::Cli::HttpError.new(500, JSON.parse(%({"error":"hub down"}))) if @fail_writes
  end

  def current(id : Int64) : JSON::Any
    h = book(id.to_i).as_h
    h["lastModified"] = JSON::Any.new("v#{@changed[id]?.try(&.["_writes"]?).try(&.as_i64) || 0}")
    @changed[id]?.try { |c| h.merge!(c) }
    JSON::Any.new(h)
  end

  def patch_book(id : Int64, body : Hash(String, JSON::Any)) : JSON::Any
    record("PATCH #{id}", body)
    if @conflict_next
      @conflict_next = false
      c = (@changed[id] ||= {} of String => JSON::Any)
      c["title"] = JSON::Any.new("Changed meanwhile")
      c["_writes"] = JSON::Any.new((c["_writes"]?.try(&.as_i64) || 0_i64) + 1)
      raise CalibreHub::Cli::HttpError.new(409, JSON.parse({error: "changed in the meantime", book: current(id)}.to_json))
    end
    c = (@changed[id] ||= {} of String => JSON::Any)
    tags = (c["tags"]? || current(id)["tags"]).as_a.map(&.as_s)
    body.each do |k, v|
      case k
      when "addTags"    then tags += v.as_a.map(&.as_s) - tags; c["tags"] = JSON.parse(tags.to_json)
      when "removeTags" then tags -= v.as_a.map(&.as_s); c["tags"] = JSON.parse(tags.to_json)
      when "kategorie"  then c["custom"] = JSON.parse({kategorie: v}.to_json)
      when "lastModified"
      else c[k] = v
      end
    end
    c["_writes"] = JSON::Any.new((c["_writes"]?.try(&.as_i64) || 0_i64) + 1)
    current(id)
  end

  def delete_book(id : Int64) : JSON::Any
    record("DELETE #{id}", nil)
    JSON.parse({book: current(id)}.to_json)
  end

  def restore_book(id : Int64) : JSON::Any
    record("RESTORE #{id}", nil)
    JSON.parse({book: current(id)}.to_json)
  end

  def bulk(target : JSON::Any, changes : Hash(String, JSON::Any)) : JSON::Any
    record("BULK", {target: target, changes: changes})
    id = "job#{@jobs.size + 1}"
    total = target["ids"].as_a.size
    @jobs[id] = JSON.parse({id: id, status: "done", done: total, total: total, errors: [] of String}.to_json)
    JSON.parse({jobId: id, total: total}.to_json)
  end

  def job(id : String) : JSON::Any
    if @job_polls_running > 0
      @job_polls_running -= 1
      return JSON.parse({id: id, status: "running", done: 0, total: 2, errors: [] of String}.to_json)
    end
    @jobs[id]
  end

  def undo_job(id : String) : JSON::Any
    record("UNDO #{id}", nil)
    @jobs["undo-#{id}"] = JSON.parse({id: "undo-#{id}", status: "done", done: 1, total: 1, errors: [] of String}.to_json)
    JSON.parse({jobId: "undo-#{id}", total: 1}.to_json)
  end

  def list_books(list : Int64, ids : Array(Int64), remove : Bool) : JSON::Any
    record("LIST #{remove ? "rm" : "add"} #{list}", ids)
    JSON.parse({"list" => JSON.parse({id: list, name: "x", count: 1}.to_json), (remove ? "removed" : "added") => JSON.parse(ids.to_json)}.to_json)
  end

  def create_list(name : String) : JSON::Any
    record("NEWLIST", name)
    JSON.parse({id: 9, name: name, count: 0}.to_json)
  end

  def download(id : Int64, format : String, path : String) : Int64
    record("DOWNLOAD #{id} #{format}", path)
    42_i64
  end
end

# Runs commands like the program would, synchronously; true if one quits
private def run(app : Tui::App, cmd : Tea::Cmd?) : Bool
  queue = [cmd] of Tea::Cmd?
  quit = false
  until queue.empty?
    c = queue.shift || next
    case c
    when Tea::AsyncCmd
      c.proc.call.try { |m| queue << app.update(m) }
    when Tea::MsgCmd                     then queue << app.update(c.msg)
    when Tea::BatchCmd, Tea::SequenceCmd then queue.concat(c.cmds.map(&.as(Tea::Cmd?)))
    when Tea::ControlCmd                 then quit = true if c.type == "quit"
    end
  end
  quit
end

private def press(app : Tui::App, *keys : String) : Bool
  keys.any? { |k| run(app, app.update(key_msg(k))) }
end

# a space as the terminal sends it (with its rune; bubbletea.cr 0.2.0's
# KeyMsg.new(" ") has none, so text inputs would drop it)
private def key_msg(k : String) : Tea::KeyMsg
  k == " " ? Tea::KeyMsg.new(" ", " ", -15, " ") : Tea::KeyMsg.new(k)
end

private def type(app : Tui::App, text : String)
  text.each_char { |c| press(app, c.to_s) }
end

private def started(source = FakeSource.new, width = 120, height = 30) : {Tui::App, FakeSource}
  app = Tui::App.new(source)
  app.glamour_style = "ascii"
  app.poll_interval = 0.seconds
  run(app, app.update(Tea::WindowSizeMsg.new(width, height)))
  run(app, app.init)
  {app, source}
end

private def screen(app : Tui::App) : String
  app.view.gsub(/\e\[[0-9;?]*[a-zA-Z]/, "")
end

private def entry_index(app : Tui::App, key : String) : Int32
  app.sidebar.entries.index { |e| e.key == key } || raise "no sidebar entry #{key}"
end

describe "Tui keys" do
  it "turns Bubble Tea keys into keymap tokens" do
    {"j" => ["j"], "G" => ["G"], "ctrl+d" => ["<C-d>"], "enter" => ["<Enter>"], "esc" => ["<Esc>"],
     "shift+tab" => ["<S-Tab>"], "alt+left" => ["<A-Left>"], "pgdown" => ["<PageDown>"], "?" => ["?"]}.each do |key, tokens|
      Tui.tokens(Tea::KeyMsg.new(key)).should eq(tokens)
    end
    Tui.tokens(Tea::KeyMsg.new("ab", "runes", -1, "ab")).should eq(["a", "b"])
  end

  it "reads sequences and counts like the web app" do
    e = Tui::KeyEngine.new
    e.feed("g").should eq(:pending)
    e.feed("g").should eq(Tui::KeyEngine::Fired.new(Tui::Action::First, nil))
    e.feed("5").should eq(:pending)
    e.pending.should eq("5")
    e.feed("j").should eq(Tui::KeyEngine::Fired.new(Tui::Action::Down, 5))
    e.feed("1")
    e.feed("2")
    e.feed("G").should eq(Tui::KeyEngine::Fired.new(Tui::Action::Last, 12))
    # 0 alone is no count; a key that fits nothing starts over
    e.feed("0").should be_nil
    e.feed("g")
    e.feed("j").should eq(Tui::KeyEngine::Fired.new(Tui::Action::Down, nil))
    e.feed("<C-d>").should eq(Tui::KeyEngine::Fired.new(Tui::Action::HalfDown, nil))
  end

  it "names actions like the web keymap and shows keys for the help" do
    Tui::Action::HalfDown.name.should eq("halfDown")
    Tui::Action::GoLibrary.name.should eq("goLibrary")
    Tui.format_keys("<C-d>").should eq("Strg+D")
    Tui.format_keys("gg").should eq("gg")
    Tui.format_keys("<Down>").should eq("↓")
  end
end

describe "Tui::Query" do
  it "asks for the newest books first by default" do
    p = Tui::Query.new.params(60, 60, "kategorie")
    {p["sort"], p["order"], p["offset"], p["limit"]}.should eq({"added", "desc", "60", "60"})
    p["q"]?.should be_nil
  end

  it "builds the filters like the web app" do
    q = Tui::Query.new(q: " dune ", lang: "deu", unsorted: true, tags: ["a", "b"], author: "X")
    p = q.params(0, 60, "kategorie")
    p["q"].should eq(%((dune) and languages:"=deu" and #kategorie:false))
    p.fetch_all("tag").should eq(["a", "b"])
    p["author"].should eq("X")
    Tui::Query.new(series: "Saga").params(0, 60, nil)["sort"].should eq("series")
    lp = Tui::Query.new(list: 3_i64).params(0, 60, nil)
    {lp["list"], lp["sort"], lp["order"]}.should eq({"3", "listAdded", "desc"})
    Tui::Query.new(list_path: "Reise").params(0, 60, nil)["listPath"].should eq("Reise")
  end

  it "cycles sorts and reverses the order" do
    q = Tui::Query.new.next_sort
    q.effective_sort.should eq({"modified", "desc"})
    q.reverse_order.effective_sort.should eq({"modified", "asc"})
    Tui::Query.new(list: 1_i64).next_sort.effective_sort.should eq({"title", "asc"})
    Tui::Query.new.toggle_tag("a").toggle_tag("a").tags.should be_empty
  end

  it "names the active filters" do
    q = Tui::Query.new(list: 1_i64, kategorie: "A.B", unsorted: false, tags: ["x"])
    q.chips({1_i64 => "Leseliste"}).should eq([{"Liste", "Leseliste"}, {"Kategorie", "A/B"}, {"Tag", "x"}])
  end
end

describe Tui::Markdown do
  it "turns description HTML into Markdown" do
    html = %(<div><p>Ein <b>Buch</b> &amp; <i>mehr</i>.</p><p>Zeile<br/>zwei *</p>
      <ul><li>eins</li><li>zwei</li></ul><a href="https://x.org">Link</a><script>x</script></div>)
    md = Tui::Markdown.from_html(html)
    md.should contain("Ein **Buch** & *mehr*.")
    md.should contain("Zeile  \nzwei \\*")
    md.should contain("- eins\n- zwei")
    md.should contain("[Link](https://x.org)")
  end

  it "keeps plain text paragraphs" do
    Tui::Markdown.from_html("Erster Absatz\nweiter\n\n# kein Titel").should eq("Erster Absatz  \nweiter\n\n\\# kein Titel")
  end
end

describe Tui::Text do
  it "measures and cuts in terminal cells" do
    Tui::Text.width("Bücher").should eq(6)
    Tui::Text.width("日本").should eq(4)
    Tui::Text.truncate("abcdef", 4).should eq("abc…")
    Tui::Text.truncate("a\e]0;x\ab\u009b", 10).should eq("a]0;xb")
    Tui::Text.fit("日本語", 5).should eq("日本…")
    Tui::Text.fit("a\nb", 4).should eq("a b ")
    Tui::Text.wrap("eins zwei drei", 9).should eq(["eins zwei", "drei"])
  end
end

describe Tui::App do
  it "loads the newest books and the sidebar" do
    app, source = started
    app.rows.size.should eq(150)
    source.requests.first["order"].should eq("desc")
    s = screen(app)
    s.should contain("150 Bücher · Hinzugefügt ↓")
    s.should contain("Book 149")
    s.should contain("Fach/Softw…")
    s.should contain("LISTEN")
    s.should contain("Ohne Kategorie")
    s.should contain("FAST-TAGS")
    s.should contain("1/150")
  end

  it "moves with j/k, counts, gg/G and loads pages where the cursor goes" do
    app, source = started
    press(app, "j", "j", "k")
    app.cursor.should eq(1)
    press(app, "5", "j")
    app.cursor.should eq(6)
    press(app, "G")
    app.cursor.should eq(149)
    # the last page, not all pages before it
    source.requests.map(&.["offset"]?).should contain("120")
    source.requests.map(&.["offset"]?).should_not contain("60")
    app.rows[149].not_nil!.title.should eq("Book 1")
    press(app, "g", "g")
    app.cursor.should eq(0)
    press(app, "3", "G")
    app.cursor.should eq(2)
    screen(app).should contain("3/150")
  end

  it "scrolls half and whole pages with Ctrl-d/u and Ctrl-f/b" do
    app, source = started(height: 30)
    press(app, "ctrl+d")
    app.cursor.should eq(13)
    app.offset.should eq(13)
    press(app, "ctrl+f", "ctrl+f")
    app.cursor.should eq(13 + 54)
    # page 2 was needed on the way
    source.requests.map(&.["offset"]?).should contain("60")
    press(app, "ctrl+u")
    app.cursor.should eq(13 + 54 - 13)
  end

  it "searches with /, goes back with q and quits with q at the start" do
    app, source = started
    press(app, "j", "j")
    press(app, "/")
    app.searching?.should be_true
    type(app, "dune")
    screen(app).should contain("/dune")
    press(app, "enter").should be_false
    app.searching?.should be_false
    source.requests.last["q"].should eq("(dune)")
    app.rows.size.should eq(15)
    app.cursor.should eq(0)
    screen(app).should contain("Suche: dune")
    # n/N: next and previous result
    press(app, "n", "n", "N")
    app.cursor.should eq(1)
    press(app, "q").should be_false
    app.query.q.should be_nil
    app.cursor.should eq(2)
    app.rows.size.should eq(150)
    press(app, "esc").should be_false
    press(app, "q").should be_true
  end

  it "cancels a search with Esc" do
    app, _ = started
    press(app, "/")
    type(app, "x")
    press(app, "esc")
    app.searching?.should be_false
    app.query.q.should be_nil
  end

  it "says so when n has no search" do
    app, _ = started
    press(app, "n")
    app.cursor.should eq(0)
    screen(app).should contain("Keine Suche aktiv")
  end

  it "opens a book with Enter and shows its metadata and description" do
    app, source = started
    press(app, "j", "enter")
    app.detail.should eq(1)
    s = screen(app)
    s.should contain("Book 149")
    s.should contain("Author 2")
    s.should contain("Kategorie   Fach/Software")
    s.should contain("Listen      Leseliste")
    s.should contain("Bewertung   ★★★★☆")
    s.should contain("Kennungen   isbn:978149")
    s.should_not contain("Erschienen")
    s.should contain("About **book** 149.") # Glamour "ascii" keeps the markers
    source.book_requests.should eq([149_i64])
    s.should contain("Cover")
    # n: next book of the result
    press(app, "n")
    app.detail.should eq(2)
    app.cursor.should eq(2)
    screen(app).should contain("Book 148")
    press(app, "q").should be_false
    app.detail.should be_nil
    screen(app).should contain("3/150")
  end

  it "scrolls a long description" do
    source = FakeSource.new
    app, _ = started(source, height: 12)
    press(app, "enter")
    press(app, "G")
    app.detail_scroll.should be > 0
    press(app, "g", "g")
    app.detail_scroll.should eq(0)
  end

  it "filters from the sidebar and toggles the filter off again" do
    app, source = started
    press(app, "h")
    app.focus.sidebar?.should be_true
    app.sidebar.to(entry_index(app, "unsorted"))
    press(app, "enter")
    app.query.unsorted.should be_true
    source.requests.last["q"].should eq("#kategorie:false")
    app.rows.size.should eq(50)
    screen(app).should contain("Ohne Kategorie")
    app.sidebar.to(entry_index(app, "f:leseliste"))
    press(app, "enter")
    app.query.tags.should eq(["leseliste"])
    source.requests.last.fetch_all("tag").should eq(["leseliste"])
    press(app, "enter")
    app.query.tags.should be_empty
    # back through the history
    press(app, "q")
    app.query.tags.should eq(["leseliste"])
    press(app, "q", "q")
    app.query.filters?.should be_false
  end

  it "folds the category tree with l and h" do
    app, source = started
    press(app, "h")
    app.sidebar.to(entry_index(app, "k:Fach"))
    app.sidebar.entries.any? { |e| e.key == "k:Fach.Software" }.should be_false
    press(app, "l")
    app.sidebar.entries.any? { |e| e.key == "k:Fach.Software" }.should be_true
    press(app, "l") # into the child
    app.sidebar.current.not_nil!.key.should eq("k:Fach.Software")
    press(app, "enter")
    source.requests.last["kategorie"].should eq("Fach.Software")
    press(app, "h") # to the parent
    app.sidebar.current.not_nil!.key.should eq("k:Fach")
    press(app, "h") # fold
    app.sidebar.entries.any? { |e| e.key == "k:Fach.Software" }.should be_false
    press(app, "tab")
    app.focus.list?.should be_true
  end

  it "shows the most frequent authors until all are asked for" do
    app, _ = started
    authors = -> { app.sidebar.entries.count(&.key.starts_with?("authors:")) }
    authors.call.should eq(8)
    press(app, "h")
    app.sidebar.to(entry_index(app, "more:authors"))
    press(app, "enter")
    authors.call.should eq(12)
    app.sidebar.current.not_nil!.label.should eq("Weniger")
  end

  it "builds the list tree, levels without a list filter by path" do
    app, source = started
    press(app, "h")
    app.sidebar.to(entry_index(app, "l:Reise"))
    press(app, "enter")
    source.requests.last["listPath"].should eq("Reise")
    app.sidebar.to(entry_index(app, "l:Leseliste"))
    press(app, "enter")
    source.requests.last["list"].should eq("1")
    source.requests.last["sort"].should eq("listAdded")
    screen(app).should contain("Liste: Leseliste")
  end

  it "changes the sort with o and O without a step back" do
    app, source = started
    press(app, "o")
    {source.requests.last["sort"], source.requests.last["order"]}.should eq({"modified", "desc"})
    press(app, "O")
    source.requests.last["order"].should eq("asc")
    screen(app).should contain("Geändert ↑")
    app.history.should be_empty
  end

  it "shows the help with ? and closes it with any key" do
    app, _ = started
    press(app, "?")
    app.help?.should be_true
    screen(app).should contain("Tastenkürzel")
    screen(app).should contain("Strg+D")
    press(app, "j")
    app.help?.should be_false
    app.cursor.should eq(0)
  end

  it "hides the sidebar on narrow terminals until it has the focus" do
    app, _ = started(width: 70)
    screen(app).should_not contain("LISTEN")
    press(app, "h")
    screen(app).should contain("LISTEN")
    screen(app).should_not contain("Book 150")
  end

  it "shows errors of the hub in the status line" do
    source = FakeSource.new
    source.fail = true
    app, _ = started(source)
    screen(app).should contain("hub down")
    source.fail = false
    press(app, "o")
    app.rows.size.should eq(150)
  end

  it "drops pages of an older query" do
    app, source = started
    stale = Tui::PageMsg.new(app.rows.generation - 1, 0, source.books(HTTP::Params.parse("q=dune")))
    app.update(stale)
    app.rows.size.should eq(150)
  end

  it "works with hubs without lists" do
    source = FakeSource.new
    source.lists_json = "{"
    app, _ = started(source)
    screen(app).should_not contain("LISTEN")
    screen(app).should contain("KATEGORIEN")
  end
end

private def command(app : Tui::App, line : String) : Bool
  press(app, ":")
  type(app, line)
  press(app, "enter")
end

private def last_write(source : FakeSource) : {String, JSON::Any}
  source.writes.last? || raise "no write"
end

describe Tui::Commands do
  it "parses CLI words, German words and the web app's action ids" do
    Tui::Commands.parse("tag add sheet music").should eq({"addTags", "sheet music"})
    Tui::Commands.parse(":tag rm sf").should eq({"removeTags", "sf"})
    Tui::Commands.parse("kategorie Roman/Fantasy").should eq({"kategorie", "Roman/Fantasy"})
    Tui::Commands.parse("addToList Leseliste").should eq({"addToList", "Leseliste"})
    Tui::Commands.parse("list new Urlaub / 2026").should eq({"newList", "Urlaub / 2026"})
    Tui::Commands.parse("sort added desc").should eq({"sort", "added desc"})
    Tui::Commands.parse("trash").should eq({"delete", ""})
    Tui::Commands.parse("12").should eq({"line", "12"})
    Tui::Commands.parse("tag").should be_nil
    Tui::Commands.parse("frobnicate").should be_nil
  end

  it "completes commands, subcommands and values" do
    c = Tui::Choices.new
    c.tags = ["leseliste", "sf", "Sheet Music"]
    c.kategorien = ["Fach", "Fach/Software", "Roman/Fantasy"]
    Tui::Completion.command_line("ta", c).should eq({0, ["tag"], true})
    Tui::Completion.command_line("tag a", c).should eq({4, ["add"], true})
    Tui::Completion.command_line("tag add s", c).should eq({8, ["sf", "Sheet Music", "leseliste"], false})
    # a list value: the item after the last comma
    Tui::Completion.command_line("tag add sf, le", c).should eq({12, ["leseliste"], false})
    # starting with it first, then containing it
    Tui::Completion.command_line("kategorie soft", c).should eq({10, ["Fach/Software"], false})
    Tui::Completion.command_line("sort ad", c).should eq({5, ["added"], true})
    Tui::Completion.command_line("sort added d", c).should eq({11, ["desc"], false})
    Tui::Completion.common_prefix(["Fach", "Fach/Software"]).should eq("Fach")
  end
end

describe Tui::Changes do
  book = Tui::Book.new(JSON.parse(%({"id":1,"title":"T","tags":["a","B"],"custom":{"kategorie":"X.Y"},
    "pubdate":"1990-05-06T12:00:00+00:00","rating":6,"series":"S","seriesIndex":2})))

  it "makes the web app's changes from a typed value" do
    act = ->(id : String, v : String) { Tui::Changes.for(Tui.book_action(id).not_nil!, v).to_json }
    act.call("addTags", "x, y ,x").should eq(%({"addTags":["x","y"]}))
    act.call("kategorie", "Roman/Fantasy").should eq(%({"kategorie":"Roman.Fantasy"}))
    act.call("kategorie", "-").should eq(%({"kategorie":null}))
    act.call("seriesNumbered", "Dune").should eq(%({"series":"Dune","numberSeries":true}))
    act.call("authors", "A & B").should eq(%({"authors":["A","B"]}))
    act.call("rating", "4").should eq(%({"rating":8}))
    act.call("rating", "0").should eq(%({"rating":null}))
    act.call("year", "2001").should eq(%({"pubYear":2001}))
    expect_raises(Tui::Invalid) { act.call("rating", "7") }
    expect_raises(Tui::Invalid) { act.call("kategorie", "Roman/Sci.Fi") }
    expect_raises(Tui::Invalid) { act.call("addTags", " ") }
  end

  it "patches one book, shows it at once and knows the way back" do
    body = Tui::Changes.patch({"pubYear" => JSON::Any.new(2001_i64), "removeTags" => JSON.parse(%(["b"]))}, book)
    body.to_json.should eq(%({"removeTags":["b"],"pubdate":"2001-05-06"}))
    after = Tui::Changes.apply(book, body.merge({"kategorie" => JSON::Any.new("Z")}), "kategorie")
    after.tags.should eq(["a"])
    after.category("kategorie").should eq("Z")
    back = Tui::Changes.undo(body.merge({"kategorie" => JSON::Any.new("Z"), "rating" => JSON::Any.new(nil)}), book, "kategorie")
    back.to_json.should eq(%({"tags":["a","B"],"pubdate":"1990-05-06","kategorie":"X.Y","rating":6}))
  end
end

describe Tui::EditForm do
  book = Tui::Book.new(JSON.parse(%({"id":1,"title":"Dune","authors":["Frank Herbert"],"tags":["sf"],
    "languages":["eng"],"custom":{"kategorie":"Roman.SF"},"identifiers":{"isbn":"123"},
    "comments":"<p>A <b>desert</b> planet.</p>","rating":8,"lastModified":"v7"})))

  it "sends only changed fields with the lastModified read" do
    orig = Tui::EditForm.values(book, "kategorie")
    orig["kategorie"].should eq("Roman/SF")
    orig["rating"].should eq("4")
    orig["comments"].should eq("A **desert** planet.")
    Tui::EditForm.patch(orig, orig, "v7", "kategorie").should be_nil
    form = orig.merge({"tags" => "sf, Klassiker", "kategorie" => "Roman/Science Fiction", "pubdate" => "1965-08-01",
                       "identifiers" => "isbn:123, asin:B00", "comments" => "A **desert** planet.\n\nWorms."})
    Tui::EditForm.patch(orig, form, "v7", "kategorie").to_json.should eq(
      %({"kategorie":"Roman.Science Fiction","tags":["sf","Klassiker"],"pubdate":"1965-08-01",) +
      %("identifiers":{"isbn":"123","asin":"B00"},"comments":"<p>A <b>desert</b> planet.</p><p>Worms.</p>","lastModified":"v7"}))
    expect_raises(Tui::Invalid) { Tui::EditForm.patch(orig, orig.merge({"title" => " "}), "v7", nil) }
    expect_raises(Tui::Invalid) { Tui::EditForm.patch(orig, orig.merge({"pubdate" => "1965"}), "v7", nil) }
    expect_raises(Tui::Invalid) { Tui::EditForm.patch(orig, orig.merge({"identifiers" => "isbn"}), "v7", nil) }
  end
end

describe "Tui writes" do
  it "runs `:` commands on the cursor book and undoes them" do
    app, source = started
    id = app.rows[0].not_nil!.id
    command(app, "tag add Klassiker")
    last_write(source).should eq({"PATCH #{id}", JSON.parse(%({"addTags":["Klassiker"]}))})
    app.rows[0].not_nil!.tags.should eq(["sf", "Klassiker"])
    screen(app).should contain("Tags hinzufügen: Dune 150")
    press(app, "u")
    last_write(source).should eq({"PATCH #{id}", JSON.parse(%({"tags":["sf"],"lastModified":"v1"}))})
    app.rows[0].not_nil!.tags.should eq(["sf"])
    press(app, "u")
    screen(app).should contain("Nichts zurückzunehmen")
  end

  it "toggles fast tags optimistically and takes them back on errors" do
    app, source = started
    press(app, "T")
    screen(app).should contain("1 leseliste")
    source.fail_writes = true
    # the change shows before the hub answers
    cmd = app.update(Tea::KeyMsg.new("1"))
    app.rows[0].not_nil!.tags.should eq(["sf", "leseliste"])
    run(app, cmd)
    app.rows[0].not_nil!.tags.should eq(["sf"])
    screen(app).should contain("hub down")
    source.fail_writes = false
    press(app, "T", "1")
    app.rows[0].not_nil!.tags.should eq(["sf", "leseliste"])
    press(app, "T", "1")
    last_write(source)[1].should eq(JSON.parse(%({"removeTags":["leseliste"]})))
  end

  it "changes a selection as a bulk job and undoes it on the hub" do
    app, source = started
    source.job_polls_running = 1
    press(app, " ", "j", " ")
    app.selection.size.should eq(2)
    screen(app).should contain("2 ausgewählt")
    ids = app.selection.dup
    command(app, "kategorie Fach/Neu")
    last_write(source).should eq({"BULK", JSON.parse({target: {ids: ids}, changes: {kategorie: "Fach.Neu"}}.to_json)})
    screen(app).should contain("Kategorie setzen (2): 2 von 2 erledigt")
    press(app, "u")
    last_write(source).should eq({"UNDO job1", JSON::Any.new(nil)})
    press(app, "esc")
    app.selection.should be_empty
  end

  it "numbers a series only for several books" do
    app, source = started
    command(app, "nummerieren Saga")
    screen(app).should contain("nur für mehrere")
    source.writes.should be_empty
  end

  it "asks before deleting and restores from the trash" do
    app, source = started
    id = app.rows[0].not_nil!.id
    press(app, "d", "d")
    screen(app).should contain("„Dune 150“ in den Papierkorb verschieben? [j/N]")
    press(app, "n")
    source.writes.should be_empty
    press(app, "d", "d", "j")
    last_write(source)[0].should eq("DELETE #{id}")
    press(app, "u")
    last_write(source)[0].should eq("RESTORE #{id}")
  end

  it "puts books on lists, creating one when asked" do
    app, source = started
    id = app.rows[0].not_nil!.id
    # t: the default list; the fake's books are on it already
    press(app, "t")
    last_write(source).should eq({"LIST rm 1", JSON.parse("[#{id}]")})
    command(app, "list add Urlaub")
    screen(app).should contain("Liste „Urlaub“ gibt es nicht")
    press(app, "j")
    source.writes.last(2).map(&.[0]).should eq(["NEWLIST", "LIST add 9"])
    command(app, "list add reise/meer")
    last_write(source).should eq({"LIST add 2", JSON.parse("[#{id}]")})
    press(app, "u")
    last_write(source).should eq({"LIST rm 2", JSON.parse("[#{id}]")})
  end

  it "sorts, searches and jumps from the command line" do
    app, source = started
    command(app, "sort title")
    source.requests.last["sort"].should eq("title")
    source.requests.last["order"].should eq("asc")
    command(app, "sort rating up")
    screen(app).should contain("asc oder desc")
    command(app, "12")
    app.cursor.should eq(11)
    command(app, "search dune")
    app.query.q.should eq("dune")
    command(app, "nope")
    screen(app).should contain("Unbekannter Befehl: nope")
  end

  it "keeps what is typed in the same message as the `:`" do
    app, _ = started
    run(app, app.update(Tea::KeyMsg.new(":so", "runes", -1, ":so")))
    app.command_line.value.should eq("so")
  end

  it "completes with Tab and keeps a history" do
    dir = File.tempname("tui-history")
    file = File.join(dir, "history")
    begin
      app, _ = started
      app.history_file = file
      press(app, ":")
      type(app, "so")
      press(app, "tab")
      app.command_line.value.should eq("sort ")
      type(app, "a")
      press(app, "tab")
      # "author" and "added" (in the order of the sorts): nothing in common
      # past "a", so it cycles
      app.command_line.value.should eq("sort author")
      screen(app).should contain("added")
      press(app, "tab")
      app.command_line.value.should eq("sort added")
      press(app, "enter")
      app.query.sort.should eq("added")
      press(app, ":", "up")
      app.command_line.value.should eq("sort added")
      press(app, "esc")
      File.read(file).should eq("sort added\n")
      Tui::CommandLine.new(file).history.should eq(["sort added"])
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "edits a book in the form, with completion and conflicts" do
    app, source = started
    id = app.rows[0].not_nil!.id
    press(app, "e")
    form = app.form.not_nil!
    screen(app).should contain("Bearbeiten: Dune 150")
    type(app, " II")
    # down to the tags: authors, series, volume, category, tags
    5.times { press(app, "down") }
    form.fields[form.focus].key.should eq("tags")
    type(app, ", lese")
    press(app, "tab")
    form.value("tags").should eq("sf, leseliste")
    source.conflict_next = true
    press(app, "ctrl+s")
    last_write(source).should eq({"PATCH #{id}", JSON.parse(%({"title":"Dune 150 II","tags":["sf","leseliste"],"lastModified":"v0"}))})
    screen(app).should contain("inzwischen geändert")
    screen(app).should contain("Changed meanwhile")
    press(app, "m")
    press(app, "ctrl+s")
    last_write(source).should eq({"PATCH #{id}", JSON.parse(%({"title":"Dune 150 II","tags":["sf","leseliste"],"lastModified":"v1"}))})
    app.form.should be_nil
    app.rows[0].not_nil!.title.should eq("Dune 150 II")
    screen(app).should contain("Gespeichert")
  end

  it "asks before dropping changes in the form" do
    app, source = started
    press(app, "e")
    press(app, "esc")
    app.form.should be_nil
    press(app, "e")
    type(app, "x")
    press(app, "esc")
    screen(app).should contain("Änderungen verwerfen? [j/N]")
    press(app, "n")
    app.form.should_not be_nil
    press(app, "esc", "j")
    app.form.should be_nil
    source.writes.should be_empty
  end
end

describe "Tui markdown back to HTML" do
  it "writes what from_html reads" do
    html = "<p>One <b>bold</b> and <i>it</i> &amp; more.<br>Next</p><ul><li>a</li><li>b</li></ul><h2>Head</h2>"
    md = Tui::Markdown.from_html(html)
    Tui::Markdown.to_html(md).should eq(html)
    Tui::Markdown.to_html("a \\* b").should eq("<p>a * b</p>")
  end
end
