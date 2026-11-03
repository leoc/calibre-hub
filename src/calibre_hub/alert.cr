module CalibreHub
  # Runs the alert command (CALIBRE_HUB_ALERT_COMMAND) with subject and
  # text. True when it went out (or there is no command to run); a failure
  # is logged, never raised.
  module Alert
    def self.run(command : Array(String)?, subject : String, text : String) : Bool
      return true unless command && !command.empty?
      status = Process.run(command[0], command[1..] + [subject, text], output: :inherit, error: :inherit)
      return true if status.success?
      STDERR.puts "alert failed: #{command[0]} exited with #{status.exit_code}"
      false
    rescue ex
      STDERR.puts "alert failed: #{ex.message}"
      false
    end
  end
end
