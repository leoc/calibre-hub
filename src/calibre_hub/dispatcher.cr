require "db"
require "json"
require "./alert"

module CalibreHub
  # Delivers events to the executables in handlers.d, at least once.
  # Every (event, handler) pair is a delivery; a handler gets the event JSON
  # on stdin and must exit 0. Failures retry with exponential backoff and are
  # parked after max_attempts, which raises an alert. Handlers run one at a
  # time in name order; each handler gets events in the order they happened.
  class Dispatcher
    getter handlers_dir : String?

    def initialize(@db : DB::Database, @handlers_dir : String?, @env : Hash(String, String) = {} of String => String,
                   @max_attempts = 10, @timeout : Time::Span = 10.minutes,
                   @alert : Array(String)? = nil, @base_delay : Time::Span = 10.seconds,
                   @max_delay : Time::Span = 1.hour)
    end

    def handlers : Array(String)
      dir = @handlers_dir
      return [] of String unless dir && Dir.exists?(dir)
      Dir.children(dir).sort.select do |name|
        path = File.join(dir, name)
        !name.starts_with?('.') && File::Info.executable?(path) && !File.directory?(path)
      end
    end

    # One pass: create deliveries for new events, run due ones.
    # Returns the number of deliveries run.
    def run_once(now = Time.utc) : Int32
      hs = handlers
      ran = 0
      pending = [] of {Int64, String}
      @db.query_each("select id, payload from events where done_at is null order by id limit 200") do |rs|
        pending << {rs.read(Int64), rs.read(String)}
      end
      # a handler that still waits on an event gets no later events, so it
      # sees them in order; other handlers carry on
      blocked = Set(String).new
      pending.each do |event_id, payload|
        hs.each do |h|
          @db.exec "insert or ignore into deliveries (event_id, handler) values (?, ?)", event_id, h
        end
        hs.each do |h|
          next if blocked.includes?(h)
          row = @db.query_one?("select attempts, next_attempt_at, done_at, failed_at from deliveries where event_id = ? and handler = ?",
            event_id, h, as: {Int64, Int64, Int64?, Int64?})
          next unless row
          attempts, next_at, done_at, failed_at = row
          next if done_at || failed_at
          if next_at > now.to_unix
            blocked << h
            next
          end
          ran += 1
          deliver(event_id, h, payload, attempts, now)
          blocked << h unless delivered?(event_id, h)
        end
        open = @db.query_one("select count(*) from deliveries where event_id = ? and done_at is null and failed_at is null", event_id, as: Int64)
        @db.exec "update events set done_at = ? where id = ?", now.to_unix, event_id if open == 0
      end
      ran
    end

    # Parked deliveries, newest first (for the API later)
    def failed(limit = 50) : Array(NamedTuple(event_id: Int64, handler: String, attempts: Int64, error: String?))
      rows = [] of NamedTuple(event_id: Int64, handler: String, attempts: Int64, error: String?)
      @db.query_each("select event_id, handler, attempts, last_error from deliveries where failed_at is not null order by failed_at desc limit ?", limit) do |rs|
        rows << {event_id: rs.read(Int64), handler: rs.read(String), attempts: rs.read(Int64), error: rs.read(String?)}
      end
      rows
    end

    def delay(attempts : Int64) : Time::Span
      d = @base_delay * (2.0 ** (attempts - 1).clamp(0, 30))
      d > @max_delay ? @max_delay : d
    end

    private def delivered?(event_id, handler) : Bool
      !@db.query_one("select done_at from deliveries where event_id = ? and handler = ?", event_id, handler, as: Int64?).nil?
    end

    private def deliver(event_id : Int64, handler : String, payload : String, attempts : Int64, now : Time)
      path = File.join(@handlers_dir.not_nil!, handler)
      ok, error = run(path, payload)
      attempts += 1
      if ok
        @db.exec "update deliveries set attempts = ?, done_at = ?, last_error = null where event_id = ? and handler = ?",
          attempts, Time.utc.to_unix, event_id, handler
      elsif attempts >= @max_attempts
        @db.exec "update deliveries set attempts = ?, failed_at = ?, last_error = ? where event_id = ? and handler = ?",
          attempts, Time.utc.to_unix, error, event_id, handler
        STDERR.puts "handler #{handler} gave up on event #{event_id} after #{attempts} attempts: #{error}"
        alert("calibre-hub: handler #{handler} failed",
          "Event #{event_id} after #{attempts} attempts: #{error}")
      else
        next_at = (now + delay(attempts)).to_unix
        @db.exec "update deliveries set attempts = ?, next_attempt_at = ?, last_error = ? where event_id = ? and handler = ?",
          attempts, next_at, error, event_id, handler
        STDERR.puts "handler #{handler} failed on event #{event_id} (attempt #{attempts}): #{error}"
      end
    end

    private def run(path : String, payload : String) : {Bool, String?}
      output = IO::Memory.new
      process = Process.new(path, env: @env, input: :pipe, output: output, error: output)
      begin
        process.input.print payload
        process.input.close
      rescue IO::Error
        # handler exited without reading stdin; only its exit code counts
      end
      done = Channel(Process::Status).new(1)
      spawn { done.send(process.wait) }
      select
      when status = done.receive
        log = output.to_s.strip
        log.each_line { |l| puts "[#{File.basename(path)}] #{l}" } unless log.empty?
        status.success? ? {true, nil} : {false, "exit #{status.exit_code}: #{log.lines.last? || ""}"}
      when timeout(@timeout)
        process.terminate rescue nil
        {false, "timeout after #{@timeout.total_seconds.to_i} s"}
      end
    rescue ex : File::Error | IO::Error
      {false, ex.message}
    end

    private def alert(subject : String, text : String)
      Alert.run(@alert, subject, text)
    end
  end
end
