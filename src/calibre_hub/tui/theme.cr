require "bubbletea"

module CalibreHub
  module Tui
    # Colours that follow the terminal background (light or dark), close to
    # the web app's theme: neutral text, muted secondary text, one accent.
    module Theme
      alias C = Lipgloss::AdaptiveColor

      TEXT    = C.new(light: "#1f2328", dark: "#e6e6e6")
      MUTED   = C.new(light: "#6b7280", dark: "#9ca3af")
      ACCENT  = C.new(light: "#4f46e5", dark: "#a5b4fc")
      CURSOR  = C.new(light: "#e0e7ff", dark: "#312e81")
      DIMSEL  = C.new(light: "#eeeeee", dark: "#30343b")
      BORDER  = C.new(light: "#d1d5db", dark: "#4b5563")
      ERROR   = C.new(light: "#b91c1c", dark: "#fca5a5")
      CHIP_BG = C.new(light: "#eef2ff", dark: "#272a4a")

      alias S = Lipgloss::Style

      def self.text : S
        S.new.foreground(TEXT)
      end

      def self.muted : S
        S.new.foreground(MUTED)
      end

      def self.accent : S
        S.new.foreground(ACCENT)
      end

      def self.title : S
        S.new.foreground(ACCENT).bold
      end

      def self.header : S
        S.new.foreground(MUTED).bold
      end

      def self.cursor(focused : Bool) : S
        S.new.background(focused ? CURSOR : DIMSEL).foreground(TEXT)
      end

      def self.chip : S
        S.new.background(CHIP_BG).foreground(ACCENT).padding(0, 1)
      end

      def self.error : S
        S.new.foreground(ERROR).bold
      end

      def self.border : S
        S.new.foreground(BORDER)
      end

      def self.cover : S
        S.new.border(:rounded).border_foreground(BORDER).foreground(MUTED).align(:center, :center)
      end
    end
  end
end
