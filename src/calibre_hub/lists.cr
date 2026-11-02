require "db"
require "json"
require "./calibre"
require "./edit"

module CalibreHub
  # Reading lists, like playlists: named lists of books in the state DB
  # (calibre Desktop doesn't see them). Every list has an owner; others see
  # it only with visibility readable (read) or editable (read and change).
  # One list per owner can be the default list (the bookmark on the cover),
  # favorites are shown in the sidebar, synced lists are mirrored to the
  # reader by the leseliste handler (one folder per list).
  #
  # Every change is an event of type "list" in the event queue, so handlers
  # see it like book changes:
  #   {"type": "list", "action": "created|updated|deleted|added|removed",
  #    "bookId": 0, "listId": 3, "list": {...}, "previous": {...}?,
  #    "bookIds": [...], "at": ...}
  # previous: the list before an update (name, sync, ...).
  class Lists
    VISIBILITIES = %w(private readable editable)
    SORTS        = %w(listAdded title author series)
    MAX_NAME     = 120
    MAX_DESC     = 5000
    MAX_BOOKS    = 10_000
    # the tag the reading list was before lists existed
    MIGRATED_NAME = "Leseliste"

    class Forbidden < Exception
    end

    class Taken < Exception
    end

    class NotFound < Exception
    end

    @[JSON::Serializable::Options(emit_nulls: true)]
    struct List
      include JSON::Serializable

      getter id : Int64
      getter name : String
      getter description : String
      getter owner : String
      getter visibility : String
      getter sync : Bool
      getter favorite : Bool
      @[JSON::Field(key: "isDefault")]
      getter is_default : Bool
      getter count : Int64
      # the first books (most recently added), for the cover mosaic
      @[JSON::Field(key: "coverBookIds")]
      getter cover_book_ids : Array(Int64)
      @[JSON::Field(key: "createdAt")]
      getter created_at : Time
      @[JSON::Field(key: "updatedAt")]
      getter updated_at : Time
      # last time books were added, for "in the last used list"
      @[JSON::Field(key: "lastUsedAt")]
      getter last_used_at : Time?
      # may the asking user change it (owner or visibility editable)
      getter editable : Bool

      def initialize(@id, @name, @description, @owner, @visibility, @sync, @favorite, @is_default, @count,
                     @cover_book_ids, @created_at, @updated_at, @last_used_at, @editable)
      end
    end

    COLUMNS = "id, owner, name, description, visibility, sync, favorite, is_default, created_at, updated_at, last_used_at"
    COVERS  = 4

    # exists: which of these book ids are in the library (calibre-server);
    # nil skips the check
    alias Exists = Proc(Array(Int64), Array(Int64))

    def initialize(@db : DB::Database, @exists : Exists? = nil, @wake : Channel(Nil)? = nil)
      @mutex = Mutex.new
      @db.exec "create table if not exists meta (key text primary key, value text)"
      @db.exec <<-SQL
        create table if not exists lists (
          id integer primary key autoincrement,
          owner text not null,
          name text not null,
          description text not null default '',
          visibility text not null default 'private',
          sync integer not null default 0,
          favorite integer not null default 0,
          is_default integer not null default 0,
          created_at integer not null,
          updated_at integer not null,
          last_used_at integer
        )
        SQL
      @db.exec "create unique index if not exists lists_owner_name on lists (owner, name collate nocase)"
      # added_at in milliseconds; ties (bulk adds) keep the insert order
      @db.exec <<-SQL
        create table if not exists list_items (
          list_id integer not null,
          book_id integer not null,
          added_at integer not null,
          primary key (list_id, book_id)
        )
        SQL
      @db.exec "create index if not exists list_items_book on list_items (book_id)"
      # memberships of deleted books, given back when the book is restored
      @db.exec <<-SQL
        create table if not exists list_items_deleted (
          list_id integer not null,
          book_id integer not null,
          added_at integer not null,
          primary key (list_id, book_id)
        )
        SQL
      # the events table belongs to the detector; created here too so the
      # lists work on their own (specs, scan)
      @db.exec <<-SQL
        create table if not exists events (
          id integer primary key autoincrement,
          type text not null,
          book_id integer not null,
          payload text not null,
          created_at integer not null,
          done_at integer
        )
        SQL
    end

    # Lists the user may see: own lists first, favorites first, by name
    def all(user : String) : Array(List)
      rows = [] of List
      @db.query_each("select #{COLUMNS} from lists where owner = ? or visibility != 'private'
                      order by owner != ?, favorite desc, name collate nocase, id", user, user) do |rs|
        rows << read(rs, user)
      end
      rows.map { |l| with_counts(l) }
    end

    def [](id : Int64, user : String) : List
      visible(id, user)
    end

    def create(user : String, body : Hash(String, JSON::Any)) : List
      name = name!(body["name"]?) || raise Edit::Invalid.new("name", "name expected")
      now = Time.utc
      id = @mutex.synchronize do
        raise Taken.new("a list named #{name} exists") if taken?(user, name, nil)
        @db.transaction do |tx|
          c = tx.connection
          c.exec "insert into lists (owner, name, description, visibility, sync, favorite, is_default, created_at, updated_at)
                  values (?, ?, '', 'private', 0, 0, 0, ?, ?)", user, name, now.to_unix, now.to_unix
          new_id = c.scalar("select last_insert_rowid()").as(Int64)
          apply(c, new_id, user, body.reject("name"))
          new_id
        end.not_nil!
      end
      list = visible(id, user)
      emit("created", list)
      list
    end

    def update(id : Int64, user : String, body : Hash(String, JSON::Any)) : List
      before = editable(id, user)
      @mutex.synchronize do
        if n = name!(body["name"]?)
          raise Taken.new("a list named #{n} exists") if taken?(before.owner, n, id)
        end
        @db.transaction do |tx|
          c = tx.connection
          c.exec "update lists set name = ? where id = ?", name!(body["name"]?), id if body["name"]?
          apply(c, id, before.owner, body.reject("name"))
          c.exec "update lists set updated_at = ? where id = ?", Time.utc.to_unix, id
        end
      end
      list = visible(id, user)
      emit("updated", list, previous: before)
      list
    end

    # Only the owner deletes a list
    def delete(id : Int64, user : String) : List
      list = visible(id, user)
      raise Forbidden.new("only the owner deletes a list") unless list.owner == user
      ids = book_ids(id)
      @db.transaction do |tx|
        tx.connection.exec "delete from list_items where list_id = ?", id
        tx.connection.exec "delete from list_items_deleted where list_id = ?", id
        tx.connection.exec "delete from lists where id = ?", id
      end
      emit("deleted", list, book_ids: ids)
      list
    end

    # Adds books (unknown ids are left out); returns the list and the ids
    # added (those already in the list aren't added again)
    def add(id : Int64, user : String, ids : Array(Int64)) : {List, Array(Int64)}
      editable(id, user)
      ids = ids.uniq
      raise Edit::Invalid.new("bookIds", "at most #{MAX_BOOKS} books at once") if ids.size > MAX_BOOKS
      known = @exists.try { |e| e.call(ids).to_set }
      ids = ids.select { |b| known.nil? || known.includes?(b) }
      added = [] of Int64
      now = Time.utc
      @db.transaction do |tx|
        c = tx.connection
        ids.each do |b|
          c.exec "insert or ignore into list_items (list_id, book_id, added_at) values (?, ?, ?)", id, b, now.to_unix_ms
          added << b if c.scalar("select changes()").as(Int64) > 0
        end
        c.exec "update lists set last_used_at = ? where id = ?", now.to_unix, id
      end
      list = visible(id, user)
      emit("added", list, book_ids: added) unless added.empty?
      {list, added}
    end

    def remove(id : Int64, user : String, ids : Array(Int64)) : {List, Array(Int64)}
      editable(id, user)
      removed = [] of Int64
      @db.transaction do |tx|
        c = tx.connection
        ids.uniq.each do |b|
          c.exec "delete from list_items where list_id = ? and book_id = ?", id, b
          removed << b if c.scalar("select changes()").as(Int64) > 0
        end
      end
      list = visible(id, user)
      emit("removed", list, book_ids: removed) unless removed.empty?
      {list, removed}
    end

    # Book ids of a list, most recently added first
    def book_ids(id : Int64) : Array(Int64)
      ids = [] of Int64
      @db.query_each("select book_id from list_items where list_id = ? order by added_at desc, rowid desc", id) do |rs|
        ids << rs.read(Int64)
      end
      ids
    end

    # The lists (visible to the user) each book is in
    def memberships(book_ids : Array(Int64), user : String) : Hash(Int64, Array(Int64))
      result = {} of Int64 => Array(Int64)
      book_ids.each { |b| result[b] = [] of Int64 }
      return result if book_ids.empty?
      book_ids.each_slice(500) do |slice|
        @db.query_each("select i.book_id, i.list_id from list_items i join lists l on l.id = i.list_id
                        where i.book_id in (#{slice.join(",")}) and (l.owner = ? or l.visibility != 'private')
                        order by i.list_id", user) do |rs|
          b, l = rs.read(Int64, Int64)
          result[b] << l
        end
      end
      result
    end

    def lists_of(book_id : Int64, user : String) : Array(List)
      ids = memberships([book_id], user)[book_id].to_set
      all(user).select { |l| ids.includes?(l.id) }
    end

    # A book was deleted: it leaves its lists (remembered for a restore)
    def book_deleted(book_id : Int64)
      lists = [] of Int64
      @db.query_each("select list_id from list_items where book_id = ?", book_id) { |rs| lists << rs.read(Int64) }
      return if lists.empty?
      @db.transaction do |tx|
        c = tx.connection
        c.exec "insert or replace into list_items_deleted (list_id, book_id, added_at)
                select list_id, book_id, added_at from list_items where book_id = ?", book_id
        c.exec "delete from list_items where book_id = ?", book_id
      end
      lists.each do |id|
        find(id).try { |l| emit("removed", l, book_ids: [book_id]) }
      end
    end

    # A deleted book came back from the trash with a new id: back into the
    # lists it was in
    def book_restored(old_id : Int64, new_id : Int64)
      # its deleted event may not have been followed yet
      book_deleted(old_id)
      rows = [] of {Int64, Int64}
      @db.query_each("select list_id, added_at from list_items_deleted where book_id = ?", old_id) do |rs|
        rows << rs.read(Int64, Int64)
      end
      return if rows.empty?
      @db.transaction do |tx|
        c = tx.connection
        rows.each do |list_id, added_at|
          c.exec "insert or ignore into list_items (list_id, book_id, added_at) values (?, ?, ?)", list_id, new_id, added_at
        end
        c.exec "delete from list_items_deleted where book_id = ?", old_id
      end
      rows.each do |list_id, _|
        find(list_id).try { |l| emit("added", l, book_ids: [new_id]) }
      end
    end

    def migrated? : Bool
      !@db.query_one?("select value from meta where key = 'lists_migrated'", as: String).nil?
    end

    # Once: the books with the reading list tag become the list "Leseliste",
    # synced to the reader, the owner's default list and a favorite. The tag
    # stays on the books; the list is the source of truth from now on.
    # tagged: the book ids with the tag, oldest first.
    def migrate(owner : String, tag : String, tagged : Array(Int64)) : List?
      return nil if migrated?
      now = Time.utc
      id = @db.transaction do |tx|
        c = tx.connection
        lid = c.query_one?("select id from lists where owner = ? and name = ? collate nocase", owner, MIGRATED_NAME, as: Int64)
        unless lid
          c.exec "insert into lists (owner, name, description, visibility, sync, favorite, is_default, created_at, updated_at)
                  values (?, ?, '', 'private', 1, 1, 0, ?, ?)", owner, MIGRATED_NAME, now.to_unix, now.to_unix
          lid = c.scalar("select last_insert_rowid()").as(Int64)
        end
        if c.query_one("select count(*) from lists where owner = ? and is_default = 1", owner, as: Int64) == 0
          c.exec "update lists set is_default = 1 where id = ?", lid
        end
        # oldest first, so the newest books come first in "recently added"
        tagged.each do |b|
          c.exec "insert or ignore into list_items (list_id, book_id, added_at) values (?, ?, ?)", lid, b, now.to_unix_ms
        end
        c.exec "insert or replace into meta (key, value) values ('lists_migrated', ?)", tag
        lid
      end.not_nil!
      list = find(id).not_nil!
      emit("created", list, book_ids: book_ids(id))
      puts "lists: tag #{tag} migrated to the list #{MIGRATED_NAME} (#{list.count} books)"
      list
    end

    # Follows the event queue (cursor lists_event_seq): deleted books leave
    # their lists
    def watch_events(interval = 5.seconds)
      if @db.query_one?("select value from meta where key = 'lists_event_seq'", as: String).nil?
        max = @db.query_one("select coalesce(max(id), 0) from events", as: Int64)
        @db.exec "insert or replace into meta (key, value) values ('lists_event_seq', ?)", max.to_s
      end
      spawn do
        loop do
          begin
            follow_events
          rescue ex
            STDERR.puts "lists: events: #{ex.message}"
          end
          sleep interval
        end
      end
    end

    def follow_events
      cursor = @db.query_one("select value from meta where key = 'lists_event_seq'", as: String).to_i64
      rows = [] of {Int64, String, Int64}
      @db.query_each("select id, type, book_id from events where id > ? order by id limit 500", cursor) do |rs|
        rows << rs.read(Int64, String, Int64)
      end
      return if rows.empty?
      rows.each { |_, type, book_id| book_deleted(book_id) if type == "deleted" }
      @db.exec "update meta set value = ? where key = 'lists_event_seq'", rows.last[0].to_s
    end

    private def visible(id : Int64, user : String) : List
      list = find(id, user) || raise NotFound.new
      raise NotFound.new unless list.owner == user || list.visibility != "private"
      list
    end

    private def editable(id : Int64, user : String) : List
      list = visible(id, user)
      raise Forbidden.new("list is read-only") unless list.editable
      list
    end

    private def find(id : Int64, user : String? = nil) : List?
      @db.query_one?("select #{COLUMNS} from lists where id = ?", id) do |rs|
        read(rs, user)
      end.try { |l| with_counts(l) }
    end

    private def taken?(owner : String, name : String, except : Int64?) : Bool
      !@db.query_one?("select id from lists where owner = ? and name = ? collate nocase and id != ?",
        owner, name, except || 0_i64, as: Int64).nil?
    end

    private def name!(value : JSON::Any?) : String?
      return nil unless value
      name = (value.as_s? || raise Edit::Invalid.new("name", "string expected")).strip
      raise Edit::Invalid.new("name", "name expected") if name.empty?
      raise Edit::Invalid.new("name", "at most #{MAX_NAME} characters") if name.size > MAX_NAME
      raise Edit::Invalid.new("name", "no control characters") if name.matches?(/[\x00-\x1f]/)
      name
    end

    # description, visibility, sync, favorite, isDefault
    private def apply(c, id : Int64, owner : String, body : Hash(String, JSON::Any))
      body.each do |key, value|
        case key
        when "description"
          d = value.as_s? || (value.raw.nil? ? "" : raise Edit::Invalid.new(key, "string expected"))
          raise Edit::Invalid.new(key, "at most #{MAX_DESC} characters") if d.size > MAX_DESC
          c.exec "update lists set description = ? where id = ?", d.strip, id
        when "visibility"
          v = value.as_s?
          raise Edit::Invalid.new(key, "one of #{VISIBILITIES.join(", ")}") unless v && VISIBILITIES.includes?(v)
          c.exec "update lists set visibility = ? where id = ?", v, id
        when "sync", "favorite"
          b = value.as_bool?
          raise Edit::Invalid.new(key, "true or false expected") if b.nil?
          c.exec "update lists set #{key} = ? where id = ?", b ? 1 : 0, id
        when "isDefault"
          b = value.as_bool?
          raise Edit::Invalid.new(key, "true or false expected") if b.nil?
          # one default list per owner
          c.exec "update lists set is_default = 0 where owner = ?", owner if b
          c.exec "update lists set is_default = ? where id = ?", b ? 1 : 0, id
        else
          raise Edit::Invalid.new(key, "unknown field")
        end
      end
    end

    private def read(rs, user : String?) : List
      id, owner, name, desc, vis, sync, fav, default, created, updated, used =
        rs.read(Int64, String, String, String, String, Int64, Int64, Int64, Int64, Int64, Int64?)
      List.new(id, name, desc, owner, vis, sync == 1, fav == 1, default == 1, 0_i64, [] of Int64,
        Time.unix(created), Time.unix(updated), used.try { |u| Time.unix(u) },
        user.nil? || owner == user || vis == "editable")
    end

    private def with_counts(l : List) : List
      count = @db.query_one("select count(*) from list_items where list_id = ?", l.id, as: Int64)
      covers = [] of Int64
      @db.query_each("select book_id from list_items where list_id = ? order by added_at desc, rowid desc limit ?", l.id, COVERS) do |rs|
        covers << rs.read(Int64)
      end
      List.new(l.id, l.name, l.description, l.owner, l.visibility, l.sync, l.favorite, l.is_default, count,
        covers, l.created_at, l.updated_at, l.last_used_at, l.editable)
    end

    private def emit(action : String, list : List, book_ids = [] of Int64, previous : List? = nil)
      now = Time.utc
      payload = JSON.build do |j|
        j.object do
          j.field "type", "list"
          j.field "action", action
          j.field "bookId", 0
          j.field "listId", list.id
          j.field "list", list
          j.field "previous", previous if previous
          j.field "bookIds", book_ids
          j.field "at", now
        end
      end
      @db.exec "insert into events (type, book_id, payload, created_at) values ('list', 0, ?, ?)", payload, now.to_unix
      if w = @wake
        select
        when w.send(nil)
        else
        end
      end
    end
  end
end
