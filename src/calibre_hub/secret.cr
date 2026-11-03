module CalibreHub
  # Secrets are read from files, e.g. systemd credentials. Trailing newlines
  # are dropped, like nix/init.sh does for calibre-server.
  module Secret
    def self.read(path) : String
      String.new(read_bytes(path))
    end

    # byte-wise, so binary keys (not valid UTF-8) work too
    def self.read_bytes(path) : Bytes
      bytes = File.open(path, &.getb_to_end)
      size = bytes.size
      while size > 0 && bytes[size - 1] == '\n'.ord
        size -= 1
      end
      bytes[0, size]
    end
  end
end
