require "log"
require "compress/zip"
require "http/client"
require "html"
require "json"
require "uri"
require "xml"
require "./meta_rules"
require "./covers"

module CalibreHub
  module Meta
    # Metadata in the book file itself: the EPUB's OPF and its first and
    # last pages (ISBN on the copyright page), or a PDF's info dict and
    # first pages (poppler's pdfinfo/pdftotext)
    module FileMeta
      # cover: the text of a PDF's first page (a standard's title page)
      record Info, record : Record, isbns : Array(String), cover : String? = nil

      MAX_TEXT = 300_000

      # nil when the file can't be read; the online sources still run.
      # Crystal's zip reader rejects entries with an invalid DOS timestamp
      # (seen in the wild), which calibre and readers don't mind.
      def self.read(path : String, format : String) : Info?
        case format.upcase
        when "EPUB" then epub(path)
        when "PDF"  then pdf(path)
        end
      rescue ex : ArgumentError | Compress::Zip::Error | XML::Error | IO::Error
        Log.warn { "metadata: can't read #{File.basename(path)}: #{ex.message}" }
        nil
      end

      def self.epub(path : String) : Info?
        Compress::Zip::File.open(path) do |zip|
          container = zip["META-INF/container.xml"]?.try { |e| e.open(&.gets_to_end) } || return nil
          opf_path = XML.parse(container).xpath_string("string(//*[local-name()='rootfile']/@full-path)").presence || return nil
          opf_xml = zip[opf_path]?.try { |e| e.open(&.gets_to_end) } || return nil
          record = opf(opf_xml)
          base = File.dirname(opf_path)
          pages = spine(opf_xml).map { |href| base == "." ? href : "#{base}/#{href}" }
          pages = (pages.first(6) + pages.last(3)).uniq
          text = String.build do |io|
            pages.each do |p|
              entry = zip[URI.decode(p)]? || zip[p]? || next
              io << strip_tags(entry.open(&.gets_to_end)) << '\n'
              break if io.bytesize > MAX_TEXT
            end
          end
          Info.new(record, Isbn.scan(text))
        end
      rescue ex : Compress::Zip::Error | XML::Error | IO::Error
        STDERR.puts "metadata: #{File.basename(path)}: #{ex.message}"
        nil
      end

      # dc:* and calibre's/EPUB 3 series metadata
      def self.opf(xml : String) : Record
        doc = XML.parse(xml)
        dc = ->(name : String) { doc.xpath_nodes("//*[local-name()='metadata']/*[local-name()='#{name}']").map(&.content.strip).reject(&.empty?) }
        meta = ->(name : String) { doc.xpath_string("string(//*[local-name()='meta'][@name='#{name}']/@content)").presence }
        isbn = doc.xpath_nodes("//*[local-name()='metadata']/*[local-name()='identifier']").compact_map do |n|
          scheme = n.attributes.find { |a| a.name == "scheme" }.try(&.content).to_s.downcase
          v = n.content.strip
          Isbn.normalize(v.sub(/\Aurn:isbn:/i, "")) if scheme == "isbn" || v.matches?(/\A(urn:)?isbn:/i) ||
                                                       (scheme.empty? && v.gsub(/[^0-9Xx]/, "").size.in?(10, 13))
        end.first?
        series = meta.call("calibre:series") ||
                 doc.xpath_string("string(//*[local-name()='meta'][@property='belongs-to-collection'])").strip.presence
        index = meta.call("calibre:series_index").try(&.to_f?) ||
                doc.xpath_string("string(//*[local-name()='meta'][@property='group-position'])").strip.to_f?
        creators = doc.xpath_nodes("//*[local-name()='metadata']/*[local-name()='creator']").select do |n|
          role = n.attributes.find { |a| a.name == "role" }.try(&.content)
          role.nil? || role == "aut"
        end.map(&.content.strip).reject(&.empty?)
        Record.new(
          title: dc.call("title").first?,
          authors: creators.empty? ? nil : creators,
          isbn: isbn,
          publisher: dc.call("publisher").first?,
          pubdate: dc.call("date").first?.try { |d| Dates.normalize(d) },
          languages: Lang.list(dc.call("language")).presence,
          comments: dc.call("description").first?,
          series: series,
          series_index: series ? index : nil,
        )
      end

      def self.spine(xml : String) : Array(String)
        doc = XML.parse(xml)
        hrefs = {} of String => String
        doc.xpath_nodes("//*[local-name()='manifest']/*[local-name()='item']").each do |n|
          id = n["id"]? || next
          hrefs[id] = n["href"]? || next
        end
        doc.xpath_nodes("//*[local-name()='spine']/*[local-name()='itemref']").compact_map { |n| n["idref"]?.try { |i| hrefs[i]? } }
      end

      def self.strip_tags(html : String) : String
        HTML.unescape(html.gsub(/<(script|style)\b.*?<\/\1>/im, " ").gsub(/<[^>]*>/, " ")).gsub(/\s+/, " ")
      end

      def self.pdf(path : String) : Info?
        info = run("pdfinfo", [path]) || return nil
        text = run("pdftotext", ["-l", "6", "-enc", "UTF-8", path, "-"]) || ""
        Info.new(pdf_info(info), Isbn.scan(text[0, MAX_TEXT]? || text), text.split('\f', 2).first.presence)
      end

      # pdfinfo's "Key: value" lines; "Microsoft Word - x.doc" titles and
      # tools as authors are dropped
      def self.pdf_info(text : String) : Record
        fields = {} of String => String
        text.each_line do |l|
          k, _, v = l.partition(':')
          fields[k.strip] = v.strip unless v.strip.empty?
        end
        title = fields["Title"]?.try { |t| Clean.strip_junk(t) }.presence
        title = nil if title && title.matches?(/\A(?:untitled|unbenannt|document|dokument\d*)\z/i)
        author = fields["Author"]?.presence
        author = nil if author && Clean.unknown_author?(author)
        Record.new(title: title, authors: author.try { |a| Clean.split_authors(a) })
      end

      private def self.run(cmd : String, args : Array(String)) : String?
        output = IO::Memory.new
        status = Process.run(cmd, args, output: output, error: Process::Redirect::Close)
        status.success? ? output.to_s : nil
      rescue File::NotFoundError | IO::Error
        nil
      end
    end

    # A provider didn't answer; the book is tried again on the next run
    class SourceError < Exception
    end

    # GET with timeouts, a User-Agent and a minimum interval per host, so a
    # run over 10,000 books stays polite
    class Http
      def initialize(@interval : Time::Span = 1.second, @timeout : Time::Span = 15.seconds)
        @last = {} of String => Time::Instant
        @mutex = Mutex.new
      end

      # nil on 404
      def get(url : String, accept = "application/json") : String?
        uri = URI.parse(url)
        wait(uri.host.to_s)
        client = HTTP::Client.new(uri)
        client.connect_timeout = 5.seconds
        client.read_timeout = @timeout
        r = client.get(uri.request_target, headers: HTTP::Headers{"Accept" => accept, "User-Agent" => "calibre-hub/0.1 (private library)"})
        return nil if r.status_code == 404
        raise SourceError.new("#{uri.host}: HTTP #{r.status_code}") unless r.success?
        r.body
      rescue ex : IO::Error | Socket::Error | OpenSSL::Error
        raise SourceError.new("#{uri.try(&.host)}: #{ex.message}")
      ensure
        client.try &.close
      end

      # image bytes, nil when there is none
      def image(url : String) : Bytes?
        uri = URI.parse(url)
        wait(uri.host.to_s)
        client = HTTP::Client.new(uri)
        client.connect_timeout = 5.seconds
        client.read_timeout = @timeout
        client.get(uri.request_target, headers: HTTP::Headers{"User-Agent" => "calibre-hub/0.1 (private library)"}) do |r|
          next nil unless r.success?
          buf = IO::Memory.new
          IO.copy(r.body_io, buf, Covers::MAX_BYTES + 1)
          next nil if buf.size > Covers::MAX_BYTES
          buf.to_slice
        end
      rescue ex : IO::Error | Socket::Error | OpenSSL::Error
        raise SourceError.new("#{uri.try(&.host)}: #{ex.message}")
      ensure
        client.try &.close
      end

      private def wait(host : String)
        return if @interval.zero?
        @mutex.synchronize do
          if last = @last[host]?
            pause = @interval - (Time.instant - last)
            sleep pause if pause > Time::Span.zero
          end
          @last[host] = Time.instant
        end
      end
    end

    # Open Library: an edition by ISBN (books API), works by title and
    # author (search API); descriptions from the work
    class OpenLibrary
      NAME = "openlibrary"

      def initialize(@http : Http, @base = "https://openlibrary.org", @covers = "https://covers.openlibrary.org")
        @base = @base.rstrip('/')
        @covers = @covers.rstrip('/')
      end

      def by_isbn(isbn : String) : Array(Candidate)
        body = @http.get("#{@base}/api/books?" + URI::Params.encode({"bibkeys" => "ISBN:#{isbn}", "format" => "json", "jscmd" => "data"})) || return [] of Candidate
        OpenLibrary.parse_books(body, isbn, @base, @covers)
      end

      def search(title : String, author : String?) : Array(Candidate)
        params = {"title" => title, "fields" => "key,title,author_name,publisher,first_publish_year,language,isbn,cover_i", "limit" => "5"}
        author.try { |a| params["author"] = a }
        body = @http.get("#{@base}/search.json?" + URI::Params.encode(params)) || return [] of Candidate
        OpenLibrary.parse_search(body, @base, @covers)
      end

      # Description and languages of the edition's work (one more request)
      def complete(c : Candidate)
        return unless c.fields.comments.nil?
        key = c.ref || return
        if key.starts_with?("/books/")
          edition = @http.get("#{@base}#{key}.json").try { |b| JSON.parse(b) } || return
          c.fields.languages ||= Lang.list(edition["languages"]?.try(&.as_a.compact_map { |l| l["key"]?.try(&.as_s?).try(&.split('/').last) }) || [] of String).presence
          c.fields.series ||= edition["series"]?.try(&.as_a.first?).try(&.as_s?).try { |s| s.sub(/\s*[;,]?\s*(?:no\.|nr\.|#|band|bd\.)?\s*\d+\s*\z/i, "").strip.presence }
          key = edition["works"]?.try(&.as_a.first?).try(&.["key"]?).try(&.as_s?) || return
        end
        work = @http.get("#{@base}#{key}.json") || return
        c.fields.comments = OpenLibrary.description(work)
      end

      def self.parse_books(body : String, isbn : String, base : String, covers : String) : Array(Candidate)
        JSON.parse(body).as_h.values.compact_map do |b|
          ids = b["identifiers"]?
          found = (ids.try(&.["isbn_13"]?).try(&.as_a) || [] of JSON::Any).compact_map { |i| Isbn.normalize(i.as_s) }.first? ||
                  (ids.try(&.["isbn_10"]?).try(&.as_a) || [] of JSON::Any).compact_map { |i| Isbn.normalize(i.as_s) }.first? || isbn
          cover = b["cover"]?.try(&.["large"]?).try(&.as_s?).try { |u| cover_url(u, covers) }
          r = Record.new(
            title: b["title"]?.try(&.as_s?).try { |t| Text.main_title(t) },
            authors: b["authors"]?.try(&.as_a.compact_map { |a| a["name"]?.try(&.as_s?) }).presence,
            isbn: found,
            publisher: b["publishers"]?.try(&.as_a.first?).try(&.["name"]?).try(&.as_s?),
            pubdate: b["publish_date"]?.try(&.as_s?).try { |d| Dates.normalize(d) },
            cover_url: cover,
          )
          key = b["key"]?.try(&.as_s?)
          Candidate.new(NAME, r, key.try { |k| "#{base}#{k}" }, by_isbn: isbn, ref: key)
        end
      end

      def self.parse_search(body : String, base : String, covers : String) : Array(Candidate)
        (JSON.parse(body)["docs"]?.try(&.as_a) || [] of JSON::Any).map do |d|
          strings = ->(k : String) { d[k]?.try(&.as_a.compact_map(&.as_s?)) || [] of String }
          isbns = strings.call("isbn").compact_map { |i| Isbn.normalize(i) }.uniq
          publishers = strings.call("publisher").uniq
          languages = Lang.list(strings.call("language"))
          r = Record.new(
            title: d["title"]?.try(&.as_s?).try { |t| Text.main_title(t) },
            authors: strings.call("author_name").presence,
            # a work has many editions: their ISBN and publisher only when there is one
            isbn: isbns.size == 1 ? isbns.first : nil,
            publisher: publishers.size == 1 ? publishers.first : nil,
            pubdate: d["first_publish_year"]?.try(&.as_i?).try(&.to_s),
            languages: languages.size == 1 ? languages : nil,
            cover_url: d["cover_i"]?.try(&.as_i64?).try { |id| "#{covers}/b/id/#{id}-L.jpg?default=false" },
          )
          key = d["key"]?.try(&.as_s?)
          Candidate.new(NAME, r, key.try { |k| "#{base}#{k}" }, edition: isbns.size == 1, ref: key)
        end
      end

      # string or {"type": "/type/text", "value": "..."}; Markdown-ish
      # text becomes paragraphs
      def self.description(body : String) : String?
        d = JSON.parse(body)["description"]? || return nil
        text = (d.as_s? || d["value"]?.try(&.as_s?)).try(&.strip).presence || return nil
        # links and quotes of other people's comments are not the blurb
        text = text.gsub(/\[([^\]]*)\]\([^)]*\)/, "\\1").gsub(/^>\s?/m, "")
        text.split(/(?:\r?\n){2,}/).map { |p| "<p>#{HTML.escape(p.strip.gsub(/\s+/, " "))}</p>" }.join
      end

      private def self.cover_url(url : String, covers : String) : String
        (m = url.match(/\/b\/id\/(\d+)/)) ? "#{covers}/b/id/#{m[1]}-L.jpg?default=false" : url
      end
    end

    # Deutsche Nationalbibliothek over SRU, MARC21-xml, no API key. Good
    # for German books; publisher series (Taschenbuch numbers) are dropped.
    class Dnb
      NAME = "dnb"

      def initialize(@http : Http, @base = "https://services.dnb.de/sru/dnb")
        @base = @base.rstrip('/')
      end

      def by_isbn(isbn : String) : Array(Candidate)
        query("num=#{isbn}").tap(&.each { |c| c.by_isbn = isbn })
      end

      def search(title : String, author : String?) : Array(Candidate)
        q = %(tit="#{title.gsub('"', "")}")
        author.try { |a| q += %( and per="#{a.gsub('"', "")}") }
        query(q)
      end

      private def query(cql : String) : Array(Candidate)
        params = {"version" => "1.1", "operation" => "searchRetrieve", "query" => cql,
                  "recordSchema" => "MARC21-xml", "maximumRecords" => "10"}
        body = @http.get("#{@base}?" + URI::Params.encode(params), "application/xml") || return [] of Candidate
        Dnb.parse(body)
      end

      # 245 title, 100/700 authors, 020 ISBN, 264/260 publisher and year,
      # 041 language, 490 series, 520 summary
      def self.parse(xml : String) : Array(Candidate)
        doc = XML.parse(xml)
        doc.xpath_nodes("//*[local-name()='record'][*[local-name()='leader']]").compact_map do |rec|
          sub = ->(tag : String, code : String) do
            rec.xpath_nodes("*[local-name()='datafield'][@tag='#{tag}']/*[local-name()='subfield'][@code='#{code}']").map { |n| clean(n.content) }.reject(&.empty?)
          end
          title = sub.call("245", "a").first? || next
          parts = sub.call("245", "n") + sub.call("245", "p")
          title = ([title] + parts).join(". ") unless parts.empty?
          authors = sub.call("100", "a")
          rec.xpath_nodes("*[local-name()='datafield'][@tag='700']").each do |f|
            roles = f.xpath_nodes("*[local-name()='subfield'][@code='4']").map(&.content)
            name = f.xpath_string("string(*[local-name()='subfield'][@code='a'])")
            authors << clean(name) if roles.includes?("aut") && !name.empty?
          end
          publisher = (sub.call("264", "b") + sub.call("260", "b")).first?
          year = (sub.call("264", "c") + sub.call("260", "c")).first?.try { |d| Dates.normalize(d) }
          languages = Lang.list(sub.call("041", "a"))
          if languages.empty?
            f008 = rec.xpath_string("string(*[local-name()='controlfield'][@tag='008'])")
            Lang.normalize(f008[35, 3]? || "").try { |l| languages << l }
          end
          series = sub.call("490", "a").first?
          index = sub.call("490", "v").first?.try { |v| v[/\d+(?:[.,]\d+)?/]?.try(&.sub(',', '.').to_f?) }
          # "Fischer 16453", "Pocket 7380": the publisher's numbering
          if series && (index.try { |i| i >= 100 } || (publisher && !(Text.tokens(series).to_set & Text.tokens(publisher).to_set).empty?))
            series = index = nil
          end
          id = rec.xpath_string("string(*[local-name()='controlfield'][@tag='001'])").presence
          r = Record.new(
            title: title,
            authors: authors.map { |a| Clean.invert(a) }.uniq.presence,
            isbn: sub.call("020", "a").compact_map { |i| Isbn.normalize(i) }.first?,
            publisher: publisher,
            pubdate: year,
            languages: languages.presence,
            comments: sub.call("520", "a").first?.try { |s| "<p>#{HTML.escape(s)}</p>" },
            series: series,
            series_index: series ? index : nil,
          )
          Candidate.new(NAME, r, id.try { |i| "https://d-nb.info/#{i}" })
        end
      end

      # non-sorting markers (U+0098/U+009C), trailing ISBD punctuation
      private def self.clean(s : String) : String
        s.delete("\u0098\u009C").unicode_normalize.strip.rstrip(" /:;,=").strip
      end
    end
  end
end
