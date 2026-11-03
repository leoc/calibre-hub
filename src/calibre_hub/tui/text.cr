module CalibreHub
  module Tui
    # Display width of plain text (no escape sequences) in terminal cells,
    # without a call into Go per cell: wide East Asian characters and emoji
    # take two cells, combining marks and controls none.
    module Text
      WIDE = [
        0x1100..0x115F, 0x2E80..0x303E, 0x3041..0x33FF, 0x3400..0x4DBF, 0x4E00..0x9FFF,
        0xA000..0xA4CF, 0xAC00..0xD7A3, 0xF900..0xFAFF, 0xFE30..0xFE4F, 0xFF00..0xFF60,
        0xFFE0..0xFFE6, 0x1F300..0x1F64F, 0x1F900..0x1F9FF, 0x20000..0x3FFFD,
      ]
      ZERO = [0x0300..0x036F, 0x200B..0x200F, 0x20D0..0x20FF, 0xFE00..0xFE0F, 0xFE20..0xFE2F]

      def self.char_width(c : Char) : Int32
        o = c.ord
        return 0 if o < 32 || (0x7F..0x9F).includes?(o)
        return 1 if o < 0x300
        return 0 if ZERO.any?(&.includes?(o))
        WIDE.any?(&.includes?(o)) ? 2 : 1
      end

      def self.width(s : String) : Int32
        s.each_char.sum { |c| char_width(c) }
      end

      # Control characters (not shown, width 0) out, so an escape sequence
      # in a book's metadata never reaches the terminal (review #8411 N5)
      def self.clean(s : String) : String
        s.gsub(/[\x00-\x08\x0b-\x1f\x7f\x{80}-\x{9f}]/, "")
      end

      # Cut to at most `max` cells, with "…" when something was cut; without
      # control characters
      def self.truncate(s : String, max : Int32) : String
        return "" if max <= 0
        s = clean(s)
        return s if width(s) <= max
        acc = String::Builder.new
        used = 0
        s.each_char do |c|
          w = char_width(c)
          break if used + w > max - 1
          acc << c
          used += w
        end
        acc << "…"
        acc.to_s
      end

      # Cut or pad with spaces to exactly `size` cells
      def self.fit(s : String, size : Int32) : String
        t = truncate(single_line(s), size)
        t + " " * Math.max(0, size - width(t))
      end

      def self.single_line(s : String) : String
        s.gsub(/[\r\n\t\v\f]+/, " ")
      end

      # Words wrapped to lines of at most `max` cells
      def self.wrap(s : String, max : Int32) : Array(String)
        lines = [] of String
        line = ""
        s.split(/\s+/, remove_empty: true).each do |word|
          word = truncate(word, max)
          if line.empty?
            line = word
          elsif width(line) + 1 + width(word) <= max
            line += " " + word
          else
            lines << line
            line = word
          end
        end
        lines << line unless line.empty?
        lines
      end
    end
  end
end
