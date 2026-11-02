require "spec"
require "file_utils"
require "kemal"
require "../src/calibre_hub/api"
require "../src/calibre_hub/handlers/leseliste"

private def body(json : String) : Hash(String, JSON::Any)
  JSON.parse(json).as_h
end

private def with_lists(exists : CalibreHub::Lists::Exists? = nil, &)
  path = File.tempname("hub-lists", ".sqlite")
  db = DB.open("sqlite3://#{path}?max_pool_size=1")
  yield CalibreHub::Lists.new(db, exists), db, path
ensure
  db.try &.close
  File.delete?(path) if path
end

private def events(db) : Array(JSON::Any)
  rows = [] of JSON::Any
  db.query_each("select payload from events where type = 'list' order by id") { |rs| rows << JSON.parse(rs.read(String)) }
  rows
end

describe CalibreHub::Lists do
  it "creates, changes and deletes lists, one default per owner" do
    with_lists do |lists, db|
      a = lists.create("arthur", body(%({"name": " Urlaub ", "description": "Strand", "sync": true})))
      a.name.should eq("Urlaub")
      a.description.should eq("Strand")
      a.sync.should be_true
      a.visibility.should eq("private")
      a.owner.should eq("arthur")
      b = lists.create("arthur", body(%({"name": "Fachbuch", "isDefault": true, "favorite": true})))
      b.is_default.should be_true
      lists.update(a.id, "arthur", body(%({"isDefault": true}))).is_default.should be_true
      lists[b.id, "arthur"].is_default.should be_false
      # favorites first, then by name
      lists.all("arthur").map(&.name).should eq(["Fachbuch", "Urlaub"])

      expect_raises(CalibreHub::Lists::Taken) { lists.create("arthur", body(%({"name": "urlaub"}))) }
      expect_raises(CalibreHub::Lists::Taken) { lists.update(b.id, "arthur", body(%({"name": "URLAUB"}))) }
      expect_raises(CalibreHub::Edit::Invalid, "name expected") { lists.create("arthur", body(%({"name": "  "}))) }
      expect_raises(CalibreHub::Edit::Invalid, "one of") { lists.update(a.id, "arthur", body(%({"visibility": "public"}))) }
      expect_raises(CalibreHub::Edit::Invalid, "unknown field") { lists.update(a.id, "arthur", body(%({"color": "red"}))) }
      # the same name is fine for someone else
      lists.create("tilli", body(%({"name": "Urlaub"}))).name.should eq("Urlaub")

      renamed = lists.update(a.id, "arthur", body(%({"name": "Sommer"})))
      renamed.name.should eq("Sommer")
      lists.delete(a.id, "arthur").name.should eq("Sommer")
      expect_raises(CalibreHub::Lists::NotFound) { lists[a.id, "arthur"] }

      e = events(db)
      e.map { |x| x["action"].as_s }.should eq(%w(created created updated created updated deleted))
      e[4]["previous"]["name"].should eq("Urlaub")
      e[4]["list"]["name"].should eq("Sommer")
      e[0]["type"].should eq("list")
      e[0]["bookId"].should eq(0)
    end
  end

  it "keeps others' private lists hidden and read-only lists unchanged" do
    with_lists do |lists|
      mine = lists.create("arthur", body(%({"name": "Privat"})))
      shown = lists.create("arthur", body(%({"name": "Gezeigt", "visibility": "readable"})))
      shared = lists.create("arthur", body(%({"name": "Gemeinsam", "visibility": "editable"})))
      lists.all("tilli").map(&.name).should eq(["Gemeinsam", "Gezeigt"])
      expect_raises(CalibreHub::Lists::NotFound) { lists[mine.id, "tilli"] }
      lists[shown.id, "tilli"].editable.should be_false
      expect_raises(CalibreHub::Lists::Forbidden) { lists.add(shown.id, "tilli", [1_i64]) }
      lists.add(shared.id, "tilli", [1_i64])[1].should eq([1_i64])
      expect_raises(CalibreHub::Lists::Forbidden) { lists.delete(shared.id, "tilli") }
      lists.memberships([1_i64], "tilli").should eq({1_i64 => [shared.id]})
    end
  end

  it "adds and removes books, newest first, only known ones" do
    exists = ->(ids : Array(Int64)) { ids.reject { |i| i == 999 } }
    with_lists(exists) do |lists, db|
      l = lists.create("arthur", body(%({"name": "Leseliste"})))
      l.last_used_at.should be_nil
      list, added = lists.add(l.id, "arthur", [3_i64, 4_i64, 999_i64, 3_i64])
      added.should eq([3_i64, 4_i64])
      list.count.should eq(2)
      list.last_used_at.should_not be_nil
      sleep 2.milliseconds
      _, added = lists.add(l.id, "arthur", [5_i64, 3_i64])
      added.should eq([5_i64])
      # the newest first; one bulk add keeps its order reversed
      lists.book_ids(l.id).should eq([5_i64, 4_i64, 3_i64])
      lists[l.id, "arthur"].cover_book_ids.should eq([5_i64, 4_i64, 3_i64])
      _, removed = lists.remove(l.id, "arthur", [4_i64, 77_i64])
      removed.should eq([4_i64])
      lists.memberships([3_i64, 4_i64], "arthur").should eq({3_i64 => [l.id], 4_i64 => [] of Int64})
      lists.lists_of(3_i64, "arthur").map(&.id).should eq([l.id])
      e = events(db)
      e.map { |x| {x["action"].as_s, x["bookIds"].as_a.map(&.as_i64)} }.should eq([
        {"created", [] of Int64}, {"added", [3_i64, 4_i64]}, {"added", [5_i64]}, {"removed", [4_i64]},
      ])
      e[1]["list"]["count"].should eq(2)
    end
  end

  it "takes deleted books out of their lists and back in on restore" do
    with_lists do |lists, db|
      a = lists.create("arthur", body(%({"name": "A"})))
      b = lists.create("arthur", body(%({"name": "B"})))
      lists.add(a.id, "arthur", [1_i64, 2_i64])
      lists.add(b.id, "arthur", [1_i64])
      db.exec "insert into meta (key, value) values ('lists_event_seq', '0')"
      db.exec "insert into events (type, book_id, payload, created_at) values ('deleted', 1, '{}', 0)"
      lists.follow_events
      lists.book_ids(a.id).should eq([2_i64])
      lists.book_ids(b.id).should be_empty
      events(db).last(2).map { |x| {x["listId"].as_i64, x["action"].as_s, x["bookIds"][0].as_i64} }.should eq([
        {a.id, "removed", 1_i64}, {b.id, "removed", 1_i64},
      ])
      lists.book_restored(1_i64, 42_i64)
      lists.book_ids(a.id).sort.should eq([2_i64, 42_i64])
      lists.book_ids(b.id).should eq([42_i64])
      # restored once
      lists.book_restored(1_i64, 43_i64)
      lists.book_ids(b.id).should eq([42_i64])
    end
  end

  it "migrates the reading list tag once" do
    with_lists do |lists, db|
      lists.migrated?.should be_false
      l = lists.migrate("arthur", "leseliste", [7_i64, 8_i64]).not_nil!
      l.name.should eq("Leseliste")
      l.sync.should be_true
      l.is_default.should be_true
      l.favorite.should be_true
      lists.book_ids(l.id).should eq([8_i64, 7_i64])
      lists.migrated?.should be_true
      lists.migrate("arthur", "leseliste", [9_i64]).should be_nil
      lists.book_ids(l.id).should eq([8_i64, 7_i64])
      e = events(db).last
      {e["action"], e["bookIds"].as_a.map(&.as_i64)}.should eq({"created", [8_i64, 7_i64]})
    end
  end
