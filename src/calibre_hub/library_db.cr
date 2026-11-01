require "db"
require "sqlite3"

module CalibreHub
  # Direct access to calibre's metadata.db, read-only for the hub. Only
  # install_triggers writes, and only while calibre-server is stopped
  # (preStart), so calibre-server stays the only writer at runtime.
  #
  # Triggers append (book, table, op) to hub_changelog for every change to a
  # book or anything linked to it. Renaming a tag, author, series ... changes
  # only the value table, so those get UPDATE triggers that log all linked
  # books.
  module LibraryDB
    CHANGELOG = "hub_changelog"
    PREFIX    = "hub_"
    # keep this many rows; the hub reads far more often than that fills up
    KEEP = 100_000

    # per-book tables calibre keeps besides metadata (reading positions,
    # annotations, conversion settings ...) are not metadata changes
    IGNORED = %w(annotations annotations_dirtied metadata_dirtied conversion_options
      books_plugin_data last_read_positions books_pages_link)

    record Change, seq : Int64, book : Int64

    def self.open_read_only(path : String) : DB::Database
      # calibre-server holds write locks briefly; wait instead of failing
      db = DB.open("sqlite3://#{path}?busy_timeout=10000&max_pool_size=1")
      db.exec "pragma query_only = on"
      db
    end

    def self.max_seq(db : DB::Database) : Int64?
      db.query_one?("select max(seq) from #{CHANGELOG}", as: Int64?)
    rescue SQLite3::Exception
      nil
    end

    # Changes after seq; nil if the changelog does not exist
    def self.changes_since(db : DB::Database, seq : Int64, limit = 10_000) : Array(Change)?
      rows = [] of Change
      db.query_each("select seq, book from #{CHANGELOG} where seq > ? order by seq limit ?", seq, limit) do |rs|
        rows << Change.new(rs.read(Int64), rs.read(Int64))
      end
      rows
    rescue SQLite3::Exception
      nil
    end

    def self.triggers_installed?(db : DB::Database) : Bool
      expected = trigger_sql(db).map(&.[0]).to_set
      present = Set(String).new
      db.query_each("select name from sqlite_master where type = 'trigger' and name like '#{PREFIX}%'") do |rs|
        present << rs.read(String)
      end
      !expected.empty? && expected.subset_of?(present)
    end

    # Idempotent: drops all hub triggers and creates them from the current
    # schema, so new custom columns are covered after the next start.
    def self.install_triggers(path : String)
      db = DB.open("sqlite3://#{path}?max_pool_size=1")
      statements = trigger_sql(db)
      db.transaction do |tx|
        c = tx.connection
        c.exec <<-SQL
          create table if not exists #{CHANGELOG} (
            seq integer primary key autoincrement,
            book integer not null,
            tbl text not null,
            op text not null,
            at real not null default (julianday('now'))
          )
          SQL
        old = [] of String
        c.query_each("select name from sqlite_master where type = 'trigger' and name like '#{PREFIX}%'") do |rs|
          old << rs.read(String)
        end
        old.each { |name| c.exec %(drop trigger "#{name}") }
        statements.each { |_, sql| c.exec sql }
      end
    ensure
      db.try &.close
    end

    # [name, create statement] for the current schema
    def self.trigger_sql(db : DB::Database) : Array({String, String})
      tables = {} of String => Array(String)
      db.query_each("select name from sqlite_master where type = 'table' and name not like 'sqlite_%'") do |rs|
        tables[rs.read(String)] = [] of String
      end
      tables.each_key do |t|
        db.query_each(%(select name from pragma_table_info("#{t}"))) { |rs| tables[t] << rs.read(String) }
      end

      sql = [] of {String, String}
      log = ->(name : String, table : String, op : String, book : String) do
        {name, <<-SQL}
          create trigger "#{name}" after #{op} on "#{table}" begin
            insert into #{CHANGELOG} (book, tbl, op) values (#{book}, '#{table}', '#{op.downcase}');
          end
          SQL
      end

      {"insert" => "new.id", "update" => "new.id", "delete" => "old.id"}.each do |op, ref|
        sql << log.call("#{PREFIX}books_#{op}", "books", op.upcase, ref)
      end

      tables.each do |table, cols|
        next if table == "books" || table == CHANGELOG || IGNORED.includes?(table)
        next if table.includes?("_fts")
        if cols.includes?("book")
          {"insert" => "new.book", "update" => "new.book", "delete" => "old.book"}.each do |op, ref|
            sql << log.call("#{PREFIX}#{table}_#{op}", table, op.upcase, ref)
          end
        end
        # value tables: books_<values>_link(book, <column>) -> <values>(id)
        if (m = table.match(/\Abooks_(.+)_link\z/)) && tables.has_key?(m[1]) && !tables[m[1]].includes?("book")
          values = m[1]
          column = (cols - %w(id book)).first?
          next unless column
          name = "#{PREFIX}#{values}_rename"
          sql << {name, <<-SQL}
            create trigger "#{name}" after update on "#{values}" begin
              insert into #{CHANGELOG} (book, tbl, op)
                select book, '#{values}', 'update' from "#{table}" where "#{column}" = new.id;
            end
            SQL
        end
      end

      sql << {"#{PREFIX}changelog_prune", <<-SQL}
        create trigger "#{PREFIX}changelog_prune" after insert on #{CHANGELOG}
          when new.seq % 1000 = 0 begin
          delete from #{CHANGELOG} where seq <= new.seq - #{KEEP};
        end
        SQL
      sql
    end
  end
end
