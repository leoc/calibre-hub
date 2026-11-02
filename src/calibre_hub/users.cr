require "db"
require "./auth"

module CalibreHub
  # The hub users in the state DB: who exists, with which role. The
  # configuration (Nix options, passwords from secret files) decides; on
  # every start it is written here. A user no longer configured stays as
  # inactive, so their lists and progress keep an owner, but can't log in.
  # Passwords and tokens are never stored.
  class Users
    record User, name : String, role : String, active : Bool

    def initialize(@db : DB::Database)
      @db.exec <<-SQL
        create table if not exists users (
          name text primary key,
          role text not null,
          active integer not null default 1,
          created_at integer not null,
          updated_at integer not null
        )
        SQL
    end

    # Takes over the configured users; the single login user of earlier
    # versions arrives here as the first admin
    def sync(accounts : Array(Auth::Account), now = Time.utc) : Nil
      @db.transaction do |tx|
        c = tx.connection
        c.exec "update users set active = 0, updated_at = ? where active = 1", now.to_unix
        accounts.each do |a|
          c.exec "insert into users (name, role, active, created_at, updated_at) values (?, ?, 1, ?, ?)
                  on conflict (name) do update set role = excluded.role, active = 1, updated_at = excluded.updated_at",
            a.name, a.role.to_s, now.to_unix, now.to_unix
        end
      end
    end

    def all : Array(User)
      users = [] of User
      @db.query_each("select name, role, active from users order by name") do |rs|
        users << User.new(rs.read(String), rs.read(String), rs.read(Int64) == 1)
      end
      users
    end
  end
end