end

private def call(method, path, body = nil)
  io = IO::Memory.new
  request = HTTP::Request.new(method, path, HTTP::Headers{"X-Calibre-Hub" => "1"}, body)
  ctx = HTTP::Server::Context.new(request, HTTP::Server::Response.new(io))
  Kemal::RouteHandler::INSTANCE.call(ctx)
  ctx.response.close
  response = HTTP::Client::Response.from_io(IO::Memory.new(io.to_s))
  {response.status_code, response.body.presence.try { |b| JSON.parse(b) }}
end

describe "list routes" do
  it "serves the list API" do
    with_lists(->(ids : Array(Int64)) { ids.reject { |i| i == 999 } }) do |lists|
      auth = CalibreHub::Auth.new("arthur", "pw", Bytes.new(32))
      CalibreHub.list_routes(lists, auth, nil)

      status, l = call("POST", "/api/lists", %({"name": "Leseliste", "sync": true}))
      status.should eq(201)
      id = l.not_nil!["id"].as_i64
      l.not_nil!["owner"].should eq("arthur")
      call("POST", "/api/lists", %({"name": "leseliste"}))[0].should eq(409)
      call("POST", "/api/lists", %({"name": 3}))[0].should eq(400)

      status, r = call("POST", "/api/lists/#{id}/books", %({"bookIds": [1, 2, 999]}))
      status.should eq(200)
      r.not_nil!["added"].should eq(JSON.parse("[1, 2]"))
      r.not_nil!["list"]["count"].should eq(2)
      call("POST", "/api/lists/#{id}/books", %({"target": {"ids": [1]}}))[0].should eq(400)
      call("PUT", "/api/lists/#{id}/books/3")[1].not_nil!["added"].should eq(JSON.parse("[3]"))
      call("PUT", "/api/lists/#{id}/books/3")[0].should eq(200)
      call("PUT", "/api/lists/#{id}/books/999")[0].should eq(404)
      call("DELETE", "/api/lists/#{id}/books/3")[1].not_nil!["removed"].should eq(JSON.parse("[3]"))
      status, r = call("POST", "/api/lists/#{id}/books/remove", %({"bookIds": [1]}))
      status.should eq(200)
      r.not_nil!["list"]["count"].should eq(1)

      status, all = call("GET", "/api/lists")
      status.should eq(200)
      all.not_nil!.as_a.map(&.["name"].as_s).should eq(["Leseliste"])
      call("GET", "/api/books/2/lists")[1].not_nil!.as_a.map(&.["id"].as_i64).should eq([id])

      status, l = call("PATCH", "/api/lists/#{id}", %({"description": "Für den Boox", "isDefault": true}))
      status.should eq(200)
      l.not_nil!["description"].should eq("Für den Boox")
      l.not_nil!["isDefault"].should be_true
      call("PATCH", "/api/lists/#{id}", %({"sync": "ja"}))[0].should eq(400)
      call("GET", "/api/lists/999")[0].should eq(404)
      call("GET", "/api/lists/x")[0].should eq(404)
      call("DELETE", "/api/lists/#{id}")[0].should eq(200)
      call("GET", "/api/lists/#{id}")[0].should eq(404)
    end
  end

  it "pages a list by the time books were added" do
    with_lists do |lists|
      l = lists.create("arthur", body(%({"name": "L"})))
      lists.add(l.id, "arthur", [1_i64, 2_i64, 3_i64])
      calibre = CalibreHub::Calibre.new("http://127.0.0.1:1", "x", "x")
      page = ->(q : String) { CalibreHub::Api.list_page(lists, calibre, l.id, "arthur", HTTP::Params.parse(q), nil, 0, 2) }
      page.call("").should eq({3, [3_i64, 2_i64]})
      page.call("order=asc").should eq({3, [1_i64, 2_i64]})
      expect_raises(CalibreHub::Edit::Invalid) { page.call("sort=rating") }
      expect_raises(CalibreHub::Lists::NotFound) { CalibreHub::Api.list_page(lists, calibre, l.id, "tilli", HTTP::Params.new, nil, 0, 2) }
    end
  end
