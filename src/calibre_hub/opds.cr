require "xml"
require "html"
require "./book"
require "./lists"

module CalibreHub
  # OPDS 1.2 catalogs of the reading lists, for reader apps (Basic auth
  # like calibre's /opds): /opds/lists is a navigation feed of the lists the
  # user sees, /opds/lists/:id an acquisition feed of one list, most recently
  # added first. Files and covers link to calibre's /get/*, which the hub
  # passes through.
  module Opds
    NAV       = "application/atom+xml;profile=opds-catalog;kind=navigation"
    ACQ       = "application/atom+xml;profile=opds-catalog;kind=acquisition"
    PAGE_SIZE = 100
    MIME      = {
      "EPUB"  => "application/epub+zip",
      "KEPUB" => "application/kepub+zip",
      "PDF"   => "application/pdf",
      "AZW3"  => "application/x-mobi8-ebook",
      "MOBI"  => "application/x-mobipocket-ebook",
      "CBZ"   => "application/vnd.comicbook+zip",
      "CBR"   => "application/vnd.comicbook-rar",
      "FB2"   => "application/x-fictionbook+xml",
      "TXT"   => "text/plain",
    }
    # offered first: what readers open best
    ORDER = %w(EPUB KEPUB AZW3 MOBI PDF CBZ CBR FB2 TXT)

    def self.lists_feed(lists : Array(Lists::List), now = Time.utc) : String
      feed("urn:calibre-hub:lists", "Listen", now, "/opds/lists", NAV) do |x|
        lists.each do |l|
          x.element("entry") do
            x.element("title") { x.text l.name }
            x.element("id") { x.text "urn:calibre-hub:list:#{l.id}" }
            x.element("updated") { x.text (l.last_used_at || l.updated_at).to_rfc3339 }
            x.element("content", type: "text") do
              x.text [l.description.presence, "#{l.count} #{l.count == 1 ? "Buch" : "Bücher"}"].compact.join(" · ")
            end
            x.element("link", rel: "subsection", href: "/opds/lists/#{l.id}", type: ACQ)
          end
        end
      end
    end

    # books: the page, in list order; library: calibre's library path suffix
    def self.list_feed(list : Lists::List, books : Array(Book), offset : Int32, total : Int32,
                       library : String, now = Time.utc) : String
      self_href = "/opds/lists/#{list.id}#{offset > 0 ? "?offset=#{offset}" : ""}"
      feed("urn:calibre-hub:list:#{list.id}", list.name, now, self_href, ACQ, list.description.presence) do |x|
        x.element("link", rel: "up", href: "/opds/lists", type: NAV)
        if offset + books.size < total
          x.element("link", rel: "next", href: "/opds/lists/#{list.id}?offset=#{offset + books.size}", type: ACQ)
        end
        if offset > 0
          x.element("link", rel: "previous", href: "/opds/lists/#{list.id}?offset=#{Math.max(0, offset - PAGE_SIZE)}", type: ACQ)
        end
        books.each { |b| entry(x, b, library) }
      end
    end

    private def self.entry(x : XML::Builder, b : Book, library : String)
      x.element("entry") do
        x.element("title") { x.text b.title }
        x.element("id") { x.text "urn:calibre-hub:book:#{b.id}" }
        x.element("updated") { x.text b.last_modified.to_utc.to_rfc3339 }
        b.authors.each { |a| x.element("author") { x.element("name") { x.text a } } }
        b.languages.each { |l| x.element("dc:language") { x.text l } }
        b.publisher.try { |p| x.element("dc:publisher") { x.text p } }
        b.pubdate.try { |d| x.element("dc:issued") { x.text d.to_s("%Y-%m-%d") } }
        b.series.try do |s|
          idx = b.series_index.try { |i| i == i.floor ? i.to_i.to_s : i.to_s }
          x.element("category", term: s, label: idx ? "#{s} #{idx}" : s)
        end
        b.comments.try { |c| x.element("summary") { x.text plain(c) } }
        formats = b.formats.sort_by { |f| ORDER.index(f) || ORDER.size }
        formats.each do |f|
          x.element("link", rel: "http://opds-spec.org/acquisition", href: "/get/#{f.downcase}/#{b.id}#{library}",
            type: MIME[f]? || "application/octet-stream", title: f)
        end
        x.element("link", rel: "http://opds-spec.org/image", href: "/get/cover/#{b.id}#{library}", type: "image/jpeg")
        x.element("link", rel: "http://opds-spec.org/image/thumbnail", href: "/get/thumb/#{b.id}#{library}?sz=300x400", type: "image/jpeg")
      end
    end

    def self.plain(html : String) : String
      HTML.unescape(html.gsub(/<br\s*\/?>|<\/p>/i, "\n").gsub(/<[^>]*>/, "")).strip
    end

    private def self.feed(id : String, title : String, now : Time, self_href : String, kind : String,
                          subtitle : String? = nil, &)
      XML.build(indent: "  ", encoding: "UTF-8") do |x|
        x.element("feed", xmlns: "http://www.w3.org/2005/Atom", "xmlns:dc": "http://purl.org/dc/terms/",
          "xmlns:opds": "http://opds-spec.org/2010/catalog") do
          x.element("id") { x.text id }
          x.element("title") { x.text title }
          subtitle.try { |s| x.element("subtitle") { x.text s } }
          x.element("updated") { x.text now.to_rfc3339 }
          x.element("author") { x.element("name") { x.text "calibre-hub" } }
          x.element("link", rel: "self", href: self_href, type: kind)
          x.element("link", rel: "start", href: "/opds", type: NAV)
          yield x
        end
      end
    end
  end
end
