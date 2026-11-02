require "log"
require "base64"
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

    # What a title search knows about the book. languages: the book's (or
    # the file's), empty when unknown
    record Query, title : String, author : String?, languages : Array(String) = [] of String,
      publisher : String? = nil

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

      # POST of a JSON body: {status, body}; the caller decides what a
      # status means
      def post(url : String, body : String, headers = HTTP::Headers.new) : {Int32, String}
        uri = URI.parse(url)
        wait(uri.host.to_s)
        client = HTTP::Client.new(uri)
        client.connect_timeout = 5.seconds
        client.read_timeout = @timeout
        headers = headers.dup
        headers["Content-Type"] = "application/json"
        headers["Accept"] = "application/json"
        headers["User-Agent"] = "calibre-hub/0.1 (private library)"
        r = client.post(uri.request_target, headers: headers, body: body)
        {r.status_code, r.body}
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

      def search(q : Query) : Array(Candidate)
        params = {"title" => q.title, "fields" => "key,title,author_name,publisher,first_publish_year,language,isbn,cover_i", "limit" => "5"}
        q.author.try { |a| params["author"] = a }
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
    # for German books, but it has English books mostly as their German
    # translations: a title search only for German books, always with the
    # author and the language. Publisher series (Taschenbuch numbers) are
    # dropped.
    class Dnb
      NAME = "dnb"

      def initialize(@http : Http, @base = "https://services.dnb.de/sru/dnb")
        @base = @base.rstrip('/')
      end

      def by_isbn(isbn : String) : Array(Candidate)
        query("num=#{isbn}").tap(&.each { |c| c.by_isbn = isbn })
      end

      # nil when the DNB isn't asked: not a German book, or no author
      def self.cql(q : Query) : String?
        author = q.author.presence || return nil
        return nil unless Lang.german?(q.languages, q.title)
        # per= with the surname finds "McKeown, Greg" and "Greg McKeown"
        per = author.split(/\s+/).last.gsub('"', "")
        %(tit="#{q.title.gsub('"', "")}" and per="#{per}" and spr=#{Lang.marc("deu")})
      end

      def search(q : Query) : Array(Candidate)
        cql = Dnb.cql(q) || return [] of Candidate
        query(cql)
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
          # "Vol. 2. / Aufgeschrieben, rev. u. ...": the statement of
          # responsibility after " / " goes
          parts = (sub.call("245", "n") + sub.call("245", "p")).map { |x| clean(x.split(" / ", 2).first).rstrip(".").strip }.reject(&.empty?)
          title = ([title] + parts).join(". ") unless parts.empty?
          volume = parts.compact_map { |x| Text.volume(x) || x[/\A\d+\z/]? }.first?
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
          # a translation: the original's language (041 h), its title (240)
          # or a translator (700 $4 trl)
          translation = !sub.call("041", "h").empty? || !sub.call("240", "a").empty? ||
                        rec.xpath_nodes("*[local-name()='datafield'][@tag='700']/*[local-name()='subfield'][@code='4']").any? { |n| n.content.strip == "trl" }
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
          Candidate.new(NAME, r, id.try { |i| "https://d-nb.info/#{i}" }).tap do |c|
            c.translation = translation
            c.volume = volume
          end
        end
      end

      # non-sorting markers (U+0098/U+009C), trailing ISBD punctuation
      private def self.clean(s : String) : String
        s.delete("\u0098\u009C").unicode_normalize.strip.rstrip(" /:;,=").strip
      end
    end

    # Hardcover (GraphQL, a personal API token), for English books. An
    # edition by ISBN; a title search only with the author, both very
    # similar, and only when the work has an edition in the book's
    # language. Good for descriptions, subtitles and author spellings; weak
    # for years and publishers, so the work's release_year is never used
    # and the publisher only comes from an edition. A rejected token pauses
    # the source for an hour (the rest of a run) and raises an alert.
    class Hardcover
      NAME = "hardcover"
      URL  = "https://api.hardcover.app/v1/graphql"
      # after a rejected token
      PAUSE = 1.hour
      # alert this long before a JWT token expires
      EXPIRY_WARNING = 14.days

      # key, subject, text; the receiver sends each key at most once a day
      alias Alert = Proc(String, String, String, Nil)

      EDITION      = "id title subtitle isbn_13 isbn_10 release_date publisher { name } language { code3 }"
      BOOK         = "id slug title subtitle description contributions { author { name } contribution } book_series { position series { name } }"
      ISBN_QUERY   = "query($isbn: String!) { editions(where: {_or: [{isbn_13: {_eq: $isbn}}, {isbn_10: {_eq: $isbn}}]}, limit: 5) { #{EDITION} book { #{BOOK} } } }"
      SEARCH_QUERY = %(query($q: String!) { search(query: $q, query_type: "Book", per_page: 10, page: 1) { results } })
      BOOKS_QUERY  = "query($ids: [Int!]) { books(where: {id: {_in: $ids}}) { #{BOOK} editions(order_by: {users_count: desc}, limit: 50) { #{EDITION} } } }"
      # placeholder entries for announced books ("Untitled" by Rebecca Yarros)
      PLACEHOLDERS = Set{"untitled", "unknown", "tba", "tbd", "titletbd", "untitlednovel", "book"}
      # books about a book: summaries, workbooks, study guides
      COMPANIONS = /\b(?:summary|summaries|workbook|study guide|analysis|companion|key takeaways)\b/i

      getter paused_until : Time?

      def initialize(@http : Http, token : String?, @url = URL, @alert : Alert? = nil)
        @url = @url.rstrip('/')
        # the token page shows it as "Bearer ..."
        @token = token.try(&.strip.sub(/\ABearer\s+/i, "").presence).as(String?)
        @expiry_checked = nil.as(Time?)
      end

      def enabled? : Bool
        !@token.nil?
      end

      # a token, not paused; warns once a day when the token expires soon
      def available?(now = Time.utc) : Bool
        return false unless @token
        check_expiry(now)
        (p = @paused_until).nil? || now >= p
      end

      def by_isbn(isbn : String) : Array(Candidate)
        return [] of Candidate unless available?
        data = request(ISBN_QUERY, {"isbn" => isbn}) || return [] of Candidate
        Hardcover.parse_editions(data, isbn)
      end

      def search(q : Query) : Array(Candidate)
        return [] of Candidate unless available? && q.author.presence
        found = request(SEARCH_QUERY, {"q" => "#{q.title} #{q.author}"}) || return [] of Candidate
        ids = Hardcover.hits(found, q).first(3)
        return [] of Candidate if ids.empty?
        data = request(BOOKS_QUERY, {"ids" => ids}) || return [] of Candidate
        Hardcover.parse_books(data, q, ids)
      end

      private def request(query : String, variables) : JSON::Any?
        token = @token || return nil
        status, body = @http.post(@url, {query: query, variables: variables}.to_json,
          HTTP::Headers{"Authorization" => "Bearer #{token}"})
        if status.in?(401, 403)
          rejected("HTTP #{status}")
          return nil
        end
        raise SourceError.new("hardcover: HTTP #{status}") unless 200 <= status < 300
        json = JSON.parse(body)
        if errors = json["errors"]?.try(&.as_a?)
          message = errors.compact_map { |e| e["message"]?.try(&.as_s?) }.join("; ")
          if message.matches?(/jwt|token|unauthori[sz]ed|access[- ]denied/i)
            rejected(message)
            return nil
          end
          raise SourceError.new("hardcover: #{message}")
        end
        json["data"]?
      end

      private def rejected(reason : String)
        @paused_until = Time.utc + PAUSE
        STDERR.puts "metadata: hardcover rejected the token (#{reason}), source paused for #{PAUSE.total_minutes.to_i} minutes"
        @alert.try &.call("hardcover-token", "calibre-hub: Hardcover-Token abgelaufen oder ungültig",
          "Hardcover lehnt den API-Token ab (#{reason}). Die Metadaten-Quelle Hardcover ist ausgesetzt, " \
          "die anderen Quellen laufen weiter. Neuen Token unter https://hardcover.app/account/api holen, " \
          "in die Datei von services.calibre-hub.metadata.hardcoverTokenFile schreiben und calibre-hub neu starten.")
      end

      private def check_expiry(now : Time)
        return if (c = @expiry_checked) && now - c < 1.hour
        @expiry_checked = now
        exp = @token.try { |t| Hardcover.expiry(t) } || return
        return if exp - now > EXPIRY_WARNING
        day = exp.in(Time::Location.load_local).to_s("%d.%m.%Y")
        text = exp > now ? "läuft am #{day} ab" : "ist am #{day} abgelaufen"
        @alert.try &.call("hardcover-token-expiry", "calibre-hub: Hardcover-Token #{exp > now ? "läuft bald ab" : "abgelaufen"}",
          "Der Hardcover-API-Token #{text}. Neuen Token unter https://hardcover.app/account/api holen, " \
          "in die Datei von services.calibre-hub.metadata.hardcoverTokenFile schreiben und calibre-hub neu starten.")
      end

      # exp of a JWT token, read without verifying; nil for other tokens
      def self.expiry(token : String) : Time?
        parts = token.split('.')
        return nil unless parts.size == 3
        payload = parts[1] + "=" * ((4 - parts[1].size % 4) % 4)
        exp = JSON.parse(Base64.decode_string(payload))["exp"]?
        exp.try { |e| e.as_i64? || e.as_f?.try(&.to_i64) }.try { |e| Time.unix(e) }
      rescue Base64::Error | JSON::ParseException | ArgumentError | TypeCastError
        nil
      end

      # Search hits worth a look: very similar title, the same author, no
      # placeholder or book about the book; their ids, best first
      def self.hits(data : JSON::Any, q : Query) : Array(Int64)
        author = q.author || return [] of Int64
        hits = data["search"]?.try(&.["results"]?).try(&.["hits"]?).try(&.as_a?) || return [] of Int64
        hits.compact_map do |h|
          doc = h["document"]? || next
          title = doc["title"]?.try(&.as_s?) || next
          next if PLACEHOLDERS.includes?(Text.key(Text.main_title(title)))
          next if title.matches?(COMPANIONS) && !q.title.matches?(COMPANIONS)
          next if Text.similarity(q.title, title) < 0.9
          names = doc["author_names"]?.try(&.as_a?.try(&.compact_map(&.as_s?))) || [] of String
          next if names.empty? || Score.authors([author], names) < 0.8
          id = doc["id"]?
          id.try { |i| i.as_s?.try(&.to_i64?) || i.as_i64? }
        end.uniq
      end

      def self.parse_editions(data : JSON::Any, isbn : String) : Array(Candidate)
        editions = data["editions"]?.try(&.as_a?) || return [] of Candidate
        editions.compact_map do |e|
          book = e["book"]?
          next unless book && book.as_h?
          Candidate.new(NAME, record(book, e), url(book), by_isbn: isbn)
        end.uniq(&.url).first(1)
      end

      # The works of the search hits with an edition in the book's language
      # (unknown: German for a German-looking title, else English). The
      # edition's ISBN, publisher and date only when it is clear which one
      # it is: the only one, or the only one of the book's publisher.
      def self.parse_books(data : JSON::Any, q : Query, ids : Array(Int64)) : Array(Candidate)
        books = data["books"]?.try(&.as_a?) || return [] of Candidate
        wanted = q.languages.presence || (Lang.german_title?(q.title) ? ["deu"] : ["eng"])
        books = books.sort_by { |b| ids.index(b["id"]?.try(&.as_i64?) || 0_i64) || ids.size }
        books.compact_map do |b|
          editions = b["editions"]?.try(&.as_a?) || [] of JSON::Any
          own = editions.select { |e| !(edition_languages(e) & wanted).empty? }
          next if own.empty?
          with_isbn = own.select { |e| isbn(e) }
          same_publisher = q.publisher.try { |p| with_isbn.select { |e| publisher(e).try { |x| Text.similarity(x, p) >= 0.5 } } } || [] of JSON::Any
          edition = same_publisher.size == 1 ? same_publisher.first : (with_isbn.size == 1 ? with_isbn.first : nil)
          r = record(b, edition || own.first)
          unless edition
            r.isbn = r.publisher = r.pubdate = nil
          end
          Candidate.new(NAME, r, url(b), edition: !edition.nil?)
        end
      end

      def self.record(book : JSON::Any, edition : JSON::Any) : Record
        title = str(book, "title") || str(edition, "title")
        series = book["book_series"]?.try(&.as_a?).try(&.first?)
        Record.new(
          title: title.try { |t| Text.main_title(t) },
          subtitle: str(book, "subtitle"),
          authors: authors(book).presence,
          isbn: isbn(edition),
          publisher: publisher(edition),
          # "2021-01-01" stands for an edition of 2021
          pubdate: str(edition, "release_date").try { |d| Dates.normalize(d) }.try { |d| d.ends_with?("-01-01") ? d[0, 4] : d },
          languages: edition_languages(edition).presence,
          comments: str(book, "description").try { |d| description(d) },
          series: series.try { |s| s["series"]?.try { |x| str(x, "name") } },
          series_index: series.try { |s| s["position"]?.try { |p| p.as_f? || p.as_i64?.try(&.to_f) } },
        )
      end

      # contributions without a role or as "Author" (not translators)
      def self.authors(book : JSON::Any) : Array(String)
        (book["contributions"]?.try(&.as_a?) || [] of JSON::Any).compact_map do |c|
          role = c["contribution"]?.try(&.as_s?)
          next unless role.nil? || role.empty? || role == "Author"
          c["author"]?.try { |a| str(a, "name") }
        end.uniq
      end

      # plain text, lines become paragraphs
      def self.description(text : String) : String?
        paragraphs = text.split(/\r?\n/).map { |p| p.strip.gsub(/\s+/, " ") }.reject(&.empty?)
        return nil if paragraphs.empty?
        paragraphs.map { |p| "<p>#{HTML.escape(p)}</p>" }.join
      end

      private def self.url(book : JSON::Any) : String?
        str(book, "slug").try { |s| "https://hardcover.app/books/#{s}" }
      end

      private def self.isbn(e : JSON::Any) : String?
        (str(e, "isbn_13") || str(e, "isbn_10")).try { |i| Isbn.normalize(i) }
      end

      private def self.publisher(e : JSON::Any) : String?
        e["publisher"]?.try { |p| p.as_h? ? str(p, "name") : nil }
      end

      private def self.edition_languages(e : JSON::Any) : Array(String)
        code = e["language"]?.try { |l| l.as_h? ? str(l, "code3") : nil }
        code ? Lang.list([code]) : [] of String
      end

      private def self.str(o : JSON::Any, key : String) : String?
        o.as_h? ? o[key]?.try(&.as_s?).try(&.strip).presence : nil
      end
    end
  end
end
