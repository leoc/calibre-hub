require "spec"
require "file_utils"
require "../src/calibre_hub/library_db"

private def with_library(&)
  path = File.tempname("hub-lib", ".db")
  db = DB.open("sqlite3://#{path}")
  db.exec "create table books (id integer primary key, title text, last_modified text)"
  db.exec "create table tags (id integer primary key, name text)"
  db.exec "create table books_tags_link (id integer primary key, book integer, tag integer)"
  db.exec "create table comments (id integer primary key, book integer, text text)"
  db.exec "create table last_read_positions (id integer primary key, book integer, cfi text)"
  db.exec "insert into books (id, title) values (1, 'A'), (2, 'B')"
  db.exec "insert into tags (id, name) values (1, 'leseliste')"
  db.exec "insert into books_tags_link (book, tag) values (1, 1), (2, 1)"
  db.close
  yield path
ensure
  File.delete(path) if path && File.exists?(path)
end

private def changes(path)
  db = CalibreHub::LibraryDB.open_read_only(path)
  rows = CalibreHub::LibraryDB.changes_since(db, 0).not_nil!.map(&.book)
  db.close
  rows
end

describe CalibreHub::LibraryDB do
  it "logs changes to books, link tables and renamed values" do
    with_library do |path|
      CalibreHub::LibraryDB.install_triggers(path)
      db = DB.open("sqlite3://#{path}")
      db.exec "update books set title = 'A2' where id = 1"
      db.exec "insert into comments (book, text) values (2, 'x')"
      db.exec "update tags set name = 'Leseliste' where id = 1"
      db.exec "insert into last_read_positions (book, cfi) values (1, 'y')"
      db.close
      # books(1), comments(2), rename -> both linked books; reading positions ignored
      changes(path).should eq([1, 2, 1, 2])
    end
  end

  it "is idempotent and detects missing triggers" do
    with_library do |path|
      db = CalibreHub::LibraryDB.open_read_only(path)
      CalibreHub::LibraryDB.triggers_installed?(db).should be_false
      db.close
      2.times { CalibreHub::LibraryDB.install_triggers(path) }
      db = CalibreHub::LibraryDB.open_read_only(path)
      CalibreHub::LibraryDB.triggers_installed?(db).should be_true
      db.close
    end
  end

  it "opens read-only" do
    with_library do |path|
      db = CalibreHub::LibraryDB.open_read_only(path)
      expect_raises(SQLite3::Exception) { db.exec "update books set title = 'x'" }
      db.close
    end
  end
end
