require "db"
require "json"
require "xml"
require "digest/md5"
require "./api"
require "./calibre"
require "./writer"
require "./library_db"
require "./meta_sources"
require "./files"
require "./sanitizer"
require "./dedup"
require "./backlog_pause"

module CalibreHub
  # Imports an old collection (the "backlog") that is not sorted for the
  # inbox: folders never become categories or tags. A folder of an old
  # calibre library (metadata.opf, cover.jpg, the formats) becomes one book
  # with the OPF's metadata; any other book file becomes a book with what
  # calibre reads from it (files with the same name and another extension in
  # the same folder are formats of one book). Everything else stays where it
  # is and is listed in the report. Nothing is moved or deleted: the state
  # DB remembers every file it imported, so another run skips them, unless
  # the book it went to is no longer in the library (removed, or in
  # calibre's trash): then the file is planned again.
  #
  # Before adding, every book is checked against the library: the same file
  # (size and KOReader partial MD5, also of files the hub rewrote since), the
  # ISBN, or title and an author, with the duplicate page's rules (Dedup:
  # its normalization, never two volumes, editions of a standard or numbers
  # of a series). A duplicate is skipped, or adds the formats the library's
  # book lacks. Files without an OPF are checked by file before adding and
  # by what calibre read from them right after (calibre's own title/author
  # check, then ISBN and title/author).
  #
  # A run scans one or more folders as a job (the scan, then a unit per
  # book; a dry run only scans), in a queue of its own, resumed after a
  # restart. While an import runs the metadata, classify, convert and embed
  # hooks pause (Backlog.paused?) and work off the new books afterwards.
  module Backlog
    # calibre reads the metadata from the first of these the book has
    FORMATS  = %w(EPUB KEPUB AZW3 AZW MOBI PRC AZW4 FB2 FBZ DOCX ODT RTF PDF DJVU DJV CHM CBZ CBR CB7 LIT PDB TXT)
    MIN_SIZE = 2_048_i64
    # short TXT files are READMEs, licences and notes, not books
    MIN_TEXT = 20_480_i64
    # further formats go to calibre-server as base64 in JSON (set-fields)
    MAX_FORMAT = Writer::MAX_UPLOAD
    # what the inbox moved away, at the top of the scanned folder
    INBOX_DIRS = %w(_imported _duplicates _failed)
    OPF        = "metadata.opf"
    COVER      = "cover.jpg"
    # identifiers of the old library, not of the book
    LOCAL_IDS = %w(calibre uuid)

    class BookFile
      include JSON::Serializable

      getter path : String
      getter format : String
      getter size : Int64
      getter mtime : Int64

      def initialize(@path, @format, @size, @mtime)
      end
    end

    # What a calibre folder's metadata.opf says, as set-fields wants it
    class OpfMeta
      include JSON::Serializable

      property title : String?
      property authors : Array(String) = [] of String
      property tags : Array(String) = [] of String
      property series : String?
      @[JSON::Field(key: "seriesIndex")]
      property series_index : Float64?
      property identifiers : Hash(String, String) = {} of String => String
      property comments : String?
      property languages : Array(String) = [] of String
      property publisher : String?
      property pubdate : String?

      def initialize
      end

      def isbn : String?
        identifiers["isbn"]?
      end

      def self.parse(xml : String) : OpfMeta
        record = Meta::FileMeta.opf(xml)
        doc = XML.parse(xml)
        m = OpfMeta.new
        m.title = record.title
        m.authors = record.authors || [] of String
        m.series = record.series
        m.series_index = record.series_index
        m.comments = record.comments
        m.languages = record.languages || [] of String
        m.publisher = record.publisher
        m.pubdate = record.pubdate
        m.tags = doc.xpath_nodes("//*[local-name()='metadata']/*[local-name()='subject']").map(&.content.strip).reject(&.empty?).uniq
        doc.xpath_nodes("//*[local-name()='metadata']/*[local-name()='identifier']").each do |n|
          scheme = n.attributes.find { |a| a.name == "scheme" }.try(&.content.strip.downcase) || next
          value = n.content.strip
          next if scheme.empty? || value.empty? || LOCAL_IDS.includes?(scheme)
          m.identifiers[scheme] = value unless m.identifiers.has_key?(scheme)
        end
        if isbn = record.isbn
          m.identifiers["isbn"] = isbn
        elsif raw = m.identifiers["isbn"]?
          Meta::Isbn.normalize(raw).try { |i| m.identifiers["isbn"] = i } || m.identifiers.delete("isbn")
        end
        m
      end

      # set-fields changes; values the OPF lacks are left to calibre
      def changes : Hash(String, JSON::Any)
        c = {} of String => JSON::Any
        title.try { |t| c["title"] = JSON::Any.new(t) }
        c["authors"] = JSON.parse(authors.to_json) unless authors.empty?
        # always, so tags calibre read from the file don't stay
        c["tags"] = JSON.parse(tags.to_json)
        if s = series
          c["series"] = JSON::Any.new(s)
          series_index.try { |i| c["series_index"] = JSON::Any.new(i) }
        end
        c["identifiers"] = JSON.parse(identifiers.to_json) unless identifiers.empty?
        comments.try { |html| Sanitizer.clean(html).presence.try { |v| c["comments"] = JSON::Any.new(v) } }
        c["languages"] = JSON.parse(languages.to_json) unless languages.empty?
        publisher.try { |p| c["publisher"] = JSON::Any.new(p) }
        pubdate.try { |d| c["pubdate"] = JSON::Any.new("#{Meta::Dates.full(d)}T12:00:00+00:00") }
        c
      end
    end

    # One book to import: a calibre folder or the files of one name
    class Unit
      include JSON::Serializable

      # calibre: a folder with metadata.opf; file: book files of one name
      getter kind : String
      getter dir : String
      getter files : Array(BookFile)
      getter cover : String?
      getter meta : OpfMeta?
      # the plan: add, addFormats (to bookId), duplicate (of bookId)
      property action : String = "add"
      @[JSON::Field(key: "bookId")]
      property book_id : Int64?
      # how the duplicate was found: file, isbn, title, calibre
      property match : String?
      # a duplicate of a book this run adds (dry run) or added
      @[JSON::Field(key: "sameAs")]
      property same_as : String?
      # formats the existing book gets
      @[JSON::Field(key: "addFormats")]
      property add_formats : Array(String) = [] of String
      # after the import: imported, formatAdded, duplicate, failed
      property status : String = "pending"
      property detail : String?
      # plain files: who decided title and authors from the file name (name,
      # folder, file, a metadata source, model, unsure; Meta::FileName.decide)
      property decided : String?

      def initialize(@kind, @dir, @files, @cover = nil, @meta = nil)
      end

      def name : String
        kind == "calibre" ? dir : files.first.path
      end

      def primary : BookFile
        files.min_by { |f| FORMATS.index(f.format) || FORMATS.size }
      end
    end

    record Skipped, path : String, reason : String do
      include JSON::Serializable

      def ext : String
        File.extname(path).lchop('.').downcase.presence || "(none)"
      end
    end

    # path -> {size, mtime, status, book}: files earlier runs handled
    alias Known = Hash(String, {Int64, Int64, String, Int64?})

    # Walks folders (read-only, one after another) into units and skipped files
    class Scanner
      # other fibers (the API) run every this many entries
      YIELD_EVERY = 64
      # on_progress is called every this many entries
      PROGRESS_EVERY = 500

      getter units = [] of Unit
      getter skipped = [] of Skipped
      getter already = 0
      # files looked at, book files or not
      getter files = 0
      # the folder being walked
      getter current : String? = nil
      # (files, units) now and then while walking
      property on_progress : Proc(Int32, Int32, Nil)?
      @entries = 0

      def initialize(@roots : Array(String), @known : Known = Known.new)
      end

      def initialize(root : String, @known : Known = Known.new)
        @roots = [root]
      end

      def run : self
        @roots.each { |r| walk(r, top: true) }
        @on_progress.try &.call(@files, @units.size)
        self
      end

      def self.format(name : String) : String?
        ext = File.extname(name).lchop('.').upcase
        FORMATS.includes?(ext) ? ext : nil
      end

      # nil when the file looks like a book of its format
      def self.problem(path : String, format : String, size : Int64) : String?
        return "too small" if size < (format == "TXT" ? MIN_TEXT : MIN_SIZE)
        head = Bytes.new(1024)
        n = File.open(path) { |f| f.read(head) }
        head = head[0, n]
        ok = case format
             when "EPUB", "KEPUB", "CBZ", "DOCX", "ODT", "FBZ" then starts?(head, "PK")
             when "PDF"                                        then String.new(head).includes?("%PDF")
             when "DJVU", "DJV"                                then starts?(head, "AT&TFORM")
             when "MOBI", "AZW", "AZW3", "PRC", "PDB"          then starts?(head, "TPZ") || head.size >= 68 && {"BOOKMOBI", "TEXtREAd"}.any? { |m| String.new(head[60, 8]) == m } || format == "PDB" && head.size >= 78
             when "CHM"                                        then starts?(head, "ITSF")
             when "CBR"                                        then starts?(head, "Rar!")
             when "CB7"                                        then starts?(head, "7z")
             when "RTF"                                        then starts?(head, "{\\rtf")
             when "LIT"                                        then starts?(head, "ITOLITLS")
             when "FB2"                                        then String.new(head).lstrip("﻿ \n\r\t").starts_with?('<')
             else                                                   true
             end
        ok ? nil : "broken (not a #{format} file)"
      rescue ex : File::Error | IO::Error
        "unreadable (#{ex.message})"
      end

      private def self.starts?(head : Bytes, magic : String) : Bool
        head.size >= magic.bytesize && head[0, magic.bytesize] == magic.to_slice
      end

      private def walk(dir : String, top = false)
        @current = dir
        children = begin
          Dir.children(dir).sort
        rescue ex : File::Error
          @skipped << Skipped.new(dir, "unreadable folder (#{ex.message})")
          return
        end
        files = [] of String
        children.each do |name|
          tick
          path = File.join(dir, name)
          info = File.info?(path, follow_symlinks: false)
          if info.nil? || info.symlink?
            @skipped << Skipped.new(path, "symlink")
          elsif info.directory?
            if name.starts_with?('.')
              @skipped << Skipped.new(path + "/", "hidden folder")
            elsif top && INBOX_DIRS.includes?(name)
              @skipped << Skipped.new(path + "/", "inbox folder")
            else
              walk(path)
            end
          elsif info.file?
            @files += 1
            if name.starts_with?('.')
              @skipped << Skipped.new(path, "hidden file")
            else
              files << name
            end
          end
        end
        if files.includes?(OPF)
          calibre_folder(dir, files)
        else
          plain(dir, files)
        end
      end

      # the file system calls block the process: let the API in now and then
      private def tick
        @entries += 1
        Fiber.yield if @entries % YIELD_EVERY == 0
        @on_progress.try &.call(@files, @units.size) if @entries % PROGRESS_EVERY == 0
      end

      # the book files of a calibre folder are one book
      private def calibre_folder(dir : String, names : Array(String))
        books = [] of BookFile
        before = @already
        names.each do |name|
          next if name == OPF || name == COVER
          path = File.join(dir, name)
          (file = book_file(path)) && books << file
        end
        return if books.empty? && @already > before
        if books.empty?
          @skipped << Skipped.new(File.join(dir, OPF), "calibre folder without a book file")
          return
        end
        meta = begin
          OpfMeta.parse(File.read(File.join(dir, OPF)))
        rescue ex : XML::Error | File::Error | IO::Error | ArgumentError
          @skipped << Skipped.new(File.join(dir, OPF), "unreadable metadata.opf (#{ex.message}), formats imported as files")
          nil
        end
        unless meta
          books.each { |b| @units << Unit.new("file", dir, [b]) }
          return
        end
        cover = File.join(dir, COVER)
        @units << Unit.new("calibre", dir, books, File.file?(cover) ? cover : nil, meta)
      end

      # same name, other extension: formats of one book
      private def plain(dir : String, names : Array(String))
        groups = {} of String => Array(BookFile)
        names.each do |name|
          path = File.join(dir, name)
          file = book_file(path) || next
          stem = File.basename(name, File.extname(name))
          group = (groups[stem] ||= [] of BookFile)
          if group.any? { |b| b.format == file.format }
            groups["#{stem}\0#{name}"] = [file]
          else
            group << file
          end
        end
        groups.each_value { |files| @units << Unit.new("file", dir, files) }
      end

      # the file as a book, or nil after noting why not
      private def book_file(path : String) : BookFile?
        format = Scanner.format(path)
        unless format
          @skipped << Skipped.new(path, "not a book format")
          return nil
        end
        info = File.info(path)
        size = info.size
        mtime = info.modification_time.to_unix
        if (k = @known[path]?) && k[0] == size && k[1] == mtime
          @already += 1
          return nil
        end
        if problem = Scanner.problem(path, format, size)
          @skipped << Skipped.new(path, problem)
          return nil
        end
        BookFile.new(path, format, size, mtime)
      rescue ex : File::Error
        @skipped << Skipped.new(path, "unreadable (#{ex.message})")
        nil
      end
    end

    # a folder calibre named: "Title (12)"
    def self.calibre_name?(dir : String) : Bool
      File.basename(dir).matches?(/\s\(\d+\)\z/)
    end

    # A book for Dedup's rules from what is known of it
    def self.book(id : Int64, title : String, authors : Array(String), series : String? = nil,
                  series_index : Float64? = nil, identifiers = {} of String => String, publisher : String? = nil) : Book
      Book.new(id: id, title: title, authors: authors, author_sort: nil, tags: [] of String, series: series,
        series_index: series_index, formats: [] of String, last_modified: Time::UNIX_EPOCH, timestamp: nil,
        pubdate: nil, rating: nil, publisher: publisher, identifiers: identifiers, languages: [] of String,
        comments: nil, custom: {} of String => JSON::Any)
    end

    def self.book(id : Int64, meta : OpfMeta) : Book
      book(id, meta.title || "", meta.authors, meta.series, meta.series_index, meta.identifiers, meta.publisher)
    end

    # The library as the duplicate check sees it; books a run adds are added
    # to it, so a backlog with the same book twice adds it once. Titles,
    # authors and ISBNs are compared with Dedup's rules (normalization,
    # never different volumes, editions of a standard or numbers of a
    # series); a title needs an author in common and the same words
    # (TITLE_SIMILARITY), stricter than the duplicates page, where a person
    # decides on the looser matches. Only books in the library count:
    # files and checksums of books removed since (calibre's trash
    # included) are left out, they are no duplicates.
    class Index
      record Entry, book : Int64, path : String?

      # Dedup.similarity: 1 is the same title after normalization
      TITLE_SIMILARITY = 1.0

      @items = {} of Int64 => Dedup::Item
      @isbn = {} of String => Array(Int64)
      # Dedup's full title key -> books
      @titles = {} of String => Array(Int64)
      @formats = {} of Int64 => Set(String)
      @by_size = {} of Int64 => Array(Entry)
      @sums = {} of {Int64, String} => Int64
      @sum_sizes = Set(Int64).new
      @md5 = {} of String => {String, String}
      # the library's books and the ones a run added
      @ids = Set(Int64).new
      # pseudo ids of books a dry run would add -> their folder or file
      getter planned = {} of Int64 => String

      # library_files: {book, format, path, size}; checksums: {book, partial md5, size}
      def initialize(books : Array(Book), library_files = [] of {Int64, String, String, Int64},
                     checksums = [] of {Int64, String, Int64})
        books.each_with_index do |b, i|
          add_book(b)
          Fiber.yield if i % 256 == 255
        end
        library_files.each do |book, format, path, size|
          next unless @ids.includes?(book)
          (@formats[book] ||= Set(String).new) << format.upcase
          (@by_size[size] ||= [] of Entry) << Entry.new(book, path)
        end
        checksums.each do |book, md5, size|
          # file_checksums keeps the rows of books removed since
          next unless @ids.includes?(book)
          @sums[{size, md5}] = book
          @sum_sizes << size
        end
      end

      # From calibre-server and, when the hub can read the library, its
      # files and the checksums of files the hub rewrote
      def self.load(calibre : Calibre, library : String?, db : DB::Database) : Index
        books = calibre.list("")
        files = [] of {Int64, String, String, Int64}
        if library && File.file?(File.join(library, "metadata.db"))
          ldb = LibraryDB.open_read_only(File.join(library, "metadata.db"))
          begin
            ldb.query_each("select b.id, b.path, d.name, d.format, d.uncompressed_size from data d join books b on b.id = d.book") do |rs|
              id, dir, name, format, size = rs.read(Int64, String, String, String, Int64)
              files << {id, format, File.join(library, dir, "#{name}.#{format.downcase}"), size}
            end
          ensure
            ldb.close
          end
        end
        sums = [] of {Int64, String, Int64}
        begin
          db.query_each("select book_id, partial_md5, size from file_checksums") { |rs| sums << {rs.read(Int64), rs.read(String), rs.read(Int64)} }
        rescue ex : DB::Error | SQLite3::Exception
          # files the hub rewrote then match by title and author only
          STDERR.puts "import: no checksums of rewritten files: #{ex.message}"
        end
        Index.new(books, files, sums)
      end

      # the book is in the library (or a run added it)
      def exists?(id : Int64) : Bool
        @ids.includes?(id)
      end

      def add_book(b : Book)
        @ids << b.id
        (@formats[b.id] ||= Set(String).new).concat(b.formats.map(&.upcase))
        add_item(Dedup::Item.new(b))
      end

      # a book from a calibre folder's metadata.opf (added, or a dry run's pseudo id)
      def add_meta(id : Int64, meta : OpfMeta)
        @ids << id if id > 0
        add_item(Dedup::Item.new(Backlog.book(id, meta)))
      end

      private def add_item(item : Dedup::Item)
        @items[item.id] = item
        item.isbns.each do |i|
          list = @isbn[i] ||= [] of Int64
          list << item.id unless list.includes?(item.id)
        end
        return if item.title_key.empty?
        list = @titles[item.full_key] ||= [] of Int64
        list << item.id unless list.includes?(item.id)
      end

      def add_files(id : Int64, files : Array(BookFile))
        files.each do |f|
          (@formats[id] ||= Set(String).new) << f.format
          (@by_size[f.size] ||= [] of Entry) << Entry.new(id, f.path)
        end
      end

      def formats(id : Int64) : Set(String)
        @formats[id]? || Set(String).new
      end

      # The book that has this very file: same size, then the same
      # KOReader partial MD5 (all the hub keeps of files it rewrote) or, for
      # files at hand, that and the same first KiB, which the partial MD5
      # leaves out
      def same_file(f : BookFile) : Int64?
        entries = @by_size[f.size]?
        return nil if entries.nil? && !@sum_sizes.includes?(f.size)
        sum = md5(f.path) || return nil
        if found = @sums[{f.size, sum[0]}]?
          return found
        end
        entries.try &.each do |e|
          next if e.path == f.path
          return e.book if (p = e.path) && md5(p) == sum
        end
        nil
      end

      # {book, how}: another book with an ISBN of the item, or with its
      # title and an author in common; never another part (Dedup)
      def match_item(item : Dedup::Item) : {Int64, String}?
        item.isbns.each do |i|
          @isbn[i]?.try &.each do |id|
            next if id == item.id
            return {id, "isbn"} unless Dedup.different_parts?(item, @items[id])
          end
        end
        return nil if item.title_key.empty? || item.author_keys.empty?
        @titles[item.full_key]?.try &.each do |id|
          next if id == item.id
          other = @items[id]
          next unless item.author_keys.intersects?(other.author_keys)
          next if Dedup.different_parts?(item, other)
          return {id, "title"} if Dedup.similarity(item, other) >= TITLE_SIMILARITY
        end
        nil
      end

      # the book with this title and an author in common
      def by_title(title : String, authors : Array(String)) : Int64?
        hit = match_item(Dedup::Item.new(Backlog.book(0_i64, title, authors)))
        hit && hit[1] == "title" ? hit[0] : nil
      end

      # {book, how} for a unit, before adding
      def match(u : Unit) : {Int64, String}?
        u.files.each { |f| same_file(f).try { |id| return {id, "file"} } }
        u.meta.try { |m| match_item(Dedup::Item.new(Backlog.book(0_i64, m))) }
      end

      # {book, how} for a book calibre just added from a file, other than itself
      # the books the index has with this ISBN
      def isbn_books(isbn : String) : Array(Int64)
        @isbn[isbn]?.try(&.dup) || [] of Int64
      end

      def match_book(b : Book) : {Int64, String}?
        match_item(Dedup::Item.new(b))
      end

      # {partial MD5, MD5 of the first KiB}
      private def md5(path : String) : {String, String}?
        @md5[path] ||= begin
          head = Bytes.new(1024)
          n = File.open(path) { |io| io.read(head) }
          {BookFiles.partial_md5(path), Digest::MD5.hexdigest(head[0, n])}
        end
      rescue ex : File::Error | IO::Error
        # no file match for it, only title and author
        STDERR.puts "import: reading #{path} failed: #{ex.message}"
        nil
      end
    end

    # Fills a unit's plan from the index; true when it would add a book
    def self.plan(u : Unit, index : Index) : Bool
      u.action = "add"
      u.book_id = nil
      u.match = nil
      u.same_as = nil
      u.add_formats = [] of String
      found = index.match(u) || return true
      mark(u, found[0], found[1], index)
      false
    end

    # The unit is the book `id`: only what the library's book lacks
    def self.mark(u : Unit, id : Int64, how : String, index : Index)
      have = index.formats(id)
      missing = u.files.reject { |f| have.includes?(f.format) || index.same_file(f) }.map(&.format).uniq
      u.match = how
      if id < 0
        u.same_as = index.planned[id]?
      else
        u.book_id = id
      end
      u.action = missing.empty? ? "duplicate" : "addFormats"
      u.add_formats = missing
    end

    # Plans a scan: books it would add count for later ones; yields the
    # number of units planned now and then
    def self.plan_all(units : Array(Unit), index : Index, &progress : Int32 ->)
      units.each_with_index do |u, i|
        if i % 32 == 31
          progress.call(i + 1)
          Fiber.yield
        end
        next unless plan(u, index)
        pseudo = -(i.to_i64 + 1)
        index.planned[pseudo] = u.name
        u.meta.try { |m| index.add_meta(pseudo, m) }
        index.add_files(pseudo, u.files)
      end
      progress.call(units.size)
    end

    def self.plan_all(units : Array(Unit), index : Index)
      plan_all(units, index) { }
    end

    # The units a run imports (indexes): all, or with a limit the first in
    # scan order until `limit` of them add a book or formats; duplicates on
    # the way go along (the next run skips them), the rest waits for the
    # next run
    def self.take(units : Array(Unit), limit : Int32?) : Array(Int32)
      return (0...units.size).to_a unless limit
      taken = [] of Int32
      books = 0
      units.each_with_index do |u, i|
        break if books >= limit
        taken << i
        books += 1 unless u.action == "duplicate"
      end
      taken
    end

    # roots: the scanned folders; taken: Backlog.take's units with a limit
    def self.summary(units : Array(Unit), skipped : Array(Skipped), already : Int32, roots : Array(String) | String,
                     taken : Array(Int32)? = nil, limit : Int32? = nil) : JSON::Any
      roots = roots.is_a?(String) ? [roots] : roots
      formats = Hash(String, Int32).new(0)
      units.each { |u| u.files.each { |f| formats[f.format] += 1 } }
      dups = Hash(String, Int32).new(0)
      units.each { |u| dups[u.same_as ? "backlog" : u.match.not_nil!] += 1 if u.action == "duplicate" }
      by_reason = Hash(String, Int32).new(0)
      by_type = Hash(String, Int32).new(0)
      by_folder = {} of String => Hash(String, Int32)
      skipped.each do |s|
        reason = s.reason.sub(/ \(.*\z/, "")
        by_reason[reason] += 1
        by_type[s.path.ends_with?('/') ? "(folder)" : s.ext] += 1
        root = roots.select { |r| s.path.starts_with?(r.rstrip('/') + "/") }.max_by?(&.size) || ""
        rel = s.path.lchop(root).lchop('/')
        top = rel.includes?('/') ? rel.split('/').first : "."
        top = File.join(File.basename(root), top).chomp("/.") if roots.size > 1
        (by_folder[top] ||= Hash(String, Int32).new(0))[s.path.ends_with?('/') ? "(folder)" : s.ext] += 1
      end
      chosen = taken.try(&.map { |i| units[i] }) || units
      folders = by_folder.map { |f, types| {folder: f, count: types.values.sum, types: types.to_a.sort_by { |_, n| -n }.to_h} }
        .sort_by { |f| -f[:count] }.first(50)
      JSON.parse({
        books:           units.size,
        files:           units.sum(&.files.size),
        formats:         formats.to_a.sort_by { |_, n| -n }.to_h,
        calibreFolders:  units.count(&.kind.==("calibre")),
        plainFiles:      units.count(&.kind.==("file")),
        withCover:       units.count(&.cover),
        toAdd:           units.count(&.action.==("add")),
        toAddFormats:    units.count(&.action.==("addFormats")),
        duplicates:      {"total" => units.count(&.action.==("duplicate"))}.merge(dups),
        alreadyImported: already,
        limit:           limit,
        # what this run imports (everything without a limit)
        selected: {books: chosen.size, toAdd: chosen.count(&.action.==("add")),
                   toAddFormats: chosen.count(&.action.==("addFormats")), duplicates: chosen.count(&.action.==("duplicate"))},
        deferred: units.size - chosen.size,
        skipped:         {total: skipped.size, byReason: by_reason.to_a.sort_by { |_, n| -n }.to_h,
                  byType: by_type.to_a.sort_by { |_, n| -n }.to_h, byFolder: folders},
      }.to_json)
    end
  end
end