end

# A library with three books and their files
private def with_library(&)
  dir = File.tempname("leseliste-lib")
  Dir.mkdir_p(dir)
  db = DB.open("sqlite3://#{File.join(dir, "metadata.db")}")
  db.exec "create table books (id integer primary key, title text, path text, series_index real)"
  db.exec "create table series (id integer primary key, name text)"
  db.exec "create table books_series_link (id integer primary key, book integer, series integer)"
  db.exec "create table authors (id integer primary key, name text, sort text)"
  db.exec "create table books_authors_link (id integer primary key, book integer, author integer)"
  db.exec "create table data (id integer primary key, book integer, format text, name text)"
  db.exec "insert into authors (id, name, sort) values (1, 'Ada Lovelace', 'Lovelace, Ada')"
  db.exec "insert into series (id, name) values (1, 'Dune')"
  {1 => "Erstes", 2 => "Zweites", 3 => "Ohne Datei"}.each do |id, title|
    path = "Ada Lovelace/#{title} (#{id})"
    db.exec "insert into books (id, title, path, series_index) values (?, ?, ?, ?)", id, title, path, id.to_f
    db.exec "insert into books_authors_link (book, author) values (?, 1)", id
    next if id == 3
    Dir.mkdir_p(File.join(dir, path))
    File.write(File.join(dir, path, "book.epub"), "epub #{id}")
    db.exec "insert into data (book, format, name) values (?, 'EPUB', 'book')", id
  end
  db.exec "insert into books_series_link (book, series) values (2, 1)"
  db.close
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

