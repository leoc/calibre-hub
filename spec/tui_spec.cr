require "spec"
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
  property lists_json = %([{"id":1,"name":"Leseliste","parent":null,"leaf":"Leseliste","count":2},
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
    book(id.to_i)
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
  keys.any? { |k| run(app, app.update(Tea::KeyMsg.new(k))) }
end

private def type(app : Tui::App, text : String)
  text.each_char { |c| press(app, c.to_s) }
end

private def started(source = FakeSource.new, width = 120, height = 30) : {Tui::App, FakeSource}
  app = Tui::App.new(source)
  app.glamour_style = "ascii"
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
