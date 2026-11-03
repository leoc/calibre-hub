module CalibreHub
  # External tools (calibre, poppler) with a time limit, so a file a tool
  # hangs on (review #8411 N4) can't block a job or a request for good.
  module Command
    class Timeout < Exception
    end

    # Runs cmd and returns its status; killed after timeout, which raises
    # Timeout. Output and error are closed unless given.
    def self.run(cmd : String, args : Array(String), timeout : Time::Span, env : Process::Env = nil,
                 output : IO? = nil, error : IO? = nil) : Process::Status
      process = Process.new(cmd, args, env: env,
        output: output || Process::Redirect::Close, error: error || Process::Redirect::Close)
      done = Channel(Process::Status).new(1)
      spawn { done.send(process.wait) }
      select
      when status = done.receive
        status
      when timeout(timeout)
        process.terminate rescue nil
        raise Timeout.new("#{cmd}: timeout after #{timeout.total_seconds.to_i} s")
      end
    end
  end
end
