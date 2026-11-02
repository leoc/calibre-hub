require "html"

module CalibreHub
  module Tui
    # Book descriptions (calibre stores HTML, sometimes plain text) as
    # Markdown for Glamour. Knows the tags descriptions use: paragraphs,
    # breaks, emphasis, headings, lists, links; drops the rest.
    module Markdown
      def self.from_html(html : String) : String
        return plain(html) unless html.matches?(/<[a-z!\/][^>]*>/i)
        acc = String::Builder.new
        lists = [] of {Bool, Int32} # ordered?, counter
        link : String? = nil
        html.scan(/<!--.*?-->|<[^>]*>|[^<]+/m) do |m|
          tok = m[0]
          if tok.starts_with?("<!--")
            next
          elsif tok.starts_with?('<')
            closing = tok.starts_with?("</")
            name = tok.match(/\A<\/?\s*([a-z0-9]+)/i).try(&.[1].downcase) || next
            case name
            when "p", "div", "section", "article", "table", "tr", "blockquote"
              acc << "\n\n"
            when "br"
              acc << "  \n"
            when "b", "strong"
              acc << "**"
            when "i", "em", "cite"
              acc << "*"
            when "h1", "h2", "h3", "h4", "h5", "h6"
              acc << (closing ? "\n\n" : "\n\n#{"#" * name[1].to_i} ")
            when "ul", "ol"
              if closing
                lists.pop?
              else
                lists << {name == "ol", 0}
              end
              acc << "\n\n"
            when "li"
              next if closing
              ordered, n = lists.last? || {false, 0}
              lists[-1] = {ordered, n + 1} unless lists.empty?
              indent = "  " * Math.max(0, lists.size - 1)
              acc << "\n" << indent << (ordered ? "#{n + 1}. " : "- ")
            when "a"
              if closing
                acc << "](#{link})" if link
                link = nil
              elsif href = tok.match(/href\s*=\s*["']([^"']+)["']/i).try(&.[1])
                if href.starts_with?("http")
                  link = HTML.unescape(href)
                  acc << "["
                end
              end
            when "hr"
              acc << "\n\n---\n\n"
            end
          else
            acc << escape(HTML.unescape(tok).gsub(/\s+/, " "))
          end
        end
        tidy(acc.to_s)
      end

      # plain text: blank lines separate paragraphs, single newlines stay
      def self.plain(text : String) : String
        tidy(text.split(/\n\s*\n/).map { |para| para.strip.split('\n').map { |l| escape(l.strip) }.join("  \n") }.join("\n\n"))
      end

      private def self.escape(text : String) : String
        text.gsub(/([\\`*_\[\]])/) { "\\#{$1}" }.sub(/\A(\s*)([#>+-]|\d+\.)(\s)/) { "#{$1}\\#{$2}#{$3}" }
      end

      private def self.tidy(md : String) : String
        md.gsub(/[ \t]+\n(?!\n)/) { |s| s.ends_with?("  \n") ? "  \n" : "\n" }
          .gsub(/\n[ \t]+\n/, "\n\n")
          .gsub(/\n{3,}/, "\n\n")
          .gsub(/\*\*\s*\*\*/, "")
          .strip
      end
    end
  end
end
