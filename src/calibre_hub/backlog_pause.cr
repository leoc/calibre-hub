require "db"
require "sqlite3"

module CalibreHub
  module Backlog
    # The metadata, classify, convert and embed hooks wait while a backlog
    # import job or the Eingang's decisions run, so calibre-server only adds
    # books; they work off the new books' events afterwards (their cursors
    # stay where they were)
    def self.paused?(db : DB::Database) : Bool
      running?(db, "import_jobs") || running?(db, "intake_jobs")
    end

    private def self.running?(db : DB::Database, table : String) : Bool
      !db.query_one?("select 1 from #{table} where status = 'running' limit 1", as: Int64).nil?
    rescue DB::Error | SQLite3::Exception
      false
    end
  end
end
