require "compress/zip"
require "digest/crc32"
require "json"
require "uri"
require "xml"
require "./files"
require "./meta_rules"

module CalibreHub
  # Repairs what keeps EPUBs from opening on readers or from being accepted
  # by Send to Kindle (like the EPUB fixer of Calibre-Web-Automated, after
  # kindle-epub-fix): the mimetype entry, encodings, a missing or
  # meaningless dc:language, the spine's NCX reference, the cover meta, img
  # tags without a source and links to a chapter's body id. Conservative:
  # only those, as text edits on the files that need them; every other
  # entry is copied byte for byte. What can't be repaired safely is only
  # reported (problems). Running it on its own output finds nothing.
  module EpubFix
    MIMETYPE = "application/epub+zip"
    DC       = "http://purl.org/dc/elements/1.1/"
    NCX_TYPE = "application/x-dtbncx+xml"
    XML_DECL = %(<?xml version="1.0" encoding="utf-8"?>)
    BOM      = Bytes[0xEF, 0xBB, 0xBF]
    # files whose encoding is checked: content documents, package, NCX
    TEXT = /\.(xhtml|html|htm|opf|ncx)\z/i
    HTML = /\.(xhtml|html|htm)\z/i
    # at most this many problems of one kind per file
    MAX_REPORTED = 5

    class Error < Exception
    end

    struct Fix
      include JSON::Serializable

      getter code : String
      getter file : String?
      getter detail : String

      def initialize(@code, @file, @detail)
      end
    end

    class Report
      include JSON::Serializable

      getter fixes = [] of Fix
      getter problems = [] of Fix

      def initialize
      end

      def fix(code, file, detail)
        @fixes << Fix.new(code, file, detail)
      end

      def problem(code, file, detail)
        @problems << Fix.new(code, file, detail)
      end

      def changed? : Bool
        !@fixes.empty?
      end

      def empty? : Bool
        @fixes.empty? && @problems.empty?
      end
    end

    class Item
      getter name : String
      property data : Bytes
      getter time : Time
      getter dir : Bool
      getter stored : Bool

      def initialize(@name, @data, @time, @dir, @stored)
      end

      def text : String
        String.new(@data)
      end

      def text=(s : String)
        @data = s.to_slice
      end
    end

    # The language to write into dc:language: the book's first real
    # calibre language, two letters where there are two (deu -> de)
    def self.language(languages : Array(String)) : String?
      code = Meta::Lang.known(languages).first? || return nil
      code = code.downcase
      TWO_LETTER[code]? || code
    end

    TWO_LETTER = Meta::Lang::MAP.select { |k, _| k.size == 2 }.to_h { |two, three| {three, two} }

    # Checks src; with dest, writes the repaired EPUB there when something
    # was fixed. language: what a missing or meaningless dc:language
    # becomes (nil: only reported)
    def self.run(src : String, dest : String?, language : String?) : Report
      items = read(src)
      report = Report.new
      Fixer.new(items, report, language).run
      if dest && report.changed?
        write(dest, items)
        verify(dest, items)
      end
      report
    end

    def self.read(path : String) : Array(Item)
      items = [] of Item
      Compress::Zip::File.open(path) do |zip|
        zip.entries.each do |e|
          data = e.dir? ? Bytes.empty : e.open(&.getb_to_end)
          items << Item.new(e.filename, data, e.time, e.dir?, e.compression_method.stored?)
        end
      end
      items
    rescue ex : Compress::Zip::Error | IO::Error
      raise Error.new("not a readable ZIP: #{ex.message}")
    end

    # mimetype first and stored, as the OCF spec wants; the rest in the
    # original order
    def self.write(path : String, items : Array(Item))
      File.open(path, "w") do |io|
        Compress::Zip::Writer.open(io) do |zip|
          mt = MIMETYPE.to_slice
          entry = Compress::Zip::Writer::Entry.new("mimetype", items.find { |i| i.name == "mimetype" }.try(&.time) || Time.utc)
          entry.compression_method = Compress::Zip::CompressionMethod::STORED
          entry.crc32 = Digest::CRC32.checksum(mt)
          entry.compressed_size = mt.size.to_u32
          entry.uncompressed_size = mt.size.to_u32
          zip.add(entry, mt)
          items.each do |item|
            next if item.name == "mimetype"
            if item.dir
              zip.add_dir(item.name)
            else
              zip.add(Compress::Zip::Writer::Entry.new(item.name, item.time), item.data)
            end
          end
        end
      end
    end

    # The written file reads back with every entry and its content
    def self.verify(path : String, items : Array(Item))
      back = read(path)
      want = items.reject(&.dir).to_h { |i| {i.name, i.name == "mimetype" ? MIMETYPE.to_slice : i.data} }
      want["mimetype"] = MIMETYPE.to_slice
      got = back.reject(&.dir).to_h { |i| {i.name, i.data} }
      raise Error.new("repaired EPUB doesn't read back") unless got.keys.sort == want.keys.sort && got.all? { |k, v| want[k] == v }
    end

    # Normalized path inside the EPUB: base is the referring file
    def self.resolve(base : String, href : String) : String?
      return nil if href.empty? || href.matches?(/\A[a-z][a-z0-9+.-]*:/i) || href.starts_with?('/')
      path = URI.decode(href)
      parts = [] of String
      dir = File.dirname(base)
      (dir == "." ? path : "#{dir}/#{path}").split('/').each do |p|
        case p
        when "", "." then next
        when ".."    then parts.pop?
        else              parts << p
        end
      end
      parts.join('/')
    end

    class Fixer
      @files : Hash(String, Item)

      def initialize(@items : Array(Item), @report : Report, @language : String?)
        @files = @items.reject(&.dir).to_h { |i| {i.name, i} }
      end

      def run
        mimetype
        opf = opf_path || raise Error.new("no package document (META-INF/container.xml)")
        @items.each { |i| encoding(i) if !i.dir && i.name.matches?(TEXT) }
        package(opf)
        documents(opf)
      end

      private def mimetype
        first = @items.first?
        return if first && first.name == "mimetype" && first.stored && first.data == MIMETYPE.to_slice
        m = @files["mimetype"]?
        detail = if m.nil?
                   "missing"
                 elsif m.data != MIMETYPE.to_slice
                   "was #{String.new(m.data).strip.inspect}"
                 elsif !first || first.name != "mimetype"
                   "not the first entry"
                 else
                   "compressed"
                 end
        @report.fix("mimetype", "mimetype", detail)
      end

      private def opf_path : String?
        container = @files["META-INF/container.xml"]? || return nil
        path = container.text.scrub.match(/<(?:[\w.-]+:)?rootfile\b[^>]*\sfull-path\s*=\s*["']([^"']+)["']/).try(&.[1]) || return nil
        path = URI.decode(path)
        @files.has_key?(path) ? path : nil
      end

      # UTF-8 throughout: an XML declaration on content documents, declared
      # encodings that don't match the content corrected, legacy encodings
      # converted (only when the whole file is in one of them)
      private def encoding(item : Item)
        data = item.data
        return if data.size >= 2 && ((data[0] == 0xFF && data[1] == 0xFE) || (data[0] == 0xFE && data[1] == 0xFF))
        bom = data.size >= 3 && data[0, 3] == BOM
        body = bom ? data[3..] : data
        raw = String.new(body)
        # regexes need valid UTF-8; the declarations are ASCII
        probe = raw.valid_encoding? ? raw : raw.scrub
        decl = probe.match(/\A\s*(<\?xml\b[^?>]*\?>)/)
        declared = decl.try { |m| m[1].match(/encoding\s*=\s*["']([^"']+)["']/).try(&.[1]) }
        html = item.name.matches?(HTML)
        if raw.valid_encoding?
          text = raw
          what = nil
          if decl.nil?
            return unless html
            text = "#{XML_DECL}\n#{text.lstrip}"
            what = {"xml-declaration", "added"}
          elsif declared && !utf8?(declared)
            text = set_declared(text, decl[1])
            what = {"encoding", "declared #{declared}, content is UTF-8"}
          end
          # nothing may come before the declaration
          if decl && text.matches?(/\A\s+<\?xml\b/)
            text = text.lstrip
            what ||= {"xml-declaration", "whitespace before it removed"}
          end
          if html && (c = meta_charset(text)) && !utf8?(c)
            text = set_meta_charset(text)
            what ||= {"encoding", "meta charset #{c}, content is UTF-8"}
          end
          return unless what
          item.data = join(bom, text)
          @report.fix(what[0], item.name, what[1])
        else
          # valid UTF-8 sequences in an invalid file: mixed encodings,
          # converting would garble the UTF-8 parts
          if (declared.nil? || utf8?(declared)) && raw.each_char.any? { |c| c.ord > 0x7F && c != Char::REPLACEMENT }
            @report.problem("encoding", item.name, "mixed encodings, left as is")
            return
          end
          from = declared && !utf8?(declared) ? declared : (html ? meta_charset(probe) : nil)
          from = nil if from && utf8?(from)
          source = Meta::Charset.legacy(from)
          text = begin
            String.new(body, source)
          rescue ArgumentError
            @report.problem("encoding", item.name, "neither UTF-8 nor #{source}, left as is")
            return
          end
          dm = text.match(/\A\s*(<\?xml\b[^?>]*\?>)/)
          text = dm ? set_declared(text, dm[1]).lstrip : (html ? "#{XML_DECL}\n#{text.lstrip}" : text)
          text = set_meta_charset(text) if html && meta_charset(text)
          item.data = join(bom, text)
          @report.fix("encoding", item.name, "#{from || "undeclared (#{source})"} converted to UTF-8")
        end
      end

      private def utf8?(enc : String) : Bool
        Meta::Charset.utf8?(enc)
      end

      private def join(bom : Bool, text : String) : Bytes
        return text.to_slice unless bom
        io = IO::Memory.new
        io.write(BOM)
        io << text
        io.to_slice
      end

      private def set_declared(text : String, decl : String) : String
        Meta::Charset.set_declared(text, decl)
      end

      private def meta_charset(text : String) : String?
        Meta::Charset.meta_charset(text)
      end

      private def set_meta_charset(text : String) : String
        Meta::Charset.set_meta_charset(text)
      end

      record ManifestItem, id : String, href : String, path : String?, media_type : String, properties : String

      @manifest = [] of ManifestItem

      # dc:language, the spine's NCX, the cover meta; missing files reported
      private def package(opf : String)
        item = @files[opf]
        text = item.text
        unless text.valid_encoding?
          @report.problem("opf", opf, "package document is not UTF-8, left as is")
          return
        end
        doc = begin
          XML.parse(text, XML::ParserOptions::NONET | XML::ParserOptions::NOERROR | XML::ParserOptions::NOWARNING)
        rescue ex : XML::Error
          nil
        end
        root = doc.try(&.root)
        unless root && root.name == "package"
          @report.problem("opf", opf, "not a readable package document, left as is")
          return
        end
        elements = [] of XML::Node
        walk(root) { |n| elements << n }
        @manifest = elements.select { |n| n.name == "item" && n.parent.try(&.name) == "manifest" }.compact_map do |n|
          id = n["id"]? || next
          href = n["href"]? || next
          ManifestItem.new(id, href, EpubFix.resolve(opf, href), n["media-type"]? || "", n["properties"]? || "")
        end
        @manifest.each do |m|
          next if m.path.nil? || @files.has_key?(m.path.not_nil!)
          @report.problem("missing-file", opf, "manifest item #{m.href} is not in the EPUB")
        end
        before = text
        text = language(opf, text, elements)
        text = spine_toc(opf, text, elements)
        text = cover_meta(opf, text, elements)
        item.text = text unless text == before
      end

      private def walk(node : XML::Node, &block : XML::Node ->)
        node.children.each do |c|
          next unless c.element?
          block.call(c)
          walk(c, &block)
        end
      end

      LANGUAGE_TAG = /(<((?:[\w.-]+:)?)language\b[^>]*?)(?:\/>|>(.*?)<\/\2language\s*>)/m

      private def valid_language?(code : String) : Bool
        c = code.strip
        c.matches?(/\A[a-z]{2,3}(-[a-z0-9]{1,8})*\z/i) && !Meta::Lang::NO_LANGUAGE.includes?(c.split('-').first.downcase)
      end

      private def language(opf : String, text : String, elements : Array(XML::Node)) : String
        langs = elements.select { |n| n.name == "language" && n.namespace.try(&.href) == DC }
        invalid = langs.map(&.content.strip).reject { |l| valid_language?(l) }
        if langs.empty?
          if lang = @language
            if m = text.match(/<\/((?:[\w.-]+:)?)metadata\s*>/)
              prefix = text.match(/xmlns:([\w.-]+)\s*=\s*["']#{Regex.escape(DC)}["']/).try(&.[1])
              tag = prefix ? %(<#{prefix}:language>#{lang}</#{prefix}:language>) : %(<dc:language xmlns:dc="#{DC}">#{lang}</dc:language>)
              @report.fix("language", opf, "added #{lang}")
              return text.sub(m[0], "  #{tag}\n  #{m[0]}")
            end
          end
          @report.problem("language", opf, "no dc:language and the book has no language in calibre")
          return text
        end
        return text if invalid.empty?
        lang = @language
        unless lang
          @report.problem("language", opf, "dc:language #{invalid.map(&.inspect).join(", ")} and the book has no language in calibre")
          return text
        end
        replaced = [] of String
        out = text.gsub(LANGUAGE_TAG) do |all, m|
          content = m[3]? || ""
          next all if valid_language?(content) || content.includes?('<')
          replaced << content.strip
          "#{m[1]}>#{lang}</#{m[2]}language>"
        end
        @report.fix("language", opf, "#{replaced.map(&.inspect).join(", ")} -> #{lang}") unless replaced.empty?
        out
      end

      private def spine_toc(opf : String, text : String, elements : Array(XML::Node)) : String
        spine = elements.find { |n| n.name == "spine" } || return text
        toc = spine["toc"]?
        ids = @manifest.map(&.id).to_set
        return text if toc && ids.includes?(toc)
        ncx = @manifest.select { |m| m.media_type == NCX_TYPE && m.path.try { |p| @files.has_key?(p) } }
        tag = text.match(/<(?:[\w.-]+:)?spine\b[^>]*>/) || return text
        new_tag = if ncx.size == 1
                    if toc
                      tag[0].sub(/\btoc\s*=\s*(["'])[^"']*\1/, %(toc="#{ncx[0].id}"))
                    else
                      tag[0].sub(/\A(<(?:[\w.-]+:)?spine)\b/) { %(#{$1} toc="#{ncx[0].id}") }
                    end
                  elsif toc && ncx.empty?
                    tag[0].sub(/\s+toc\s*=\s*(["'])[^"']*\1/, "")
                  end
        return text unless new_tag && new_tag != tag[0]
        @report.fix("spine-toc", opf, toc ? "toc #{toc.inspect} -> #{ncx[0]?.try(&.id) || "none"}" : "toc -> #{ncx[0].id}")
        text.sub(tag[0], new_tag)
      end

      private def cover_meta(opf : String, text : String, elements : Array(XML::Node)) : String
        meta = elements.find { |n| n.name == "meta" && n["name"]? == "cover" }
        ids = @manifest.map(&.id).to_set
        current = meta.try(&.[]?("content"))
        return text if current && ids.includes?(current)
        images = @manifest.select { |m| m.media_type.starts_with?("image/") && m.path.try { |p| @files.has_key?(p) } }
        candidates = images.select { |m| m.properties.split.includes?("cover-image") }
        candidates = images.select { |m| m.id.matches?(/cover/i) || File.basename(m.href).matches?(/\Acover/i) } if candidates.empty?
        return text unless candidates.size == 1
        id = candidates[0].id
        if current
          tag = text.match(/<(?:[\w.-]+:)?meta\b[^>]*\bname\s*=\s*["']cover["'][^>]*>/) || return text
          @report.fix("cover-meta", opf, "#{current.inspect} -> #{id}")
          return text.sub(tag[0], tag[0].sub(/\bcontent\s*=\s*(["'])[^"']*\1/, %(content="#{id}")))
        end
        m = text.match(/<\/((?:[\w.-]+:)?)metadata\s*>/) || return text
        @report.fix("cover-meta", opf, "added #{id}")
        text.sub(m[0], %(  <#{m[1]}meta name="cover" content="#{id}"/>\n  #{m[0]}))
      end

      IMG         = /<img\b(?:[^>"']|"[^"]*"|'[^']*')*>(?:\s*<\/img\s*>)?/i
      SRC         = /\ssrc\s*=\s*(?:"([^"]*)"|'([^']*)')/i
      HREF        = /(\s(?:href|src)\s*=\s*)(?:"([^"]*)"|'([^']*)')/i
      BODY_ID     = /<body\b[^>]*?\sid\s*=\s*["']([^"']+)["']/i
      NCX_CONTENT = /(<(?:[\w.-]+:)?content\b[^>]*?\ssrc\s*=\s*)(?:"([^"]*)"|'([^']*)')/i

      # Content documents (and the NCX): img tags without a source dropped,
      # links to a body id pointed at the file; broken references reported
      private def documents(opf : String)
        docs = @manifest.select { |m| m.media_type.in?("application/xhtml+xml", "text/html") }.compact_map(&.path).select { |p| @files.has_key?(p) }
        docs |= @files.keys.select(&.matches?(HTML))
        body_ids = {} of String => String
        docs.each do |p|
          t = @files[p].text
          t.match(BODY_ID).try { |m| body_ids[p] = m[1] } if t.valid_encoding?
        end
        docs.each do |p|
          item = @files[p]
          text = item.text
          next unless text.valid_encoding?
          before = text
          stray = 0
          text = text.gsub(IMG) do |tag|
            src = tag.match(SRC).try { |m| m[1]? || m[2]? }
            next tag if src && !src.strip.empty?
            stray += 1
            ""
          end
          @report.fix("stray-img", p, "img without src removed: #{stray}") if stray > 0
          text = links(p, text, HREF, body_ids)
          item.text = text unless text == before
          broken(p, text)
        end
        @manifest.select { |m| m.media_type == NCX_TYPE }.compact_map(&.path).each do |p|
          item = @files[p]? || next
          text = item.text
          next unless text.valid_encoding?
          fixed = links(p, text, NCX_CONTENT, body_ids)
          item.text = fixed unless fixed == text
        end
      end

      private def links(file : String, text : String, pattern : Regex, body_ids : Hash(String, String)) : String
        n = 0
        out = text.gsub(pattern) do |all, m|
          value = m[2]? || m[3]? || next all
          path, hash, frag = value.partition('#')
          next all if hash.empty? || path.empty?
          target = EpubFix.resolve(file, path) || next all
          next all unless body_ids[target]? == URI.decode(frag)
          n += 1
          %(#{m[1]}"#{path}")
        end
        @report.fix("body-id-link", file, "links to a body id: #{n}") if n > 0
        out
      end

      private def broken(file : String, text : String)
        missing = [] of String
        text.scan(/\s(?:href|src)\s*=\s*(?:"([^"]*)"|'([^']*)')/i) do |m|
          value = m[1]? || m[2]? || next
          path = value.partition('#')[0]
          next if path.empty?
          target = EpubFix.resolve(file, path) || next
          missing << path unless @files.has_key?(target) || missing.includes?(path)
        end
        return if missing.empty?
        shown = missing.first(MAX_REPORTED).join(", ")
        more = missing.size > MAX_REPORTED ? " (+#{missing.size - MAX_REPORTED})" : ""
        @report.problem("broken-reference", file, "#{shown}#{more} not in the EPUB, left as is")
      end
    end
  end

  # The EPUB fixer over books, as jobs in a queue of their own: added books
  # (and books that got an EPUB) when on_import is on, the library or a
  # selection through POST /api/epub-fix, as a dry run (default) or for
  # real. The EPUB is downloaded through calibre-server, repaired in a
  # temporary folder and added back (cdb add_format); the library is never
  # written directly. Before the first repair the file as it was is kept as
  # format ORIGINAL_EPUB (keep_original), its KOReader checksum in
  # file_checksums. What a run found per book is in epub_fix_results.
  class EpubFixJobs < Jobs
    TABLE = "epub_fix_jobs"
    # results returned per job
    MAX_RESULTS = 500

    getter on_import : Bool
    getter keep_original : Bool

    def initialize(db : DB::Database, calibre : Calibre, writer : Writer, @library : String?,
                   @on_import : Bool, @keep_original : Bool = true,
                   @detector : Detector? = nil, @notify : Channel(Nil)? = nil)
      db.exec "create table if not exists meta (key text primary key, value text)"
      BookFiles.create_checksums(db)
      db.exec <<-SQL
        create table if not exists epub_fix_results (
          job_id text not null,
          book_id integer not null,
          title text not null,
          applied integer not null,
          fixes text not null,
          problems text not null,
          primary key (job_id, book_id)
        )
        SQL
      super(db, calibre, writer, nil, TABLE)
    end

    def self.dry_run!(value : JSON::Any?) : Bool
      return true if value.nil? || value.raw.nil?
      b = value.as_bool?
      raise Edit::Invalid.new("dryRun", "true or false expected") if b.nil?
      b
    end

    # body: {dryRun?: true, target?: {ids: [...]} | {query: {...}}};
    # without a target every book with an EPUB
    def submit_fix(body : Hash(String, JSON::Any)) : Job
      dry = EpubFixJobs.dry_run!(body["dryRun"]?)
      target = body["target"]?.try { |t| t.raw.nil? ? nil : t }
      ids = target ? ids(target) : library_ids
      start(ids, dry, target ? "selection" : "library")
    end

    def library_ids : Array(Int64)
      @calibre.list("", ["formats"]).select { |b| EpubFixJobs.epub?(b.formats) }.map(&.id)
    end

    def self.epub?(formats : Array(String)) : Bool
      formats.any? { |f| f.upcase == "EPUB" }
    end

    private def start(ids : Array(Int64), dry : Bool, from : String) : Job
      # results of jobs no longer kept go with them
      @db.exec "delete from epub_fix_results where job_id not in (select id from #{TABLE})"
      enqueue(ids, {"dryRun" => JSON::Any.new(dry), "from" => JSON::Any.new(from)})
    end

    def watch_events(interval = 10.seconds)
      if cursor.nil?
        max = @db.query_one("select coalesce(max(id), 0) from events", as: Int64)
        @db.exec "insert or replace into meta (key, value) values ('epub_fix_event_seq', ?)", max.to_s
      end
      spawn do
        loop do
          begin
            follow_events
          rescue ex
            STDERR.puts "epub-fix: events: #{ex.message}"
          end
          sleep interval
        end
      end
    end

    def cursor : Int64?
      @db.query_one?("select value from meta where key = 'epub_fix_event_seq'", as: String).try(&.to_i64)
    end

    # Added books with an EPUB (inbox, upload, calibre) and books that got
    # one (a conversion, an added format)
    def follow_events
      from = cursor || 0_i64
      rows = [] of {Int64, String, Int64, String}
      @db.query_each("select id, type, book_id, payload from events where id > ? order by id limit 500", from) do |rs|
        rows << rs.read(Int64, String, Int64, String)
      end
      return if rows.empty?
      strings = ->(v : JSON::Any?) { v.try(&.as_a?).try(&.map(&.to_s)) || [] of String }
      ids = rows.compact_map do |_, type, book_id, payload|
        e = JSON.parse(payload)
        case type
        when "added"
          book_id if EpubFixJobs.epub?(strings.call(e["book"]?.try(&.["formats"]?)))
        when "changed"
          f = e["changes"]?.try(&.["formats"]?)
          book_id if f && EpubFixJobs.epub?(strings.call(f[1]?)) && !EpubFixJobs.epub?(strings.call(f[0]?))
        end
      end
      unless ids.empty?
        job = start(ids.uniq, false, "added")
        puts "epub-fix: job #{job.id} for #{job.total} new EPUBs"
      end
      @db.exec "insert or replace into meta (key, value) values ('epub_fix_event_seq', ?)", rows.last[0].to_s
    end

    protected def apply(job : Job, index : Int32, id : Int64, resumed : Bool)
      dry = job.changes["dryRun"]?.try(&.as_bool?) != false
      book = @calibre.book(id) || raise Writer::NotFound.new
      return unless EpubFixJobs.epub?(book.formats)
      report, applied = fix(book, dry)
      return if report.empty?
      @db.exec "insert or replace into epub_fix_results (job_id, book_id, title, applied, fixes, problems) values (?, ?, ?, ?, ?, ?)",
        job.id, id, book.title, applied ? 1 : 0, report.fixes.to_json, report.problems.to_json
    rescue ex : Calibre::Unavailable
      raise Abort.new(ex.message)
    end

    # Repairs one book's EPUB; {what was found, written?}
    def fix(book : Book, dry : Bool) : {EpubFix::Report, Bool}
      BookFiles.tmpdir do |dir|
        src = File.join(dir, "book.epub")
        dst = File.join(dir, "#{book.id}.epub")
        BookFiles.download(@calibre, book.id, "EPUB", src)
        report = EpubFix.run(src, dry ? nil : dst, EpubFix.language(book.languages))
        if dry || !report.changed?
          {report, false}
        else
          BookFiles.remember_checksums(@db, @library, book.id, ["EPUB"])
          if @keep_original && !book.formats.any? { |f| f.upcase == "ORIGINAL_EPUB" }
            # the file in the library as it is; the download has calibre's metadata in it
            original = BookFiles.library_files(@library, book.id)["EPUB"]?.try { |f| File.exists?(f) ? f : nil } || src
            @calibre.add_format(book.id, original, "original_epub")
          end
          @calibre.add_format(book.id, dst, "epub")
          @writer.written([book.id])
          @calibre.book(book.id).try { |b| BookFiles.files_changed(@detector, @notify, b) }
          puts "epub-fix: ##{book.id} #{book.title}: #{report.fixes.map(&.code).uniq.join(", ")}"
          {report, true}
        end
      end
    end

    # A job with what it found: books and counts per fix and problem
    def summary(job : Job, results = false) : JSON::Any
      fixes = Hash(String, Int32).new(0)
      problems = Hash(String, Int32).new(0)
      books = [] of JSON::Any
      applied = 0
      with_fixes = 0
      with_problems = 0
      @db.query_each("select book_id, title, applied, fixes, problems from epub_fix_results where job_id = ? order by book_id", job.id) do |rs|
        id, title, ap, f, p = rs.read(Int64, String, Int64, String, String)
        fx = Array(EpubFix::Fix).from_json(f)
        pr = Array(EpubFix::Fix).from_json(p)
        applied += 1 if ap == 1
        with_fixes += 1 unless fx.empty?
        with_problems += 1 unless pr.empty?
        fx.map(&.code).uniq.each { |c| fixes[c] += 1 }
        pr.map(&.code).uniq.each { |c| problems[c] += 1 }
        if results && books.size < MAX_RESULTS
          books << JSON.parse({bookId: id, title: title, applied: ap == 1, fixes: fx, problems: pr}.to_json)
        end
      end
      h = JSON.parse(job.to_json).as_h
      h["dryRun"] = job.changes["dryRun"]? || JSON::Any.new(true)
      h["from"] = job.changes["from"]? || JSON::Any.new(nil)
      h["booksWithFixes"] = JSON::Any.new(with_fixes.to_i64)
      h["booksWithProblems"] = JSON::Any.new(with_problems.to_i64)
      h["booksFixed"] = JSON::Any.new(applied.to_i64)
      h["fixes"] = JSON.parse(fixes.to_json)
      h["problems"] = JSON.parse(problems.to_json)
      h["results"] = JSON::Any.new(books) if results
      JSON::Any.new(h)
    end
  end

  # GET /api/epub-fix/status, GET /api/epub-fix/jobs/:id, POST /api/epub-fix
  def self.epub_fix_routes(fixer : EpubFixJobs)
    get "/api/epub-fix/status" do
      last = fixer.last.try do |job, started|
        fixer.summary(job).as_h.merge({"startedAt" => JSON::Any.new(started.to_rfc3339)})
      end
      {onImport: fixer.on_import, keepOriginal: fixer.keep_original, running: fixer.running?, lastRun: last}.to_json
    end

    get "/api/epub-fix/jobs/:id" do |env|
      job = fixer[env.params.url["id"]]?
      next fail(env, 404, {error: "not found"}) unless job
      fixer.summary(job, results: true).to_json
    end

    post "/api/epub-fix" do |env|
      write_errors(env) do
        job = fixer.submit_fix(json_body(env))
        env.response.status_code = 202
        {jobId: job.id, total: job.total, dryRun: job.changes["dryRun"].as_bool}.to_json
      end
    end
  end
end
