require "json"

module CalibreHub
  module Tui
    # Own key bindings from $XDG_CONFIG_HOME/calibre-hub/tui-keys.json, in the
    # web app's format (its hub.keymap.vim, see README): {"down": ["n", "j"],
    # ...}. Own bindings replace the defaults of the actions they name, like
    # withOverrides in frontend/src/lib/keymap.ts. On top of that "leader":
    # what <Leader> in a binding stands for (the web app ignores the key).
    module Keymap
      # Vim's default
      LEADER = "\\"

      # actions only the web app has: a file shared with it names them, the
      # TUI leaves them out without a word
      WEB_ONLY = %w(forward goMetadata goSuggestions goCategories goLists goDuplicates hints hintsSelect
        saveLast saveDialog copyLink extendLeft extendRight)

      record Loaded, bindings : Bindings, leader : String, warnings : Array(String), path : String? = nil,
        own : Bool = false

      def self.defaults(path : String? = nil) : Loaded
        Loaded.new(DEFAULT_BINDINGS, LEADER, [] of String, path)
      end

      # $XDG_CONFIG_HOME/calibre-hub/tui-keys.json, ~/.config without it
      def self.path(env : Hash(String, String)) : String?
        config = env["XDG_CONFIG_HOME"]?.presence || env["HOME"]?.presence.try { |h| File.join(h, ".config") }
        config.try { |c| File.join(c, "calibre-hub", "tui-keys.json") }
      end

      # the bindings of the file, the defaults when there is none; what is
      # wrong in it is left out and said in `warnings`
      def self.load(path : String?) : Loaded
        return defaults(path) unless path && File.exists?(path)
        parse(File.read(path), path)
      rescue ex : IO::Error
        Loaded.new(DEFAULT_BINDINGS, LEADER, ["#{path}: #{ex.message}"], path)
      end

      def self.parse(json : String, path : String? = nil) : Loaded
        name = path.try { |p| File.basename(p) } || "tui-keys.json"
        raw = begin
          JSON.parse(json).as_h?
        rescue ex : JSON::ParseException
          return Loaded.new(DEFAULT_BINDINGS, LEADER, ["#{name}: kein gültiges JSON (#{ex.message}), Standardtasten aktiv"], path)
        end
        return Loaded.new(DEFAULT_BINDINGS, LEADER, ["#{name}: ein Objekt {\"aktion\": [\"tasten\"]} erwartet"], path) unless raw
        warnings = [] of String
        leader = LEADER
        own = Bindings.new
        raw.each do |key, value|
          if key == "leader"
            if (l = value.as_s?) && !Tui.parse_keys(l).empty?
              leader = l
            else
              warnings << "#{name}: leader muss eine Taste sein"
            end
            next
          end
          action = Action.values.find { |a| a.name == key }
          unless action
            warnings << "#{name}: unbekannte Aktion #{key}" unless WEB_ONLY.includes?(key)
            next
          end
          keys = value.as_a?.try(&.map(&.as_s?))
          if keys.nil? || keys.any? { |k| k.nil? || k.empty? }
            warnings << "#{name}: #{key} braucht eine Liste von Tasten"
            next
          end
          own[action] = keys.compact
        end
        # own bindings first: a key bound by the file wins over a default one
        bindings = own.merge(DEFAULT_BINDINGS.reject { |a, _| own.has_key?(a) })
        Loaded.new(bindings, leader, warnings, path, !own.empty? || leader != LEADER)
      end
    end
  end
end
