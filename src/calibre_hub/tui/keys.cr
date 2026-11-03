require "bubbletea"

module CalibreHub
  module Tui
    # Actions of the TUI. Their names (`Action#name`: "down", "halfDown",
    # "goLibrary" ...) are the web app's keymap names (frontend/src/lib/keymap.ts)
    # where both have the action, so the same own bindings (tui-keys.json,
    # the web's hub.keymap.vim) work in both.
    enum Action
      Down
      Up
      Left
      Right
      First
      Last
      HalfDown
      HalfUp
      NextPage
      PrevPage
      Open
      Search
      SearchNext
      SearchPrev
      Sort
      Order
      SwitchPane
      GoLibrary
      Back
      Help
      Quit
      Edit
      ToggleSelect
      ToggleList
      FastTag
      Delete
      Download
      Undo
      Commands
      Visual
      SelectAll
      ExtendDown
      ExtendUp
      Repeat
      GoTrash
      Restore

      def name : String
        to_s.camelcase(lower: true)
      end
    end

    alias Bindings = Hash(Action, Array(String))

    # Keys are written like in the web app and Vim: a printable character is
    # itself ("j", "G", "/"), anything else <Name> with modifiers C-, A-, S-
    # ("<C-d>", "<Down>", "<S-Tab>"); a sequence is keys one after the other ("gg").
    DEFAULT_BINDINGS = Bindings{
      Action::Down       => ["j", "<Down>"],
      Action::Up         => ["k", "<Up>"],
      Action::Left       => ["h", "<Left>"],
      Action::Right      => ["l", "<Right>"],
      Action::First      => ["gg", "<Home>"],
      Action::Last       => ["G", "<End>"],
      Action::HalfDown   => ["<C-d>"],
      Action::HalfUp     => ["<C-u>"],
      Action::NextPage   => ["<C-f>", "]", "<PageDown>"],
      Action::PrevPage   => ["<C-b>", "[", "<PageUp>"],
      Action::Open       => ["<Enter>"],
      Action::Search     => ["/"],
      Action::SearchNext => ["n"],
      Action::SearchPrev => ["N"],
      Action::Sort       => ["o"],
      Action::Order      => ["O"],
      Action::SwitchPane => ["<Tab>", "<S-Tab>"],
      Action::GoLibrary  => ["gl"],
      Action::Back       => ["q", "<Esc>", "H", "<A-Left>"],
      Action::Help       => ["?"],
      Action::Quit       => ["<C-c>"],
      # the web app's Vim keys where it has the action; ":" like Vim, ">"
      # like the web app's command palette
      Action::Edit         => ["e", "<F2>"],
      Action::ToggleSelect => ["<Space>"],
      Action::ToggleList   => ["t"],
      Action::FastTag      => ["T"],
      Action::Delete       => ["dd", "<Del>"],
      Action::Download     => ["D"],
      Action::Undo         => ["u"],
      Action::Commands     => [":", ">"],
      # V: lines, which in a table is the same as v
      Action::Visual     => ["v", "V"],
      Action::SelectAll  => ["<C-a>"],
      Action::ExtendDown => ["<S-Down>"],
      Action::ExtendUp   => ["<S-Up>"],
      Action::Repeat     => ["."],
      Action::GoTrash    => ["gt"],
      Action::Restore    => ["r"],
    }

    # Help groups, in this order (like the web app's help)
    HELP_GROUPS = [
      {"Bewegen", [Action::Down, Action::Up, Action::First, Action::Last, Action::HalfDown, Action::HalfUp,
                   Action::NextPage, Action::PrevPage, Action::Left, Action::Right, Action::SwitchPane]},
      {"Buch", [Action::Open, Action::SearchNext, Action::SearchPrev]},
      {"Auswahl", [Action::ToggleSelect, Action::Visual, Action::SelectAll, Action::ExtendDown, Action::ExtendUp]},
      {"Bearbeiten", [Action::Edit, Action::ToggleList, Action::FastTag, Action::Delete,
                      Action::Download, Action::Repeat, Action::Undo, Action::Commands]},
      {"Bibliothek", [Action::Search, Action::Sort, Action::Order, Action::GoLibrary, Action::GoTrash, Action::Restore,
                      Action::Back, Action::Help, Action::Quit]},
    ]

    HELP_TEXT = {
      Action::Down         => "nach unten (mit Zahl davor: so oft)",
      Action::Up           => "nach oben",
      Action::First        => "zum ersten (Zahl: zur Zeile)",
      Action::Last         => "zum letzten (Zahl: zur Zeile)",
      Action::HalfDown     => "halbe Seite nach unten",
      Action::HalfUp       => "halbe Seite nach oben",
      Action::NextPage     => "Seite nach unten",
      Action::PrevPage     => "Seite nach oben",
      Action::Left         => "Seitenleiste; dort: zuklappen, zur Ebene darüber",
      Action::Right        => "Seitenleiste: aufklappen, zur Bibliothek",
      Action::SwitchPane   => "zwischen Seitenleiste und Bibliothek wechseln",
      Action::Open         => "Buch öffnen; Seitenleiste: Filter an/aus",
      Action::SearchNext   => "nächster Treffer (im Buch: nächstes Buch)",
      Action::SearchPrev   => "vorheriger Treffer (im Buch: voriges Buch)",
      Action::Search       => "suchen (calibre-Suche, wie im Web)",
      Action::Sort         => "Sortierung wechseln",
      Action::Order        => "Reihenfolge umkehren",
      Action::GoLibrary    => "alle Bücher (Filter zurücksetzen)",
      Action::Back         => "zurück (Buch schließen, vorige Ansicht, beenden)",
      Action::Help         => "diese Hilfe",
      Action::Quit         => "beenden",
      Action::Edit         => "Buch bearbeiten (Formular)",
      Action::ToggleSelect => "Buch aus- oder abwählen (Befehle wirken auf die Auswahl)",
      Action::ToggleList   => "auf die Standardliste oder herunter",
      Action::FastTag      => "Fast-Tag umschalten (danach Ziffer)",
      Action::Delete       => "in den Papierkorb (fragt)",
      Action::Download     => "Datei ins aktuelle Verzeichnis",
      Action::Undo         => "letzte Änderung zurücknehmen",
      Action::Commands     => "Befehlszeile (Tab ergänzt, ↑/↓ Verlauf)",
      Action::Visual       => "visueller Modus: Bewegen wählt aus (nochmal: Ende)",
      Action::SelectAll    => "alle Treffer auswählen",
      Action::ExtendDown   => "Auswahl nach unten erweitern",
      Action::ExtendUp     => "Auswahl nach oben erweitern",
      Action::Repeat       => "letzte Änderung wiederholen (auf Auswahl oder Buch)",
      Action::GoTrash      => "Papierkorb",
      Action::Restore      => "im Papierkorb: wiederherstellen",
    }

    KEY_NAMES = {
      "enter" => "Enter", "esc" => "Esc", "up" => "Up", "down" => "Down", "left" => "Left",
      "right" => "Right", "home" => "Home", "end" => "End", "pgup" => "PageUp", "pgdown" => "PageDown",
      "tab" => "Tab", "backspace" => "BS", "delete" => "Del", "insert" => "Insert", "space" => "Space",
    }

    # One Bubble Tea key press as keymap tokens: "j", "G", "<C-d>", "<S-Tab>".
    # Several typed characters in one message become one token each.
    def self.tokens(msg : Tea::KeyMsg) : Array(String)
      key = msg.key
      return [] of String if key.empty?
      return ["<Space>"] if key == " "
      if msg.runes? && !msg.alt? && !msg.paste?
        return msg.runes.chars.map { |c| c == ' ' ? "<Space>" : c.to_s }
      end
      return [] of String if msg.paste?
      parts = key.split('+')
      # "+" itself, "alt++"
      name = parts.last.empty? ? "+" : parts.last
      mods = parts[0...-1].reject(&.empty?)
      prefix = String.build do |s|
        s << "C-" if mods.includes?("ctrl")
        s << "A-" if mods.includes?("alt")
        s << "S-" if mods.includes?("shift")
      end
      name = KEY_NAMES[name]? || (name.matches?(/\Af\d{1,2}\z/) ? name.upcase : name)
      return [name] if prefix.empty? && name.size == 1
      ["<#{prefix}#{name}>"]
    end

    CANONICAL = %w(Down Up Left Right Esc Del BS Space Enter Tab Home End PageDown PageUp Insert Leader)
      .to_h { |n| {n.downcase, n} }

    # "gg" -> ["g", "g"], "<c-d>x" -> ["<C-d>", "x"]; like the web app's
    # parseKeys (M- is Ctrl, names in their usual spelling)
    def self.parse_keys(keys : String) : Array(String)
      out = [] of String
      i = 0
      while i < keys.size
        m = keys[i] == '<' ? keys[i..].match(/\A<((?:[CASMcasm]-)*)([^<>\s-]+|-)>/) : nil
        if m
          raw = m[1].upcase
          mods = %w(C A S).select { |x| raw.includes?("#{x}-") || (x == "C" && raw.includes?("M-")) }
          name = m[2]
          name = CANONICAL[name.downcase]? ||
                 (name.matches?(/\Af\d{1,2}\z/i) ? name.upcase : (name.size == 1 && !mods.empty? ? name.downcase : name))
          out << (mods.empty? && name.size == 1 ? name : "<#{mods.map { |x| "#{x}-" }.join}#{name}>")
          i += m[0].size
        else
          out << keys[i].to_s
          i += 1
        end
      end
      out
    end

    # Shown in the help: "<C-d>" -> "Strg+D", "<Down>" -> "↓"
    SHOWN = {"Down" => "↓", "Up" => "↑", "Left" => "←", "Right" => "→", "PageDown" => "Bild↓",
             "PageUp" => "Bild↑", "Home" => "Pos1", "End" => "Ende", "Space" => "Leertaste", "Del" => "Entf"}

    def self.format_keys(keys : String) : String
      toks = parse_keys(keys)
      # "gg" stays as typed
      return keys if toks.all? { |t| t.size == 1 }
      toks.map do |tok|
        if m = tok.match(/\A<((?:[CAS]-)*)(.+)>\z/)
          mods = m[1].split('-', remove_empty: true).map { |x| {"C" => "Strg+", "A" => "Alt+", "S" => "Shift+"}[x] }
          name = SHOWN[m[2]]? || (m[2].size == 1 ? m[2].upcase : m[2])
          mods.join + name
        else
          tok
        end
      end.join(" ")
    end

    # Turns key tokens into actions: sequences ("gg") and a count in front
    # ("5j"). A key that fits nothing drops what was typed so far. Same rules
    # as the web app's KeyEngine.
    class KeyEngine
      record Fired, action : Action, count : Int32?

      @exact = {} of String => Action
      @prefixes = Set(String).new
      @buffer = [] of String
      @count = ""

      # `leader`: what <Leader> in a binding stands for
      def initialize(bindings : Bindings = DEFAULT_BINDINGS, @counts = true, leader : String = Keymap::LEADER)
        lead = Tui.parse_keys(leader)
        bindings.each do |action, list|
          list.each do |keys|
            toks = Tui.parse_keys(keys).flat_map { |t| t == "<Leader>" ? lead : [t] }
            next if toks.empty?
            id = toks.join('\0')
            @exact[id] = action unless @exact.has_key?(id)
            (1...toks.size).each { |i| @prefixes << toks[0, i].join('\0') }
          end
        end
      end

      # what has been typed towards the next action, for the status line
      def pending : String
        @count + @buffer.join
      end

      def reset : Nil
        @buffer.clear
        @count = ""
      end

      # an action, :pending while a sequence or count is typed, nil if nothing fits
      def feed(token : String) : Fired | Symbol | Nil
        if @counts && @buffer.empty? && token.matches?(/\A[0-9]\z/) && (token != "0" || !@count.empty?)
          @count += token
          return :pending
        end
        had_pending = !@buffer.empty? || !@count.empty?
        if r = try(@buffer + [token])
          return r
        end
        reset
        if had_pending && (again = try([token]))
          return again
        end
        nil
      end

      private def try(buf : Array(String)) : Fired | Symbol | Nil
        id = buf.join('\0')
        if action = @exact[id]?
          count = @count.empty? ? nil : @count.to_i?
          reset
          return Fired.new(action, count)
        end
        if @prefixes.includes?(id)
          @buffer = buf
          return :pending
        end
        nil
      end
    end
  end
end
