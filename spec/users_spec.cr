require "spec"
require "sqlite3"
require "../src/calibre_hub/users"

private def with_users(&)
  path = File.tempname("hub-users", ".sqlite")
  db = DB.open("sqlite3://#{path}?max_pool_size=1")
  yield CalibreHub::Users.new(db)
ensure
  db.try &.close
  File.delete?(path) if path
end

private def account(name, role = CalibreHub::Auth::Role::Admin)
  CalibreHub::Auth.account(name, "pw", role)
end

describe CalibreHub::Users do
  it "takes over the single login user of earlier versions" do
    with_users do |users|
      users.sync([account("arthur")])
      users.all.should eq([CalibreHub::Users::User.new("arthur", "admin", true)])
    end
  end

  it "follows the configuration and keeps users no longer configured as inactive" do
    with_users do |users|
      users.sync([account("arthur"), account("lea", CalibreHub::Auth::Role::Reader)])
      users.sync([account("arthur"), account("ben", CalibreHub::Auth::Role::Reader)])
      users.sync([account("arthur"), account("ben")])
      users.all.should eq([
        CalibreHub::Users::User.new("arthur", "admin", true),
        CalibreHub::Users::User.new("ben", "admin", true),
        CalibreHub::Users::User.new("lea", "reader", false),
      ])
    end
  end
end
