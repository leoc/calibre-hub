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

  it "nests lists by their path and renames sublists along" do
    with_lists do |lists, db|
      {"/Urlaub", "Urlaub/", "Urlaub//2026", " / "}.each do |bad|
        expect_raises(CalibreHub::Edit::Invalid, "no empty level") { lists.create("arthur", body(%({"name": #{bad.to_json}}))) }
      end
      sub = lists.create("arthur", body(%({"name": " Urlaub / 2026 "})))
      sub.name.should eq("Urlaub/2026")
      sub.parent.should eq("Urlaub")
      sub.leaf.should eq("2026")
      # the levels above keep their spelling
      lists.create("arthur", body(%({"name": "urlaub/2025"}))).name.should eq("Urlaub/2025")
      parent = lists.create("arthur", body(%({"name": "Urlaub", "favorite": true})))
      parent.parent.should be_nil
      deep = lists.create("arthur", body(%({"name": "Urlaub/2026/Juli"})))
      lists.create("arthur", body(%({"name": "Urlaubsziele"})))
      lists.add(parent.id, "arthur", [1_i64])
      lists.add(sub.id, "arthur", [1_i64, 2_i64])
      lists.add(deep.id, "arthur", [3_i64])
      json = JSON.parse(lists.all("arthur").to_json).as_a.to_h { |l| {l["name"].as_s, l} }
      json["Urlaub"]["count"].should eq(1)
      json["Urlaub"]["totalCount"].should eq(3)
      json["Urlaub/2026"]["totalCount"].should eq(3)
      json["Urlaub/2026"]["parent"].should eq("Urlaub")
      json["Urlaubsziele"]["totalCount"].should eq(0)
      lists[parent.id, "arthur"].total_count.should eq(3)

      expect_raises(CalibreHub::Edit::Invalid, "below itself") { lists.update(parent.id, "arthur", body(%({"name": "Urlaub/alt"}))) }
      expect_raises(CalibreHub::Lists::Taken) { lists.update(parent.id, "arthur", body(%({"name": "Urlaubsziele"}))) }
      before = events(db).size
      lists.update(parent.id, "arthur", body(%({"name": "Reisen/Sommer"}))).name.should eq("Reisen/Sommer")
      lists.all("arthur").map(&.name).sort.should eq(["Reisen/Sommer", "Reisen/Sommer/2025", "Reisen/Sommer/2026",
                                                       "Reisen/Sommer/2026/Juli", "Urlaubsziele"])
      e = events(db)[before..]
      e.map { |x| {x["previous"]["name"].as_s, x["list"]["name"].as_s} }.sort.should eq([
        {"Urlaub", "Reisen/Sommer"}, {"Urlaub/2025", "Reisen/Sommer/2025"},
        {"Urlaub/2026", "Reisen/Sommer/2026"}, {"Urlaub/2026/Juli", "Reisen/Sommer/2026/Juli"},
      ])
      # a sublist moves alone; the target's levels keep their spelling
      lists.update(deep.id, "arthur", body(%({"name": "reisen/Juli"}))).name.should eq("Reisen/Juli")
      lists[sub.id, "arthur"].total_count.should eq(2)

      # deleting a parent leaves the sublists, the node stays without a list
      lists.delete(parent.id, "arthur")
      lists.all("arthur").map(&.name).sort.should eq(["Reisen/Juli", "Reisen/Sommer/2025", "Reisen/Sommer/2026", "Urlaubsziele"])
      lists.node("arthur", "reisen/sommer", "arthur").map(&.name).should eq(["Reisen/Sommer/2025", "Reisen/Sommer/2026"])
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

# A calibre search stand-in for magic shelves: tags:"=Krimi" finds 5, 4, 3
# (newest first), languages:"=deu" finds 4 and 9, "kaputt" is rejected with a 500 like calibre-server does
private def fake_search(searched = [] of String) : CalibreHub::Lists::Search
  ->(q : String, limit : Int32) do
    searched << q
    raise CalibreHub::Calibre::Unavailable.new("calibre-server /ajax/search: HTTP 500") if q.includes?("kaputt")
    ids = [] of Int64
    ids.concat([5_i64, 4_i64, 3_i64]) if q.includes?(%(tags:"=Krimi"))
    ids.concat([4_i64, 9_i64]) if q.includes?(%(languages:"=deu"))
    ids = ids.uniq
    {ids.size.to_i64, ids.first(limit)}
  end
end

private def with_shelves(searched = [] of String, &)
  path = File.tempname("hub-shelves", ".sqlite")
  db = DB.open("sqlite3://#{path}?max_pool_size=1")
  yield CalibreHub::Lists.new(db, nil, nil, fake_search(searched), "kategorie"), db
ensure
  db.try &.close
  File.delete?(path) if path
end

describe CalibreHub::Shelf do
  it "checks a rule and turns it into one calibre search" do
    rule = CalibreHub::Shelf.parse(JSON.parse(%({"match": "any", "conditions": [
      {"field": "tag", "value": " Krimi "},
      {"field": "kategorie", "value": "Roman / Krimi"},
      {"field": "author", "value": "Agatha \\"Christie\\""},
      {"field": "language", "value": "deu", "not": true},
      {"field": "text", "value": "rating:>3", "not": false}]})), "kategorie")
    rule["conditions"][0]["value"].should eq("Krimi")
    rule["conditions"][1]["value"].should eq("Roman.Krimi")
    rule["conditions"][4]["not"]?.should be_nil
    CalibreHub::Shelf.query(rule, "kategorie").should eq(
      %((tags:"=Krimi") or (#kategorie:"=.Roman.Krimi") or (authors:"=Agatha \\"Christie\\"") or (not (languages:"=deu")) or ((rating:>3))))
    one = CalibreHub::Shelf.parse(JSON.parse(%({"conditions": [{"field": "series", "value": "Dune"}]})), nil)
    one["match"].should eq("all")
    CalibreHub::Shelf.query(one, nil).should eq(%(series:"=Dune"))

    bad = ->(json : String) { CalibreHub::Shelf.parse(JSON.parse(json), nil) }
    expect_raises(CalibreHub::Edit::Invalid, "at least one condition") { bad.call(%({"conditions": []})) }
    expect_raises(CalibreHub::Edit::Invalid, "match") { bad.call(%({"match": "some", "conditions": [{"field": "tag", "value": "a"}]})) }
    expect_raises(CalibreHub::Edit::Invalid, "field: one of") { bad.call(%({"conditions": [{"field": "rating", "value": "3"}]})) }
    expect_raises(CalibreHub::Edit::Invalid, "value expected") { bad.call(%({"conditions": [{"field": "tag", "value": " "}]})) }
    expect_raises(CalibreHub::Edit::Invalid, "no category column") { bad.call(%({"conditions": [{"field": "kategorie", "value": "A"}]})) }
    expect_raises(CalibreHub::Edit::Invalid, "unknown field") { bad.call(%({"conditions": [{"field": "tag", "value": "a", "op": "x"}]})) }
    expect_raises(CalibreHub::Edit::Invalid) { bad.call(%(["tag"])) }
  end
end

describe "magic shelves" do
  it "finds their books by the rule, counted live, and keeps them read-only" do
    searched = [] of String
    with_shelves(searched) do |lists, db|
      krimi = %({"conditions": [{"field": "tag", "value": "Krimi"}]})
      s = lists.create("arthur", body(%({"name": "Krimis", "favorite": true, "rule": #{krimi}})))
      s.rule.not_nil!["match"].should eq("all")
      s.query.should eq(%(tags:"=Krimi"))
      s.count.should eq(3)
      s.cover_book_ids.should eq([5_i64, 4_i64, 3_i64])
      s.favorite.should be_true
      json = JSON.parse(s.to_json)
      json["rule"]["conditions"][0]["field"].should eq("tag")
      json["query"].should eq(%(tags:"=Krimi"))
      json["queryError"].raw.should be_nil

      # a plain list has none of it
      plain = lists.create("arthur", body(%({"name": "Leseliste", "rule": null})))
      plain.rule.should be_nil
      JSON.parse(plain.to_json)["rule"].raw.should be_nil

      expect_raises(CalibreHub::Edit::Invalid, "no books of its own") { lists.add(s.id, "arthur", [1_i64]) }
      expect_raises(CalibreHub::Edit::Invalid, "no books of its own") { lists.remove(s.id, "arthur", [5_i64]) }
      expect_raises(CalibreHub::Edit::Invalid, "default list") { lists.update(s.id, "arthur", body(%({"isDefault": true}))) }
      expect_raises(CalibreHub::Edit::Invalid, "synced") { lists.create("arthur", body(%({"name": "X", "sync": true, "rule": #{krimi}}))) }
      expect_raises(CalibreHub::Edit::Invalid, "only a magic shelf") { lists.update(plain.id, "arthur", body(%({"rule": #{krimi}}))) }
      expect_raises(CalibreHub::Edit::Invalid, "needs a rule") { lists.update(s.id, "arthur", body(%({"rule": null}))) }
      # calibre has to understand the search
      expect_raises(CalibreHub::Edit::Invalid, "calibre can't search this") do
        lists.create("arthur", body(%({"name": "Y", "rule": {"conditions": [{"field": "text", "value": "kaputt"}]}})))
      end
      lists.all("arthur").map(&.name).should eq(["Krimis", "Leseliste"])

      # OR over two conditions; the count follows the library
      either = %({"match": "any", "conditions": [{"field": "tag", "value": "Krimi"}, {"field": "language", "value": "deu"}]})
      u = lists.update(s.id, "arthur", body(%({"rule": #{either}, "name": "Krimis oder Deutsch"})))
      u.query.should eq(%((tags:"=Krimi") or (languages:"=deu")))
      u.count.should eq(4)
      lists.members([u]).should eq([5_i64, 4_i64, 3_i64, 9_i64])
      events(db).map(&.["action"].as_s).should eq(%w(created created updated))

      # a broken stored search shows as an error, not a failed list
      db.exec "update lists set rule = ? where id = ?", %({"match":"all","conditions":[{"field":"text","value":"kaputt"}]}), s.id
      broken = lists[s.id, "arthur"]
      broken.count.should eq(0)
      broken.query_error.not_nil!.should contain("HTTP 500")
      lists.members([broken]).should be_empty
    end
  end

  it "doesn't take an outage of calibre-server for a broken rule" do
    path = File.tempname("hub-shelves", ".sqlite")
    db = DB.open("sqlite3://#{path}?max_pool_size=1")
    down = ->(_q : String, _limit : Int32) { raise CalibreHub::Calibre::Unavailable.new("calibre-server: connection refused"); {0_i64, [] of Int64} }
    lists = CalibreHub::Lists.new(db, nil, nil, down, nil)
    expect_raises(CalibreHub::Calibre::Unavailable) do
      lists.create("arthur", body(%({"name": "X", "rule": {"conditions": [{"field": "tag", "value": "a"}]}})))
    end
  ensure
    db.try &.close
    File.delete?(path) if path
  end

  it "nests shelves below lists and counts them into the node" do
    with_shelves do |lists, db|
      urlaub = lists.create("arthur", body(%({"name": "Urlaub"})))
      lists.add(urlaub.id, "arthur", [1_i64, 4_i64])
      lists.create("arthur", body(%({"name": "Urlaub/Krimis", "rule": {"conditions": [{"field": "tag", "value": "Krimi"}]}})))
      lists[urlaub.id, "arthur"].total_count.should eq(4)
      calibre = CalibreHub::Calibre.new("http://127.0.0.1:1", "x", "x")
      page = ->(q : String) { CalibreHub::Api.list_page(lists, calibre, "arthur", HTTP::Params.parse(q), nil, 0, 10) }
      # the list's own books first, then the shelf's not among them
      page.call("list=#{urlaub.id}").should eq({4, [4_i64, 1_i64, 5_i64, 3_i64]})
      page.call("list=#{urlaub.id}&direct=1").should eq({2, [4_i64, 1_i64]})
      page.call("listPath=Urlaub/Krimis").should eq({3, [5_i64, 4_i64, 3_i64]})
    end
  end

  it "keeps shelves out of the reader folders" do
    with_shelves do |lists, db|
      lists.migrate("arthur", "leseliste", [] of Int64)
      parent = lists.create("arthur", body(%({"name": "Urlaub", "sync": true})))
      lists.create("arthur", body(%({"name": "Urlaub/Krimis", "rule": {"conditions": [{"field": "tag", "value": "Krimi"}]}})))
      CalibreHub::Leseliste.synced_lists(db).not_nil!.map(&.name).should eq(["Leseliste", "Urlaub"])
      parent.sync.should be_true
    end
  end

  it "serves shelves through the list API" do
    with_shelves do |lists|
      auth = CalibreHub::Auth.new("arthur", "pw", Bytes.new(32))
      # the routes of the other list spec use another store
      reset_routes
      CalibreHub.list_routes(lists, auth, nil)
      status, l = call("POST", "/api/lists", %({"name": "Krimis", "rule": {"conditions": [{"field": "tag", "value": "Krimi"}]}}))
      status.should eq(201)
      id = l.not_nil!["id"].as_i64
      l.not_nil!["count"].should eq(3)
      call("POST", "/api/lists", %({"name": "Leer", "rule": {"conditions": []}}))[0].should eq(400)
      call("POST", "/api/lists/#{id}/books", %({"bookIds": [1]}))[0].should eq(400)
      call("PUT", "/api/lists/#{id}/books/1")[0].should eq(400)
      status, l = call("PATCH", "/api/lists/#{id}", %({"rule": {"conditions": [{"field": "language", "value": "deu"}]}}))
      status.should eq(200)
      l.not_nil!["count"].should eq(2)
      call("GET", "/api/lists")[1].not_nil!.as_a.first["query"].should eq(%(languages:"=deu"))
    end
  end
end

# list_routes on a fresh router (each spec has its own store)
private def reset_routes
  Kemal::RouteHandler::INSTANCE.routes = Radix::Tree(Kemal::Route).new
  Kemal::RouteHandler::INSTANCE.cached_routes = Kemal::LRUCache(String, Radix::Result(Kemal::Route)).new(Kemal.config.max_route_cache_size)
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
      reset_routes
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
      page = ->(q : String) { CalibreHub::Api.list_page(lists, calibre, "arthur", HTTP::Params.parse("list=#{l.id}&#{q}"), nil, 0, 2) }
      page.call("").should eq({3, [3_i64, 2_i64]})
      page.call("order=asc").should eq({3, [1_i64, 2_i64]})
      expect_raises(CalibreHub::Edit::Invalid) { page.call("sort=rating") }
      expect_raises(CalibreHub::Lists::NotFound) { CalibreHub::Api.list_page(lists, calibre, "tilli", HTTP::Params.parse("list=#{l.id}"), nil, 0, 2) }
    end
  end

  it "pages a node with its sublists, the direct books, and a node without a list" do
    with_lists do |lists|
      urlaub = lists.create("arthur", body(%({"name": "Urlaub"})))
      y2026 = lists.create("arthur", body(%({"name": "Urlaub/2026"})))
      meer = lists.create("arthur", body(%({"name": "Reise/Meer"})))
      lists.create("tilli", body(%({"name": "Reise/Berge", "visibility": "readable"})))
      lists.add(urlaub.id, "arthur", [1_i64])
      sleep 2.milliseconds
      lists.add(y2026.id, "arthur", [1_i64, 2_i64])
      lists.add(meer.id, "arthur", [5_i64])
      calibre = CalibreHub::Calibre.new("http://127.0.0.1:1", "x", "x")
      page = ->(q : String) { CalibreHub::Api.list_page(lists, calibre, "arthur", HTTP::Params.parse(q), nil, 0, 10) }
      # book 1 is in both, once, by its newest addition
      page.call("list=#{urlaub.id}").should eq({2, [2_i64, 1_i64]})
      page.call("list=#{urlaub.id}&direct=1").should eq({1, [1_i64]})
      page.call("list=#{y2026.id}").should eq({2, [2_i64, 1_i64]})
      page.call("listPath=urlaub").should eq({2, [2_i64, 1_i64]})
      # Reise has no list of its own
      page.call("listPath=Reise").should eq({1, [5_i64]})
      page.call("listPath=Reise&direct=1").should eq({0, [] of Int64})
      page.call("listPath=Reise&listOwner=tilli").should eq({0, [] of Int64})
      expect_raises(CalibreHub::Lists::NotFound) { page.call("listPath=Nirgends") }
      expect_raises(CalibreHub::Lists::NotFound) { page.call("listPath=Reise&listOwner=niemand") }
      expect_raises(CalibreHub::Lists::NotFound) { page.call("listPath=Urlaub/2026/x") }
    end
  end
end

describe CalibreHub::Opds do
  it "builds a navigation feed and an acquisition feed per list" do
    with_lists do |lists|
      l = lists.create("arthur", body(%({"name": "Urlaub & Meer", "description": "Strand"})))
      lists.add(l.id, "arthur", [1_i64])
      l = lists[l.id, "arthur"]
      nav = XML.parse(CalibreHub::Opds.lists_feed([l]))
      ns = {"a" => "http://www.w3.org/2005/Atom"}
      nav.xpath_node("//a:entry/a:title", ns).not_nil!.content.should eq("Urlaub & Meer")
      nav.xpath_node("//a:entry/a:link", ns).not_nil!["href"].should eq("/opds/lists/#{l.id}")

      b = CalibreHub::Jobs.blank
      book = CalibreHub::Book.new(id: 7_i64, title: "Dune", authors: ["Frank Herbert"], author_sort: nil, tags: [] of String,
        series: "Dune", series_index: 1.0, formats: ["PDF", "EPUB"], last_modified: Time.utc(2026, 11, 2),
        timestamp: nil, pubdate: nil, rating: nil, publisher: "Ace", identifiers: {} of String => String,
        languages: ["eng"], comments: "<p>Spice &amp; sand</p>", custom: b.custom)
      feed = XML.parse(CalibreHub::Opds.list_feed(l, [book], 0, 150, "/library"))
      feed.xpath_node("/a:feed/a:title", ns).not_nil!.content.should eq("Urlaub & Meer")
      feed.xpath_node("/a:feed/a:link[@rel='next']", ns).not_nil!["href"].should eq("/opds/lists/#{l.id}?offset=1")
      acq = feed.xpath_nodes("//a:entry/a:link[@rel='http://opds-spec.org/acquisition']", ns)
      acq.map(&.["href"]).should eq(["/get/epub/7/library", "/get/pdf/7/library"])
      acq.first["type"].should eq("application/epub+zip")
      feed.xpath_node("//a:entry/a:summary", ns).not_nil!.content.should eq("Spice & sand")
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

  it "nests the folders of sublists and takes them along with a synced parent" do
    with_library do |library|
      with_lists do |lists, db, state|
        target = File.tempname("leseliste-target")
        begin
          env = {"LESELISTE_TARGET" => target, "CALIBRE_HUB_LIBRARY" => library, "CALIBRE_HUB_STATE_DB" => state}
          last = -> { db.query_one("select payload from events order by id desc limit 1", as: String) }
          run = ->(event : String) { CalibreHub::Leseliste.run(env, IO::Memory.new(event)).should eq(0) }
          lists.migrate("arthur", "leseliste", [] of Int64)
          sub = lists.create("arthur", body(%({"name": "Urlaub/2026"})))
          lists.add(sub.id, "arthur", [2_i64])
          # not synced yet: an add to it doesn't concern the reader
          CalibreHub::Leseliste.relevant?(JSON.parse(last.call), Set(Int64).new).should be_false

          parent = lists.create("arthur", body(%({"name": "Urlaub", "sync": true})))
          lists.add(parent.id, "arthur", [1_i64])
          run.call("")
          files(target).should eq([
            "Urlaub/2026/Lovelace, Ada - Dune 02 - Zweites.epub",
            "Urlaub/Lovelace, Ada - Erstes.epub",
          ])

          # the sublist isn't synced itself, its parent is
          lists.remove(sub.id, "arthur", [2_i64])
          synced = CalibreHub::Leseliste.synced_lists(db).not_nil!
          synced.map { |l| {l.name, l.own} }.should eq([{"Leseliste", true}, {"Urlaub/2026", false}, {"Urlaub", true}])
          CalibreHub::Leseliste.relevant?(JSON.parse(last.call), Set{1_i64}, synced).should be_true
          run.call(last.call)
          files(target).should eq(["Urlaub/Lovelace, Ada - Erstes.epub"])
          lists.add(sub.id, "arthur", [2_i64])
          run.call(last.call)

          # renaming the parent moves the folder with the sublist's inside
          File.write(File.join(target, "Urlaub", "2026", "notiz.txt"), "bleibt bis zum Abgleich")
          lists.update(parent.id, "arthur", body(%({"name": "Reisen/Sommer"})))
          payloads = [] of String
          db.query_each("select payload from events order by id desc limit 2") { |rs| payloads << rs.read(String) }
          CalibreHub::Leseliste.rename(JSON.parse(payloads[1]), target, CalibreHub::Leseliste.synced_lists(db).not_nil!)
          File.exists?(File.join(target, "Reisen", "Sommer", "2026", "notiz.txt")).should be_true
          payloads.reverse_each { |p| run.call(p) }
          files(target).should eq([
            "Reisen/Sommer/2026/Lovelace, Ada - Dune 02 - Zweites.epub",
            "Reisen/Sommer/Lovelace, Ada - Erstes.epub",
          ])

          # a sublist moved out of the synced parent leaves the reader
          lists.update(sub.id, "arthur", body(%({"name": "Archiv"})))
          event = JSON.parse(last.call)
          CalibreHub::Leseliste.relevant?(event, Set(Int64).new, CalibreHub::Leseliste.synced_lists(db).not_nil!).should be_true
          run.call(last.call)
          files(target).should eq(["Reisen/Sommer/Lovelace, Ada - Erstes.epub"])

          # without the synced parent its sublist stays, not synced
          lists.update(sub.id, "arthur", body(%({"name": "Reisen/Sommer/2026"})))
          run.call(last.call)
          lists.delete(parent.id, "arthur")
          run.call(last.call)
          files(target).should be_empty
          lists.all("arthur").map(&.name).should contain("Reisen/Sommer/2026")
        ensure
          FileUtils.rm_rf(target)
        end
      end
    end
  end

  it "cleans each level of a folder path" do
    CalibreHub::Leseliste.folder("Urlaub: Meer/2026?").should eq("Urlaub_ Meer/2026_")
    CalibreHub::Leseliste.folder("/").should eq("_")
  end
end
