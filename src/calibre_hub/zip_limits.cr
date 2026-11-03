require "compress/zip"

module CalibreHub
  # Limits for every ZIP (EPUB) the hub opens itself (review #8411 M4): a
  # small file that unpacks to gigabytes must fail that file, not take the
  # hub's memory. Sizes in the ZIP's directory are only a first check, the
  # reads count what really comes out.
  module ZipLimits
    class TooLarge < Exception
    end

    MAX_ENTRIES = 10_000
    # all entries together, unpacked (an illustrated EPUB is well below)
    MAX_TOTAL = 512_i64 * 1024 * 1024

    # Entry count and the sizes the directory declares
    def self.check(zip : Compress::Zip::File, max_entries = MAX_ENTRIES, max_total = MAX_TOTAL) : Nil
      raise TooLarge.new("more than #{max_entries} entries") if zip.entries.size > max_entries
      declared = zip.entries.sum(0_i64) { |e| e.uncompressed_size.to_i64 }
      raise TooLarge.new("unpacks to more than #{max_total} bytes") if declared > max_total
    end

    # The entry's content; TooLarge when it has more than max bytes
    def self.read(entry : Compress::Zip::File::Entry, max : Int64) : Bytes
      buf = IO::Memory.new
      copied = entry.open { |io| copy(io, buf, max + 1) }
      raise TooLarge.new("#{entry.filename} unpacks to more than #{max} bytes") if copied > max
      buf.to_slice
    end

    # At most the first max bytes of the entry
    def self.head(entry : Compress::Zip::File::Entry, max : Int64) : Bytes
      buf = IO::Memory.new
      entry.open { |io| copy(io, buf, max) }
      buf.to_slice
    end

    # IO.copy with a limit, without the read of an empty slice it ends with:
    # the zip reader takes that for the entry's end and fails its checksum
    private def self.copy(src : IO, dst : IO, limit : Int64) : Int64
      buffer = Bytes.new(64 * 1024)
      copied = 0_i64
      while copied < limit
        n = src.read(buffer[0, Math.min(buffer.size.to_i64, limit - copied).to_i32])
        break if n == 0
        dst.write(buffer[0, n])
        copied += n
      end
      copied
    end
  end
end
