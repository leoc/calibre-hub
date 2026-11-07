require "db"
require "sqlite3"

module CalibreHub
  module Incoming
    # The metadata, classify, convert and embed hooks wait while the Eingang's
    # decisions run, so calibre-server only adds books; they work off the new
    # books' events afterwards (their cursors stay where they were)
    def self.paused?(db : DB::Database) : Bool
      !db.query_one?("select 1 from intake_jobs where status = 'running' limit 1", as: Int64).nil?
    rescue DB::Error | SQLite3::Exception
      false
    end
  end
end
