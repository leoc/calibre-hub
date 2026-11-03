require "db"
require "json"
require "digest/md5"
require "file_utils"
# api first: writer.cr and classify.cr need each other in this order
require "./api"
require "./dedup"
require "./library_db"

module CalibreHub
  # Duplicates in the library (rules in dedup.cr) and merging them. The
  # file sizes, paths and covers come from metadata.db (read-only), the
  # checksums from the files themselves, only for files whose format and
  # size another file has too.
  #
  # Merging keeps one book and moves into it, through calibre-server: the
  # empty fields and the identifiers and tags of the others (Dedup.fill),
  # the formats it lacks (a tiny one of its own is replaced; calibre moves
  # the replaced file to its trash), the cover when it has none; in the
  # state DB the reading list memberships and the reading progress. The
  # others then go to calibre's trash, never deleted. Every step is logged
  # (duplicate_merges), so a merge can be undone: the others come back from
  # the trash (with new ids, lists and progress included), the moved
  # formats go to calibre's trash again, filled fields are set back while
  # nobody changed them since.
  class Duplicates
    class Undone < Exception
    end

    struct FieldChange
      include JSON::Serializable
      getter field : String
      @[JSON::Field(emit_null: true)]
      getter old : JSON::Any
      @[JSON::Field(emit_null: true)]
      getter new : JSON::Any

      def initialize(@field, @old, @new)
      end
    end

    struct FormatMove
      include JSON::Serializable
      getter format : String
      # the book it came from
      getter from : Int64
      # replaced a tiny file of the same format
      getter replace : Bool

      def initialize(@format, @from, @replace)
      end
    end

    struct ListItem
      include JSON::Serializable
      @[JSON::Field(key: "listId")]
      getter list_id : Int64
      @[JSON::Field(key: "addedAt")]
      getter added_at : Int64

      def initialize(@list_id, @added_at)
      end
    end

    struct ProgressRow
      include JSON::Serializable
      getter user : String
      @[JSON::Field(key: "bookId")]
      getter book_id : Int64
      getter device : String
      @[JSON::Field(key: "deviceName")]
      getter device_name : String
      getter format : String
      getter position : String
      getter fraction : Float64
      getter source : String
      @[JSON::Field(key: "updatedAt")]
      getter updated_at : Int64

      def initialize(@user, @book_id, @device, @device_name, @format, @position, @fraction, @source, @updated_at)
      end

      def with_book(id : Int64) : ProgressRow
        ProgressRow.new(user, id, device, device_name, format, position, fraction, source, updated_at)
      end
    end

    # A row of another book; moved: it became the keeper's (newer than the
    # keeper's own for that device, which is kept in previous)
    struct ProgressMove
      include JSON::Serializable
      getter row : ProgressRow
      getter moved : Bool
      getter previous : ProgressRow?

      def initialize(@row, @moved, @previous)
      end
    end

    # A merge as logged; status: running, done, failed (partly done, can be
    # undone), undone
    class Merge
      include JSON::Serializable
      property id : Int64 = 0
      @[JSON::Field(key: "keepId")]
      getter keep_id : Int64
      @[JSON::Field(key: "otherIds")]
      getter other_ids : Array(Int64)
      property status : String = "running"
      getter at : Time
      @[JSON::Field(key: "undoneAt")]
      property undone_at : Time?
      property error : String?
      property fields = [] of FieldChange
      property formats = [] of FormatMove
      @[JSON::Field(key: "coverFrom")]
      property cover_from : Int64?
      @[JSON::Field(key: "listItems")]
      property list_items = [] of ListItem
      property progress = [] of ProgressMove
      property trashed = [] of Int64
      # old id -> new id of the books restored by the undo
      property restored = {} of String => Int64
      # what the undo could not set back
      property errors = [] of String

      def initialize(@keep_id, @other_ids, @at = Time.utc)
      end
    end

    # What a merge would do
    record Plan, keep : Book, others : Array(Book), fields : Hash(String, JSON::Any),
      formats : Array(FormatMove), cover_from : Int64?, lists : Int32, progress : Int32 do
      def to_json(json : JSON::Builder, category_column : String?)
        json.object do
          json.field "keepId", keep.id
          json.field "otherIds", others.map(&.id)
          json.field "fields" do
            json.array do
              fields.each_key do |f|
                next if f == "seriesIndex" && fields.has_key?("series")
                FieldChange.new(f, Dedup.value(keep, f, category_column), fields[f]).to_json(json)
              end
            end
          end
          json.field "formats", formats
          json.field "coverFrom", cover_from
          json.field "lists", lists
          json.field "progress", progress
          json.field "trash", others.map(&.id)
        end
      end
    end

    # from metadata.db: files per book, covers; nil without a library
    record LibraryInfo, files : Hash(Int64, Array(Dedup::FileInfo))?, covers : Hash(Int64, Bool)?

    MAX_OTHERS =  20
    KEEP_LOG   = 200

    getter threshold : Float64

    def initialize(@calibre : Calibre, @writer : Writer, @db : DB::Database, @library : String?,
                   @category_column : String? = nil, @lists : Lists? = nil, @trash : Trash? = nil,
                   @threshold : Float64 = Dedup::DEFAULT_THRESHOLD)
      @mutex = Mutex.new
      @sums = {} of {String, Int64, Int64} => String
      @db.exec <<-SQL
        create table if not exists duplicate_merges (
          id integer primary key autoincrement,
          keep_id integer not null,
          data text not null,
          at integer not null
        )
        SQL
      @db.exec <<-SQL
        create table if not exists duplicate_ignored (
          a integer not null,
          b integer not null,
          at integer not null,
          primary key (a, b)
        )
        SQL
      # the progress table belongs to Progress; created here too so merges
      # work without it (specs)
      Progress.new(@db)
    end

    def library_info : LibraryInfo
      root = @library || return LibraryInfo.new(nil, nil)
      path = File.join(root, "metadata.db")
      return LibraryInfo.new(nil, nil) unless File.exists?(path)
      files = {} of Int64 => Array(Dedup::FileInfo)
      covers = {} of Int64 => Bool
      ldb = LibraryDB.open_read_only(path)
      begin
        ldb.query_each("select b.id, b.path, b.has_cover, d.format, d.uncompressed_size, d.name
                        from books b left join data d on d.book = b.id") do |rs|
          id, dir, cover, format, size, name = rs.read(Int64, String, Int64?, String?, Int64?, String?)
          list = files[id] ||= [] of Dedup::FileInfo
          covers[id] = (cover || 0) != 0
          if format && size && name
            list << Dedup::FileInfo.new(format.upcase, size, File.join(root, dir, "#{name}.#{format.downcase}"))
          end
        end
      ensure
        ldb.close
      end
      LibraryInfo.new(files, covers)
    rescue ex : DB::Error | SQLite3::Exception
      STDERR.puts "duplicates: metadata.db: #{ex.message}"
      LibraryInfo.new(nil, nil)
    end

    # MD5 of a whole file, cached per path, size and modification time
    def checksum(f : Dedup::FileInfo) : String?
      path = f.path || return nil
      info = File.info?(path) || return nil
      key = {path, info.size, info.modification_time.to_unix}
      @sums[key] ||= begin
        d = Digest::MD5.new
        buf = Bytes.new(64 * 1024)
        File.open(path) do |io|
          while (n = io.read(buf)) > 0
            d.update(buf[0, n])
          end
        end
        d.hexfinal
      end
    rescue ex : File::Error | IO::Error
      STDERR.puts "duplicates: #{f.path}: #{ex.message}"
      nil
    end

    def ignored : Set({Int64, Int64})
      set = Set({Int64, Int64}).new
      @db.query_each("select a, b from duplicate_ignored") { |rs| set << rs.read(Int64, Int64) }
      set
    end

    # Marks every pair of the books as no duplicates (or not any more)
    def ignore(ids : Array(Int64), undo = false) : Int32
      ids = ids.uniq.sort
      raise Edit::Invalid.new("bookIds", "two books at least") if ids.size < 2
      n = 0
      @db.transaction do |tx|
        ids.each_combination(2) do |(a, b)|
          if undo
            tx.connection.exec "delete from duplicate_ignored where a = ? and b = ?", a, b
          else
            tx.connection.exec "insert or ignore into duplicate_ignored (a, b, at) values (?, ?, ?)", a, b, Time.utc.to_unix
          end
          n += tx.connection.scalar("select changes()").as(Int64).to_i
        end
      end
      n
    end

    record Group, ids : Array(Int64), reasons : Array(Dedup::Reason), keep_id : Int64, sure : Bool,
      score : Float64, items : Array(Dedup::Item), covers : Hash(Int64, Bool)

    # All groups, sure ones first, then by score
    def groups(threshold = @threshold) : Array(Group)
      info = library_info
      items = @calibre.list("").map { |b| item(b, info) }
      pairs = Dedup.pairs(items, threshold, ->checksum(Dedup::FileInfo), ignored)
      ids = Dedup.groups(pairs)
      return [] of Group if ids.empty?
      detailed = @calibre.books(ids.flatten, Calibre::DETAIL_FIELDS).index_by(&.id)
      covers = info.covers || ids.flatten.to_h { |id| {id, @calibre.has_cover?(id)} }
      ids.compact_map do |group|
        members = group.compact_map { |id| detailed[id]?.try { |b| item(b, info) } }
        next if members.size < 2
        reasons = pairs.select { |(a, b), _| group.includes?(a) && group.includes?(b) }.values.flatten
        sure = reasons.any? { |r| {"isbn", "file"}.includes?(r.kind) || (r.kind == "title" && r.detail == "1.0") }
        score = reasons.max_of { |r| {"isbn", "file"}.includes?(r.kind) ? 1.0 : (r.kind == "title" ? r.detail.try(&.to_f?) || 0.0 : 0.0) }
        Group.new(group, reasons, Dedup.keep(members, covers, @category_column), sure, score, members, covers)
      end.sort_by { |g| {g.sure ? 0 : 1, -g.score, g.ids.first} }
    end

    # The other books a book looks like a duplicate of (upload, inbox)
    def similar(id : Int64) : Array(Book)
      g = groups.find(&.ids.includes?(id)) || return [] of Book
      g.items.map(&.book).reject { |b| b.id == id }
    end

    def group_json(json : JSON::Builder, g : Group, user : String?)
      lists = user && @lists ? @lists.not_nil!.memberships(g.ids, user) : nil
      json.object do
        json.field "id", g.ids.join("-")
        json.field "bookIds", g.ids
        json.field "keepId", g.keep_id
        json.field "sure", g.sure
        json.field "score", g.score
        json.field "reasons", g.reasons
        json.field "books" do
          json.array do
            g.items.each do |i|
              b = i.book
              b.lists = lists.try(&.[b.id]?)
              json.object do
                json.field "book", b
                json.field "hasCover", g.covers[b.id]? || false
                json.field "broken", i.broken?
                json.field "files", i.files
              end
            end
          end
        end
      end
    end

    private def item(b : Book, info : LibraryInfo) : Dedup::Item
      Dedup::Item.new(b, info.files.try { |f| f[b.id]? || [] of Dedup::FileInfo })
    end

    # What merging others into keep would do
    def plan(keep_id : Int64, other_ids : Array(Int64)) : Plan
      other_ids = other_ids.uniq - [keep_id]
      raise Edit::Invalid.new("bookIds", "at least one other book") if other_ids.empty?
      raise Edit::Invalid.new("bookIds", "at most #{MAX_OTHERS} books") if other_ids.size > MAX_OTHERS
      books = @calibre.books([keep_id] + other_ids, Calibre::DETAIL_FIELDS).index_by(&.id)
      keep = books[keep_id]? || raise Writer::NotFound.new
      others = other_ids.map { |id| books[id]? || raise Writer::NotFound.new }
      info = library_info
      covers = info.covers || ([keep_id] + other_ids).to_h { |id| {id, @calibre.has_cover?(id)} }
      items = others.map { |b| item(b, info) }.sort_by { |i| Dedup.quality(i, covers[i.id]?, @category_column).map { |x| -x } + [i.id.to_i32] }
      keeper = item(keep, info)
      formats = [] of FormatMove
      items.each do |i|
        i.good_formats.each do |f|
          next if formats.any? { |m| m.format == f }
          has = keep.formats.includes?(f)
          formats << FormatMove.new(f, i.id, has) if !has || keeper.tiny_formats.includes?(f)
        end
      end
      cover_from = covers[keep_id]? ? nil : items.find { |i| covers[i.id]? }.try(&.id)
      lists = 0
      progress = 0
      other_ids.each do |o|
        if @lists
          lists += @db.query_one("select count(*) from list_items i where book_id = ? and not exists
                                  (select 1 from list_items k where k.list_id = i.list_id and k.book_id = ?)", o, keep_id, as: Int64).to_i
        end
        progress += @db.query_one("select count(*) from reading_progress where book_id = ?", o, as: Int64).to_i
      end
      Plan.new(keep, items.map(&.book), Dedup.fill(keep, items.map(&.book), @category_column), formats, cover_from, lists, progress)
    end

    def plan_json(p : Plan) : String
      JSON.build { |j| p.to_json(j, @category_column) }
    end

    # Merges others into keep; last_modified: the keeper as the user saw it
    def merge(keep_id : Int64, other_ids : Array(Int64), last_modified : String? = nil) : {Merge, Book}
      @mutex.synchronize do
        p = plan(keep_id, other_ids)
        raise Writer::Conflict.new(p.keep) if last_modified && p.keep.version != last_modified
        m = Merge.new(keep_id, p.others.map(&.id))
        save(m)
        info = library_info
        begin
          unless p.fields.empty?
            body = p.fields.dup
            body["lastModified"] = JSON::Any.new(p.keep.version)
            updated = @writer.update(keep_id, body)
            m.fields = p.fields.keys.compact_map do |f|
              old, new = Dedup.value(p.keep, f, @category_column), Dedup.value(updated, f, @category_column)
              FieldChange.new(f, old, new) unless old == new
            end
            save(m)
          end
          p.formats.each do |move|
            with_file(move.from, move.format, info) do |path|
              if move.replace
                replace_format(keep_id, path, move.format, info)
              else
                @calibre.add_format(keep_id, path, move.format.downcase)
              end
            end
            m.formats << move
            save(m)
          end
          @writer.written([keep_id]) unless m.formats.empty?
          if (from = p.cover_from) && (data = cover(from, info))
            @writer.set_cover(keep_id, data)
            m.cover_from = from
            save(m)
          end
          if l = @lists
            p.others.each do |o|
              l.merge_book(o.id, keep_id).each { |list_id, at| m.list_items << ListItem.new(list_id, at) }
            end
            save(m)
          end
          m.progress = move_progress(p.others.map(&.id), keep_id)
          save(m)
          p.others.each do |o|
            @writer.delete(o.id)
            m.trashed << o.id
            save(m)
          end
          m.status = "done"
        rescue ex
          m.status = "failed"
          m.error = ex.message || ex.class.name
          save(m)
          raise ex
        end
        save(m)
        {m, @calibre.book(keep_id) || raise Writer::NotFound.new}
      end
    end

    # Undoes a merge as far as nobody changed things since; returns the
    # merge and the books (the keeper, the restored ones)
    def undo(id : Int64) : {Merge, Array(Book)}
      @mutex.synchronize do
        m = self[id]? || raise Writer::NotFound.new
        raise Undone.new("undone already") if m.status == "undone"
        errors = [] of String
        # the others back first; nothing else changes when that fails
        m.trashed.each do |old|
          next if m.restored.has_key?(old.to_s)
          trash = @trash
          if trash && trash[old]?
            m.restored[old.to_s] = trash.restore(old).id
            save(m)
          else
            errors << "##{old} is not in the trash any more"
          end
        end
        undo_progress(m)
        @lists.try { |l| l.unmerge_book(m.keep_id, m.list_items.map { |i| {i.list_id, i.added_at} }) }
        if keep = @calibre.book(m.keep_id)
          # A moved format or the cover leaves the keeper only when the book
          # it came from is there again with it: restored from the trash,
          # or never trashed (a failed merge). Otherwise the keeper holds
          # the only copy.
          sources = source_books(m)
          removed = false
          m.formats.each do |f|
            next unless keep.formats.includes?(f.format)
            unless sources[f.from]?.try(&.formats.includes?(f.format))
              errors << "#{f.format} of ##{m.keep_id} stays: ##{f.from} did not come back with it"
              next
            end
            @calibre.cmd("remove_format", [m.keep_id, f.format])
            removed = true
            errors << "#{f.format} of ##{m.keep_id}: the replaced small file stays in calibre's trash" if f.replace
          end
          if from = m.cover_from
            if sources.has_key?(from)
              @calibre.set_fields(m.keep_id, {"cover" => JSON::Any.new(nil), "last_modified" => JSON::Any.new(Time.utc.to_rfc3339(fraction_digits: 6))})
              removed = true
            else
              errors << "the cover of ##{m.keep_id} stays: ##{from} did not come back"
            end
          end
          @writer.written([m.keep_id]) if removed
          keep = @calibre.book(m.keep_id) || keep
          body = revert_body(keep, m, errors)
          unless body.empty?
            body["lastModified"] = JSON::Any.new(keep.version)
            @writer.update(m.keep_id, body)
          end
        else
          errors << "##{m.keep_id} is gone, its fields and formats stay as they are" unless m.fields.empty? && m.formats.empty?
        end
        m.status = "undone"
        m.undone_at = Time.utc
        m.errors = errors
        save(m)
        books = @calibre.books([m.keep_id] + m.restored.values, Calibre::DETAIL_FIELDS)
        {m, books}
      end
    end

    # The books the merge took formats or the cover from, as they are now,
    # by their id in the merge: restored ones under their new id, those
    # never trashed as they are; missing when gone
    private def source_books(m : Merge) : Hash(Int64, Book)
      from = (m.formats.map(&.from) + [m.cover_from].compact).uniq
      now = from.compact_map do |old|
        if m.trashed.includes?(old)
          m.restored[old.to_s]?.try { |n| {old, n} }
        else
          {old, old}
        end
      end
      return {} of Int64 => Book if now.empty?
      found = @calibre.books(now.map(&.[1]), ["formats"]).index_by(&.id)
      now.compact_map { |old, id| found[id]?.try { |b| {old, b} } }.to_h
    end

    # PATCH body setting the filled fields back where they still have the
    # merged value; tags and identifiers lose only what the merge added
    private def revert_body(keep : Book, m : Merge, errors : Array(String)) : Hash(String, JSON::Any)
      body = {} of String => JSON::Any
      m.fields.each do |c|
        now = Dedup.value(keep, c.field, @category_column)
        case c.field
        when "tags"
          added = c.new.as_a.map(&.as_s) - c.old.as_a.map(&.as_s)
          body["removeTags"] = JSON.parse(added.to_json) unless added.empty?
        when "identifiers"
          old = c.old.as_h
          ids = keep.identifiers.reject { |k, v| !old.has_key?(k) && c.new[k]?.try(&.as_s?) == v }
          body["identifiers"] = JSON.parse(ids.to_json) if ids.size != keep.identifiers.size
        else
          if now == c.new
            body[c.field] = c.old
          else
            errors << "#{c.field} of ##{m.keep_id} changed since, left as it is"
          end
        end
      end
      # authors back to unknown: calibre needs one
      body["authors"] = JSON.parse(%(["Unknown"])) if body["authors"]?.try(&.as_a?.try(&.empty?))
      body
    end

    private def move_progress(others : Array(Int64), keep : Int64) : Array(ProgressMove)
      moves = [] of ProgressMove
      others.each do |o|
        progress_rows(o).each do |r|
          previous = progress_rows(keep, r.user, r.device).first?
          if previous.nil? || r.updated_at > previous.updated_at
            write_progress(r.with_book(keep))
            moves << ProgressMove.new(r, true, previous)
          else
            moves << ProgressMove.new(r, false, nil)
          end
        end
      end
      moves
    end

    private def undo_progress(m : Merge)
      m.progress.each do |mv|
        r = mv.row
        if mv.moved
          now = progress_rows(m.keep_id, r.user, r.device).first?
          # read on since: that stays
          if now && now.updated_at == r.updated_at
            if prev = mv.previous
              write_progress(prev)
            else
              @db.exec "delete from reading_progress where user = ? and book_id = ? and device = ?", r.user, m.keep_id, r.device
            end
          end
        end
        m.restored[r.book_id.to_s]?.try { |new_id| write_progress(r.with_book(new_id), replace: false) }
      end
    end

    private def progress_rows(book : Int64, user : String? = nil, device : String? = nil) : Array(ProgressRow)
      rows = [] of ProgressRow
      sql = "select user, book_id, device, device_name, format, position, fraction, source, updated_at from reading_progress where book_id = ?"
      args = [book] of DB::Any
      if user && device
        sql += " and user = ? and device = ?"
        args << user << device
      end
      @db.query_each(sql, args: args) do |rs|
        rows << ProgressRow.new(rs.read(String), rs.read(Int64), rs.read(String), rs.read(String), rs.read(String),
          rs.read(String), rs.read(Float64), rs.read(String), rs.read(Int64))
      end
      rows
    end

    private def write_progress(r : ProgressRow, replace = true)
      @db.exec "insert or #{replace ? "replace" : "ignore"} into reading_progress
                (user, book_id, device, device_name, format, position, fraction, source, updated_at)
                values (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        r.user, r.book_id, r.device, r.device_name, r.format, r.position, r.fraction, r.source, r.updated_at
    end

    # The format file of a book: from the library, else through calibre-server
    # The keeper's tiny file goes to calibre's format trash first (a plain
    # add_format would overwrite it for good). When adding the new one fails
    # after that, the keeper gets its old file back from a copy taken before,
    # so it never ends up without the format.
    private def replace_format(keep_id : Int64, path : String, format : String, info : LibraryInfo)
      backup = File.tempname("merge-keep", ".#{format.downcase}")
      with_file(keep_id, format, info) { |old| FileUtils.cp(old, backup) }
      @calibre.cmd("remove_format", [keep_id, format])
      begin
        @calibre.add_format(keep_id, path, format.downcase)
      rescue ex
        begin
          @calibre.add_format(keep_id, backup, format.downcase)
        rescue
          # still in calibre's format trash
        end
        raise ex
      end
    ensure
      backup.try { |b| File.delete?(b) }
    end

    private def with_file(id : Int64, format : String, info : LibraryInfo, &)
      if (path = info.files.try(&.[id]?).try(&.find { |f| f.format == format.upcase }).try(&.path)) && File.file?(path)
        yield path
        return
      end
      tmp = File.tempname("merge", ".#{format.downcase}")
      begin
        File.open(tmp, "w") do |io|
          @calibre.forward("GET", "/get/#{format.downcase}/#{id}#{@calibre.library_suffix}") do |r|
            raise Calibre::Unavailable.new("calibre-server /get: HTTP #{r.status_code}") if r.status_code >= 500
            raise Calibre::Error.new("no #{format} for book #{id}") unless r.success?
            IO.copy(r.body_io, io)
          end
        end
        yield tmp
      ensure
        File.delete?(tmp)
      end
    end

    private def cover(id : Int64, info : LibraryInfo) : Bytes?
      data = nil
      if (dir = info.files.try(&.[id]?).try(&.first?).try(&.path).try { |p| File.dirname(p) }) && File.file?(File.join(dir, "cover.jpg"))
        data = File.open(File.join(dir, "cover.jpg"), &.getb_to_end)
      else
        @calibre.forward("GET", "/get/cover/#{id}#{@calibre.library_suffix}") do |r|
          data = r.body_io.getb_to_end if r.success?
        end
      end
      data.try { |d| {"jpeg", "png"}.includes?(Covers.image_type(d)) ? d : nil }
    end

    def []?(id : Int64) : Merge?
      @db.query_one?("select id, data from duplicate_merges where id = ?", id) do |rs|
        mid, data = rs.read(Int64, String)
        Merge.from_json(data).tap { |m| m.id = mid }
      end
    end

    # The last merges, newest first
    def merges(limit = 50) : Array(Merge)
      list = [] of Merge
      @db.query_each("select id, data from duplicate_merges order by id desc limit ?", limit) do |rs|
        mid, data = rs.read(Int64, String)
        list << Merge.from_json(data).tap { |m| m.id = mid }
      end
      list
    end

    private def save(m : Merge)
      if m.id == 0
        @db.exec "insert into duplicate_merges (keep_id, data, at) values (?, ?, ?)", m.keep_id, m.to_json, m.at.to_unix
        m.id = @db.scalar("select last_insert_rowid()").as(Int64)
        @db.exec "delete from duplicate_merges where id <= ?", m.id - KEEP_LOG
      end
      @db.exec "update duplicate_merges set data = ? where id = ?", m.to_json, m.id
    end
  end

  class Lists
    # A merge: into joins every list from is in (any owner), with from's
    # time; returns the rows added (list, added_at)
    def merge_book(from : Int64, into : Int64) : Array({Int64, Int64})
      rows = [] of {Int64, Int64}
      @db.query_each("select list_id, added_at from list_items where book_id = ?", from) { |rs| rows << rs.read(Int64, Int64) }
      added = [] of {Int64, Int64}
      @db.transaction do |tx|
        rows.each do |list_id, at|
          tx.connection.exec "insert or ignore into list_items (list_id, book_id, added_at) values (?, ?, ?)", list_id, into, at
          added << {list_id, at} if tx.connection.scalar("select changes()").as(Int64) > 0
        end
      end
      added.each { |list_id, _| find(list_id).try { |l| emit("added", l, book_ids: [into]) } }
      added
    end

    # Undoing a merge: into leaves the lists the merge put it in
    def unmerge_book(into : Int64, rows : Array({Int64, Int64}))
      removed = [] of Int64
      @db.transaction do |tx|
        rows.each do |list_id, _|
          tx.connection.exec "delete from list_items where list_id = ? and book_id = ?", list_id, into
          removed << list_id if tx.connection.scalar("select changes()").as(Int64) > 0
        end
      end
      removed.each { |list_id| find(list_id).try { |l| emit("removed", l, book_ids: [into]) } }
    end
  end

  # GET /api/duplicates, merges, undo, ignore
  def self.duplicate_routes(dups : Duplicates, auth : Auth)
    get "/api/duplicates" do |env|
      write_errors(env) do
        t = env.params.query["threshold"]?.presence.try do |v|
          (v.to_f? || raise Edit::Invalid.new("threshold", "number from #{Dedup::MIN_THRESHOLD} to 1 expected")).tap do |x|
            raise Edit::Invalid.new("threshold", "number from #{Dedup::MIN_THRESHOLD} to 1 expected") unless Dedup::MIN_THRESHOLD <= x <= 1.0
          end
        end || dups.threshold
        groups = dups.groups(t)
        JSON.build do |j|
          j.object do
            j.field "threshold", t
            j.field "groups" { j.array { groups.each { |g| dups.group_json(j, g, auth.user) } } }
          end
        end
      end
    end

    post "/api/duplicates/merge" do |env|
      write_errors(env) do
        body = json_body(env)
        keep = body["keepId"]?.try(&.as_i64?) || raise Edit::Invalid.new("keepId", "book id expected")
        others = duplicate_ids(body)
        if body["dryRun"]?.try(&.as_bool?)
          next %({"plan":#{dups.plan_json(dups.plan(keep, others))}})
        end
        last = body["lastModified"]?.try { |v| v.as_s? || raise Edit::Invalid.new("lastModified", "string expected") }
        m, book = dups.merge(keep, others, last)
        {merge: m, book: book}.to_json
      end
    end

    get "/api/duplicates/merges" do |env|
      write_errors(env) { dups.merges.to_json }
    end

    post "/api/duplicates/merges/:id/undo" do |env|
      write_errors(env) do
        id = env.params.url["id"].to_i64? || raise Writer::NotFound.new
        begin
          m, books = dups.undo(id)
          {merge: m, books: books}.to_json
        rescue ex : Duplicates::Undone
          fail(env, 409, {error: ex.message})
        end
      end
    end

    # before .../ignore so "remove" isn't read as part of it
    post "/api/duplicates/ignore/remove" do |env|
      write_errors(env) { {removed: dups.ignore(duplicate_ids(json_body(env)), undo: true)}.to_json }
    end

    post "/api/duplicates/ignore" do |env|
      write_errors(env) { {ignored: dups.ignore(duplicate_ids(json_body(env)))}.to_json }
    end
  end

  def self.duplicate_ids(body : Hash(String, JSON::Any)) : Array(Int64)
    (body["bookIds"]?.try(&.as_a?) || raise Edit::Invalid.new("bookIds", "list of book ids expected")).map do |v|
      v.as_i64? || raise Edit::Invalid.new("bookIds", "list of book ids expected")
    end
  end
end
