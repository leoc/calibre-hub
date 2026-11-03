require "bubbletea"
require "./actions"
require "./theme"
require "./text"

module CalibreHub
  module Tui
    # The `:` line: a text input with Tab completion (like Vim's wildmenu:
    # Tab inserts the common part, then cycles through the candidates,
    # Shift+Tab back) and a history (Up/Down, filtered by what is typed),
    # kept in a file between runs when one is given.
    class CommandLine
      MAX_HISTORY = 200

      getter history : Array(String)
      # the candidates on show, and which one is inserted
      getter candidates = [] of String
      getter chosen : Int32? = nil
      @cycle_start = 0
      @browse : Int32? = nil
      @draft = ""
      @input : Bubbles::TextInput

      def initialize(@history_file : String? = nil, width = 80)
        @history = load
        @input = Bubbles::TextInput.new(prompt: ":", width: width, prompt_style: Theme.accent)
      end

      def width=(w : Int32)
        @input.configure(width: w)
      end

      def value : String
        @input.value
      end

      def value=(text : String)
        @input.value = text
        @input.cursor_end
      end

      def open(text = "") : Tea::Cmd?
        self.value = text
        reset_completion
        @browse = nil
        @input.focus
      end

      def close : Nil
        @input.blur
        reset_completion
      end

      # :submit (with the line), :cancel or nil (still typing)
      def key(msg : Tea::KeyMsg, choices : Choices) : {Symbol?, Tea::Cmd?}
        case msg.key
        when "enter"
          line = value.strip
          remember(line) unless line.empty?
          close
          return {:submit, nil}
        when "esc", "ctrl+c"
          close
          return {:cancel, nil}
        when "backspace"
          if value.empty?
            close
            return {:cancel, nil}
          end
        when "tab"
          complete(choices, 1)
          return {nil, nil}
        when "shift+tab"
          complete(choices, -1)
          return {nil, nil}
        when "up", "ctrl+p"
          browse(-1)
          return {nil, nil}
        when "down", "ctrl+n"
          browse(1)
          return {nil, nil}
        end
        reset_completion
        @browse = nil
        {nil, @input.update(msg)}
      end

      def view : String
        @input.view
      end

      # other messages (cursor blink)
      def update(msg : Tea::Msg) : Tea::Cmd?
        @input.update(msg)
      end

      # the candidates as one line, the inserted one marked
      def candidates_view(width : Int32) : String?
        return nil if @candidates.size < 2
        parts = @candidates.map_with_index do |c, i|
          i == @chosen ? Theme.cursor(true).bold.render(" #{c} ") : Theme.muted.render(" #{c} ")
        end
        line = ""
        used = 0
        parts.each_with_index do |p, i|
          w = Text.width(@candidates[i]) + 2
          break if used + w > width
          line += p
          used += w
        end
        line
      end

      private def complete(choices : Choices, step : Int32) : Nil
        if !@candidates.empty? && (c = @chosen)
          @chosen = (c + step) % @candidates.size
          self.value = value[0, @cycle_start] + @candidates[@chosen.not_nil!]
          return
        end
        line = value
        start, found, word = Completion.command_line(line, choices)
        return reset_completion if found.empty?
        typed = line[start..]
        if found.size == 1
          self.value = line[0, start] + found[0] + (word ? " " : "")
          return reset_completion
        end
        @candidates = found
        @cycle_start = start
        prefix = Completion.common_prefix(found)
        if prefix.size > typed.size
          self.value = line[0, start] + prefix
          @chosen = nil
        else
          @chosen = step > 0 ? 0 : found.size - 1
          self.value = line[0, start] + found[@chosen.not_nil!]
        end
      end

      private def reset_completion : Nil
        @candidates = [] of String
        @chosen = nil
      end

      # older (-1) or newer (1) lines that start with what was typed
      private def browse(step : Int32) : Nil
        reset_completion
        if @browse.nil?
          return if step > 0
          @draft = value
        end
        i = @browse || @history.size
        loop do
          i += step
          if i >= @history.size
            @browse = nil
            self.value = @draft
            return
          end
          return if i < 0
          if @history[i].downcase.starts_with?(@draft.downcase)
            @browse = i
            self.value = @history[i]
            return
          end
        end
      end

      private def remember(line : String) : Nil
        @history.delete(line)
        @history << line
        @history = @history.last(MAX_HISTORY)
        save
      end

      private def load : Array(String)
        path = @history_file || return [] of String
        File.read_lines(path).reject(&.blank?).last(MAX_HISTORY)
      rescue File::Error
        [] of String
      end

      private def save : Nil
        path = @history_file || return
        Dir.mkdir_p(File.dirname(path))
        File.write(path, @history.join('\n') + "\n")
      rescue File::Error
      end
    end
  end
end
