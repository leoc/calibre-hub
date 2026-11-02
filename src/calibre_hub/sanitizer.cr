require "xml"
require "html"

module CalibreHub
  # Allowlist cleaner for book comments: known tags stay (without attributes,
  # except a safe href on links), unknown tags are unwrapped, script-like
  # tags go with their content.
  module Sanitizer
    ALLOWED = %w(p br b strong i em u s ul ol li blockquote h1 h2 h3 h4 h5 h6 a span div)
    DROPPED = %w(script style iframe object embed template noscript svg math head title form textarea select)
    VOID    = %w(br)
    HREF    = /\A(https?:|mailto:)/i

    def self.clean(html : String) : String
      return "" if html.strip.empty?
      doc = XML.parse_html("<!DOCTYPE html><html><body>#{html}</body></html>")
      body = doc.xpath_node("//body") || return ""
      String.build { |io| children(body, io) }.strip
    end

    private def self.children(node : XML::Node, io : IO)
      node.children.each { |child| emit(child, io) }
    end

    private def self.emit(node : XML::Node, io : IO)
      if node.text? || node.cdata?
        io << HTML.escape(node.content)
      elsif node.element?
        name = node.name.downcase
        return if DROPPED.includes?(name)
        unless ALLOWED.includes?(name)
          children(node, io)
          return
        end
        io << '<' << name
        if name == "a" && (href = node["href"]?.try(&.strip)) && href.matches?(HREF)
          io << %( href=") << HTML.escape(href) << %(" rel="noopener noreferrer")
        end
        io << '>'
        return if VOID.includes?(name)
        children(node, io)
        io << "</" << name << '>'
      end
    end
  end
end