private def files(dir) : Array(String)
  Dir.glob(File.join(dir, "**", "*")).select { |f| File.file?(f) }.map(&.lchop(dir + "/")).sort
end

describe CalibreHub::Leseliste do
  it "only reacts to relevant changes of books in synced lists" do
    synced = Set{1_i64}
    rating = JSON.parse(%({"type":"changed","bookId":1,"changes":{"rating":[1,2]}}))
    CalibreHub::Leseliste.relevant?(rating, synced).should be_false
    title = JSON.parse(%({"type":"changed","bookId":1,"changes":{"title":["a","b"]}}))
    CalibreHub::Leseliste.relevant?(title, synced).should be_true
    other = JSON.parse(%({"type":"changed","bookId":2,"changes":{"title":["a","b"]}}))
    CalibreHub::Leseliste.relevant?(other, synced).should be_false
    CalibreHub::Leseliste.relevant?(JSON.parse(%({"type":"deleted","bookId":1})), synced).should be_true
    unsynced = JSON.parse(%({"type":"list","bookId":0,"list":{"sync":false}}))
    CalibreHub::Leseliste.relevant?(unsynced, synced).should be_false
    turned_off = JSON.parse(%({"type":"list","bookId":0,"list":{"sync":false},"previous":{"sync":true}}))
    CalibreHub::Leseliste.relevant?(turned_off, synced).should be_true
    CalibreHub::Leseliste.relevant?(nil, synced).should be_true
  end

  it "names files like the old export" do
    CalibreHub::Leseliste.series_number(2.0).should eq("02")
    CalibreHub::Leseliste.series_number(2.5).should eq("2.5")
    CalibreHub::Leseliste.clean(%(a/b: "c"?.)).should eq("a_b_ _c__")
  end

  it "mirrors one folder per synced list and follows changes" do
    with_library do |library|
      with_lists do |lists, db, state|
        target = File.tempname("leseliste-target")
        begin
          env = {"LESELISTE_TARGET" => target, "CALIBRE_HUB_LIBRARY" => library, "CALIBRE_HUB_STATE_DB" => state}
          run = ->(event : String) { CalibreHub::Leseliste.run(env, IO::Memory.new(event)).should eq(0) }
          # before the migration nothing is touched
          Dir.mkdir_p(File.join(target, "Fachbuch"))
          File.write(File.join(target, "Fachbuch", "alt.epub"), "x")
          run.call("")
          files(target).should eq(["Fachbuch/alt.epub"])

          lists.migrate("arthur", "leseliste", [1_i64])
          urlaub = lists.create("arthur", body(%({"name": "Urlaub: Strand", "sync": true})))
          lists.create("arthur", body(%({"name": "Nicht synchron"})))
          lists.add(urlaub.id, "arthur", [1_i64, 2_i64, 3_i64])
          run.call("")
          files(target).should eq([
            "Leseliste/Lovelace, Ada - Erstes.epub",
            "Urlaub_ Strand/Lovelace, Ada - Dune 02 - Zweites.epub",
            "Urlaub_ Strand/Lovelace, Ada - Erstes.epub",
          ])

          lists.remove(urlaub.id, "arthur", [1_i64])
          lists.update(urlaub.id, "arthur", body(%({"name": "Sommer"})))
          rename = db.query_one("select payload from events order by id desc limit 1", as: String)
          run.call(rename)
          files(target).should eq([
            "Leseliste/Lovelace, Ada - Erstes.epub",
            "Sommer/Lovelace, Ada - Dune 02 - Zweites.epub",
          ])

          lists.update(urlaub.id, "arthur", body(%({"sync": false})))
          run.call(db.query_one("select payload from events order by id desc limit 1", as: String))
          files(target).should eq(["Leseliste/Lovelace, Ada - Erstes.epub"])
        ensure
          FileUtils.rm_rf(target)
        end
      end
    end
  end
end
