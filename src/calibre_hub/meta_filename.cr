require "json"
require "uri"
require "./book"
require "./meta_rules"

module CalibreHub
  module Meta
    # Title, authors, series, publisher and year from the name of a book
    # file without metadata.opf (the backlog import), and what calibre's
    # add-book makes of the same name. calibre reads "Title - Author" (the
    # last " - " splits, "and"/"&" split authors), but most backlog files
    # are "Author - Title (Publisher, Year)": "Carr - Formulas and Theorems
    # in Pure Mathematics 2e (Chelsea, 1970).djvu" became the title "Carr"
    # by "Formulas" and "Theorems in Pure Mathematics 2e (Chelsea, 1970)".
    #
    # Which side of " - " is the person is decided by a name score (first
    # names, initials, "Last, First", surnames vs. title words, digits,
    # articles); a tie is decided by the other files of the folder (a
    # collection is named one way), else calibre's "Title - Author" stays.
    # Pure, so every rule is tested with real names (spec/filename_spec.cr).
    module FileName
      # calibre's sanitize_file_name replaces these with "_", and
      # metadata_from_filename every "_" with a space
      CALIBRE_UNSAFE = Set{'\\', '|', '?', '*', '<', '"', ':', '>', '+', '/'}
      CALIBRE_SPLIT  = /,?\s+(?:and|with)\s+/i
      UNKNOWN        = "Unknown"

      YEAR = "(?:1[5-9]|20)\\d\\d"
      # "(Chelsea, 1970)", "(Springer, 2006)"
      PUBLISHER_YEAR = /\s*\(([^()]*\p{L}[^()]*?),\s*(#{YEAR})\)\s*\z/
      # "(1974, Tonos)" (Clean::SUFFIX)
      YEAR_PUBLISHER = /\s*\((#{YEAR})?,\s*([^()]*\p{L}[^()]*)\)\s*\z/
      # "(1998)", "[2007]"
      YEAR_ONLY = /\s*[\(\[](?:(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+)?(#{YEAR})[\)\]]\s*\z/i
      # the libgen form "Title-Publisher (Year)": the publisher hangs on the title
      HUNG_COMPOUND = /(?<=\S)-((?:Addison|McGraw|Wiley|Springer|Prentice|Harcourt|Houghton|Farrar)-[^-]+?)\s*\z/
      HUNG          = /(?<=[\p{L}\p{N}).!?'’\]])\s*-([^-\s][^-]*?)\s*\z/
      # release tags and file junk at the end or the start
      TAIL_JUNK = /\s*(?:\b(?:WW|HQ|BW|PDF|EPUB|MOBI|DJVU|CHM|retail|e-?book(?:-\w+)?|iNT-TD|@Team\s+\w+)|[\[\(](?:html?|pdf|epub|djvu|chm|mobi|ebook|retail|scan|ocr)[\]\)]|\((?:German|English|Kindle|Deutsche|French|Spanish)\s+Edition\))\s*\z/i
      HEAD_JUNK = /\A\s*(?:\(\s*e-?book\b[^)]*\)|\w*e-?book\s*-)\s*/i
      ISBN_TAIL = /[\s-]((?:97[89][\s-]?)?\d{9}[\dXx])(?=\s*(?:\z|[\[\(]))/
      # "E.", "I.R", "H.S.M.", "J.-P."
      INITIAL = /\A\p{Lu}\.(?:-?\p{Lu}\.?)*\z/
      MONTHS  = "(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*"
      # abbreviated edition markers ("2e", "2nd ed.", "3. Aufl.", "(4th
      # Edition)"); a spelled out "Second Edition" is part of the title
      EDITION = /(?:,\s*|\s+)(?:\d{1,2}(?:st|nd|rd|th|d)?\.?\s*(?:ed|aufl)\.?|\d{1,2}e|[\(\[]\d{1,2}(?:st|nd|rd|th|d)?\.?\s*(?:ed(?:ition)?|aufl(?:age)?)\.?[\)\]])(?=\s|\z|[,:\[\(\]])/i
      # the publishers' short names in the "(Publisher, Year)" collections
      PUBLISHER_NAMES = {"AW" => "Addison-Wesley", "AP" => "Academic Press", "MIT" => "MIT Press",
                         "AMS" => "American Mathematical Society", "CRC" => "CRC Press", "WS" => "World Scientific",
                         "World" => "World Scientific", "Cambridge" => "Cambridge University Press",
                         "Oxford" => "Oxford University Press", "Princeton" => "Princeton University Press",
                         "Prentice" => "Prentice Hall", "McGraw" => "McGraw-Hill", "Wiley-VCH" => "Wiley-VCH"}
      # "(ed)", "(eds.)", "(auth.)", "(Hrsg.)", "et al." mark persons
      PERSON_MARK = /\s*(?:\((?:eds?|editors?|auth|hrsg|hg|ed\.?\s*by)\.?\)|,?\s+et\s+al?\.?,?|,?\s+\(?eds?\.\)?)(?=\s|\z|,)/i
      # a part's trailing number: "Stephanie Plum 05", "Sten 03"
      SERIES_NUMBER = /\A(.+?)\s+#?(\d{1,3}(?:\.\d+)?)\z/
      # "_ " stood for ":" (title) or ";" (authors) in libgen names
      MARK = '\u0001'

      # words in publishers' names, and publishers named alone
      PUBLISHER_WORDS = Set{"press", "publishing", "publications", "publication", "publishers", "publisher", "books",
                            "media", "verlag", "verl", "verlagsgruppe", "inc", "llc", "ltd", "gmbh", "co", "company",
                            "group", "house", "learning", "university", "editions", "professional", "hall", "wesley",
                            "hill", "academic", "sciences", "science", "wissenschaftsverlag", "ag", "corp",
                            "corporation", "pub", "pubs", "paperbacks", "classics", "trade", "hardcover", "adult"}
      PUBLISHERS = Set{"apress", "packt", "wiley", "springer", "pearson", "elsevier", "portfolio", "viking", "picador",
                       "gotham", "transworld", "doubleday", "heinemann", "bloomsbury", "ullstein", "fischer", "razeware",
                       "pragmatic", "harperbusiness", "harpercollins", "harper", "penguin", "routledge", "crc", "sybex",
                       "wrox", "manning", "dover", "vintage", "anchor", "crown", "scribner", "knopf", "hanser", "rowohlt",
                       "goldmann", "heyne", "piper", "droemer", "kosmos", "campus", "redline", "riva", "haufe", "gabler",
                       "vahlen", "rheinwerk", "galileo", "mitp", "dpunkt", "vieweg", "teubner", "oldenbourg", "cornelsen",
                       "duden", "langenscheidt", "klett", "diogenes", "suhrkamp", "reclam", "dtv", "aufbau", "insel",
                       "o'reilly", "o’reilly", "oreilly", "o'relly", "nostarch", "sams", "que", "cengage", "macmillan",
                       "norton", "hachette", "random", "simon", "createspace", "chelsea", "aw", "mit", "ap",
                       "cambridge", "oxford", "princeton", "yale", "harvard", "chicago", "blackwell", "kluwer", "birkhauser",
                       "birkhäuser", "dummies", "newnes", "delmar", "prentice", "mcgraw", "addison", "borland", "imperial",
                       "infinity", "premier", "pfeiffer", "capstone", "rodale", "puffin", "picador", "macgraw", "tor",
                       "baen", "ace", "daw", "orbit", "gollancz", "bantam", "ballantine", "del rey", "jossey", "bass"}
      # words of titles, never of names (lower case, folded)
      TITLE_NOUNS = Set{"introduction", "guide", "handbook", "manual", "programming", "mathematics", "mathematical",
                        "engineering", "theory", "principles", "systems", "system", "design", "data", "science",
                        "history", "art", "language", "languages", "learning", "computer", "computers", "computing",
                        "network", "networks", "algorithms", "algorithm", "analysis", "methods", "method",
                        "applications", "practice", "practical", "development", "management", "business", "physics",
                        "chemistry", "biology", "economics", "encyclopedia", "encyclopaedia", "dictionary", "cookbook",
                        "essentials", "fundamentals", "basics", "advanced", "modern", "complete", "applied", "structures",
                        "processing", "recognition", "graphics", "game", "games", "music", "piano", "sonata", "songs",
                        "song", "symphony", "concerto", "quartet", "violin", "guitar", "jazz", "book", "books", "notes",
                        "course", "lectures", "lecture", "tutorial", "reference", "primer", "workbook", "atlas",
                        "survival", "secrets", "secret", "world", "life", "mind", "brain", "story", "stories", "tales",
                        "war", "wars", "night", "nights", "time", "rules", "techniques", "skills",
                        "ideas", "thinking", "machine", "intelligence", "artificial", "neural", "logic", "software",
                        "hardware", "electronics", "electronic", "electrical", "digital", "signal", "statistics",
                        "statistical", "probability", "calculus", "algebra", "geometry", "trigonometry", "formulas",
                        "theorems", "equations", "functions", "models", "model", "patterns", "pattern", "testing",
                        "security", "cryptography", "linux", "unix", "windows", "python", "java", "ruby", "haskell",
                        "javascript", "web", "internet", "database", "databases", "sql", "server", "cloud",
                        "your", "you", "my", "our", "their", "his", "her", "its", "we", "this", "that", "what", "who",
                        "woodworking", "networking", "wireless", "compilers", "compiler", "architecture", "health", "medicine", "medical", "anatomy", "psychology", "philosophy",
                        "religion", "politics", "political", "social", "society", "culture", "power", "money",
                        "finance", "marketing", "sales", "selling", "leadership", "success", "strategy", "strategies",
                        "einführung", "handbuch", "grundlagen", "geschichte", "praxis", "technik", "mathematik",
                        "physik", "informatik", "programmierung", "lehrbuch", "kompendium", "anleitung", "leitfaden",
                        "übungen", "aufgaben", "lösungen", "prüfung", "prüfungen", "kochbuch", "roman", "erzählungen",
                        "gedichte", "lieder", "handbook", "volume", "vol", "band", "teil", "part", "edition", "series",
                        "collection", "complete", "selected", "works", "essays", "letters", "studies", "study",
                        "exercises", "problems", "solutions", "questions", "answers", "test", "exam", "cycle", "saga",
                        "chronicles", "trilogy", "quest", "adventure", "adventures", "mystery", "murder", "death",
                        "dead", "man", "men", "woman", "women", "children", "child",
                        "dragon", "dragons", "magic", "star", "stars", "planet", "universe", "space", "earth", "fire",
                        "water", "dark", "darkness", "light", "shadow", "shadows", "blood", "city",
                        "road", "sea", "island"}
      # common first names (folded), the strongest sign of a person
      FIRST_NAMES = Set{
        "aaron", "adam", "adrian", "alan", "albert", "alex", "alexander", "alfred", "ali", "alice", "alison", "allan",
        "amanda", "amy", "andre", "andrea", "andreas", "andrew", "andy", "angela", "ann", "anna", "anne", "anthony",
        "anton", "arthur", "barbara", "barry", "ben", "benjamin", "bernard", "bernd", "bill", "bob", "brad", "brian",
        "bruce", "bruno", "carl", "carlos", "carol", "caroline", "catherine", "charles", "charlie", "chris",
        "christian", "christina", "christine", "christoph", "christopher", "claire", "claude", "claudia", "colin",
        "craig", "dale", "dan", "daniel", "dave", "david", "dean", "dennis", "derek", "diana", "dieter", "dirk",
        "dominik", "don", "donald", "doris", "douglas", "edward", "elizabeth", "ellen", "emily", "emma", "eric", "erich",
        "erik", "ernst", "eva", "frank", "franz", "fred", "frederick", "friedrich", "gabriel", "gary", "gene", "george",
        "georg", "gerald", "gerhard", "gordon", "graham", "greg", "gregory", "gunter", "günter", "hans", "harald",
        "harold", "harry", "heinrich", "heinz", "helen", "helmut", "henry", "herbert", "hermann", "howard", "ian",
        "isaac", "jack", "jacob", "james", "jan", "jane", "janet", "jason", "jean", "jeff", "jeffrey", "jennifer",
        "jens", "jeremy", "jerry", "jim", "joan", "joe", "johann", "johannes", "john", "jon", "jonathan", "jordan",
        "jorg", "jörg", "joseph", "josh", "joshua", "juan", "judith", "julia", "julian", "julie", "jurgen", "jürgen",
        "karen", "karl", "kate", "katherine", "kathrin", "keith", "ken", "kenneth", "kent", "kevin", "klaus", "kurt",
        "larry", "laura", "lawrence", "lee", "leo", "leonard", "lewis", "linda", "lisa", "louis", "luca", "lucas",
        "luke", "lutz", "manfred", "marc", "marcus", "margaret", "maria", "marie", "mark", "markus", "martin", "mary",
        "matt", "matthew", "matthias", "max", "michael", "michel", "michelle", "mike", "monika", "nancy", "neil",
        "nicholas", "nick", "nicole", "nigel", "norbert", "norman", "oliver", "oscar", "otto", "pam", "pamela",
        "patricia", "patrick", "paul", "peter", "petra", "phil", "philip", "philipp", "pierre", "rachel", "ralf",
        "ralph", "randall", "ray", "raymond", "rebecca", "reinhard", "richard", "rick", "rob", "robert", "robin",
        "roger", "roland", "ron", "ronald", "rose", "roy", "rudolf", "russell", "ruth", "ryan", "sabine", "sally",
        "sam", "samuel", "sandra", "sandi", "sarah", "scott", "sean", "sebastian", "simon", "sophie", "stefan",
        "stephan", "stephanie", "stephen", "steve", "steven", "stuart", "susan", "suzanne", "terry", "theodor",
        "thomas", "tim", "timothy", "tobias", "todd", "tom", "tony", "ulrich", "ursula", "uwe", "victor", "vincent",
        "walter", "wayne", "werner", "william", "wolfgang", "yuri", "elmore", "dean", "julian", "orson", "isaac",
        "arthur", "ray", "philip", "terry", "neal", "dan", "iain", "ursula", "frank", "kim", "jez", "gene", "avdi",
        "sandi", "kent", "alistair", "erich", "dale", "brene", "nassim", "malcolm", "yuval", "jared", "noam",
        "jeffery", "morgan", "clive", "bram", "drew", "kay", "imran", "didier", "henri", "melanie", "mitch", "edith", "jules", "jonathan", "patricia", "anne",
        "harry", "fred", "larry", "greg", "tanith", "simon", "eric", "neal", "les", "laura", "rachel", "nina",
        "jeremy", "vivian", "cindy", "erik", "dmitry", "igor", "joseph", "clifford", "guy", "nils", "juan",
        "marcel", "jacques", "francois", "françois", "jose", "josé", "luis", "carlo", "giovanni", "giuseppe",
        "marco", "paolo", "pablo", "sergei", "sergey", "vladimir", "ivan", "olga", "natalia", "elena", "irina",
        "hiroshi", "takeshi", "kenji", "akira", "raj", "ravi", "amit", "deepak", "sanjay", "wei", "li", "jun",
        "hans-peter", "karl-heinz", "jean-paul", "jean-pierre", "anna-lena", "lars", "sven", "nils", "bjorn",
        "björn", "magnus", "johan", "kristian", "henrik", "ole", "mats", "pieter", "willem", "hendrik", "kees",
        "brandon", "tyler", "kyle", "zach", "zachary", "nathan", "aaron", "evan", "ethan", "dylan", "logan",
        "chad", "troy", "dustin", "kirk", "lance", "glenn", "dwight", "earl", "floyd", "clyde", "vernon",
        "ernest", "eugene", "francis", "herman", "irving", "lester", "lloyd", "milton", "morris", "murray",
        "nelson", "philip", "ralph", "sidney", "stanley", "wallace", "warren", "wilbur", "alice", "agatha",
        "betty", "beverly", "carolyn", "cheryl", "cynthia", "deborah", "donna", "dorothy", "frances", "gloria",
        "heather", "jessica", "joyce", "judy", "kathleen", "kathryn", "kelly", "kimberly", "lori", "marilyn",
        "martha", "megan", "melissa", "mildred", "norma", "phyllis", "sharon", "shirley", "teresa", "theresa",
        "tina", "virginia", "wendy", "diane", "janice", "jean", "lois", "louise", "marjorie", "peggy", "robin",
        "sylvia", "terri", "toni", "vicki", "agnes", "edna", "ethel", "hazel", "ida", "irene", "lillian",
        "mabel", "nora", "pearl", "rosa", "stella", "vera", "viola", "orson", "isaac", "ray", "poul", "gordon",
        "arthur", "kurt", "kim", "iain", "connie", "lois", "octavia", "ursula", "frederik", "frederic", "hal",
        "alfred", "cordwainer", "theodore", "clifford", "fritz", "ward", "dean", "piers", "terry", "terence",
      }
      PARTICLES = Set{"van", "von", "der", "den", "de", "du", "da", "di", "del", "della", "le", "la", "ten", "ter", "dos", "y", "zu", "bin", "al"}

      # What calibre's add-book makes of the file name when the file has
      # no metadata of its own: metadata_from_filename with the default
      # pattern "(?P<title>.+) - (?P<author>[^_]+)" and string_to_authors
      def self.calibre(name : String) : {String, Array(String)}
        n = calibre_sanitize(File.basename(name))
        dot = n.rindex('.')
        n = dot ? n[0, dot] : ""
        n = n.gsub('_', ' ')
        title = n
        authors = [] of String
        if m = n.match(/\A(.+) - ([^_]+)/m)
          title = m[1]
          raw = m[2].gsub("&&", "\u{FFFF}").gsub(CALIBRE_SPLIT, "&")
          authors = raw.split('&').map { |a| a.strip.gsub('\u{FFFF}', '&') }.reject(&.empty?)
        end
        title = UNKNOWN if title.empty?
        {title, authors.empty? ? [UNKNOWN] : authors}
      end

      private def self.calibre_sanitize(name : String) : String
        one = name.chars.map { |c| CALIBRE_UNSAFE.includes?(c) || c.ord < 32 ? '_' : c }.join
        one = one.gsub(/\s/, " ").strip
        ext = File.extname(one)
        base = one[0, one.size - ext.size]
        base = "_" if base.matches?(/\A\.+\z/)
        one = base.gsub("..", "_") + ext
        one = one[0..-2] + "_" if one.ends_with?('.') || one.ends_with?(' ')
        one = "_" + one[1..] if one.starts_with?('.')
        one
      end

      # Same text as calibre stores it (spaces trimmed and squeezed)
      def self.same_text?(a : String?, b : String?) : Bool
        squeeze(a) == squeeze(b)
      end

      def self.same_authors?(a : Array(String), b : Array(String)) : Bool
        a.size == b.size && a.zip(b).all? { |x, y| same_text?(x, y) }
      end

      private def self.squeeze(s : String?) : String
        (s || "").gsub(/\s+/, " ").strip
      end

      # A title a file brought along that says nothing about the book:
      # "chap01 7..24", "100767", "Less 0375505784 4p Fm R1.Qxd",
      # "logik-stud.dvi", "file:///F|/…", "test", "untitled", "()"
      def self.bad_title?(t : String) : Bool
        s = t.strip
        # "1984", "2001"
        return false if s.matches?(/\A\d{1,4}\z/)
        return true if s.count(&.letter?) < 3
        return true if s.matches?(/\A(?:test|untitled|unbenannt|title|titel|unknown|document|dokument|cover|book\d*|doc\d*|new document|microsoft word.*|chap(?:ter)?\s*\d.*|ch\d+.*|\S+\.(?:dvi|docx?|indd|qxd|tex|ps|rtf|html?|pdf|p65|pm\d|fm|wpd|txt))\z/i)
        return true if s.matches?(/\A(?:file|https?):\//i) || s.matches?(/\.(?:qxd|indd|dvi|p65)\b/i)
        # mostly digits and codes: "0375505784 4p Fm R1"
        s.count(&.ascii_number?) > s.count(&.letter?)
      end

      # Which side of " - " the folder's files name the author: :first,
      # :last, or nil when they don't agree clearly (at least two clear
      # names, two thirds of them one way)
      def self.orientation(names : Enumerable(String)) : Symbol?
        first = last = 0
        names.each do |n|
          case clear_side(n)
          when :first then first += 1
          when :last  then last += 1
          end
        end
        total = first + last
        return nil if total < 2
        return :first if first * 3 >= total * 2
        return :last if last * 3 >= total * 2
        nil
      end

      # the side of a name with a strong person on it, nil when unclear
      private def self.clear_side(name : String) : Symbol?
        n = prepare(name) || return nil
        parts = split_parts(n[0])
        return nil if parts.size < 2
        sf, sl = side_score(parts.first), side_score(parts.last)
        return :first if sf >= 2 && sf > sl
        return :last if sl >= 2 && sl > sf
        nil
      end

      # The reading of the file name: title, authors (empty when the name
      # has none), series and number, publisher, year (Guess#year and
      # #pubdate). hint: the folder's orientation (orientation).
      def self.parse(name : String, hint : Symbol? = nil) : Guess?
        prepared = prepare(name) || return nil
        s, publisher, year, paren_author, libgen = prepared
        # libgen names put the authors first
        hint ||= :first if libgen
        series = nil
        index = nil.as(Float64?)
        # "(For Dummies) John Paul Mueller - Deep Learning for Dummies": a
        # series in front of the authors (libgen)
        if (m = s.match(/\A\(([^()]+)\)\s+(.+\s[-–]\s.+)\z/)) && side_score(m[2].split(/\s+[-–]\s+/).first) >= 1
          series, index = series_index(m[1])
          s = m[2]
        end
        # "6. Jared Diamond - Guns, Germs and Steel": a number in a list
        s = s.sub(/\A\d{1,3}\.\s+(?=.+\s[-–]\s)/, "")
        parts = split_parts(s)
        # "07 - Compilers - Principles…": a number in a list of files
        parts.shift if parts.size >= 2 && parts.first.matches?(/\A\d{1,3}\.?\z/)
        # "O'Reilly - Server Load Balancing", "CRC Press - Dictionary … - D. Clark"
        if parts.size >= 2 && known_publisher?(parts.first)
          publisher ||= parts.first
          parts.shift
        end
        authors = [] of String
        rest = parts
        if parts.size >= 2
          sf, sl = side_score(parts.first), side_score(parts.last)
          side = if hint && sf == sl && sf >= 0
                   # a tie: as the folder's other files
                   hint
                 elsif sf >= 1 && sf >= sl
                   :first
                 elsif libgen && sf >= 0 && sf > sl
                   # "Morgan Housel - The Psychology of Money-Harriman House (2020)"
                   :first
                 elsif sl >= 1 && sl > sf
                   :last
                 elsif sf == 0 && sl == 0
                   # can't tell: calibre's "Title - Author" stays
                   :last
                 elsif sl == 0 && sf <= -2 && parts.first.split(' ').size >= 2 && !parts.last.matches?(/\s(?:and|und)\s/i)
                   # "An Introduction to Genetic Algorithms - Melanie Mitchell"
                   :last
                 end
          if side == :first
            authors = split_authors(parts.first)
            rest = parts[1..]
          elsif side == :last
            authors = split_authors(parts.last)
            rest = parts[0..-2]
          end
        end
        # "Author - Series 03 - Title": the part before the title with a number
        if rest.size >= 2 && !authors.empty? && series.nil?
          (0...rest.size - 1).each do |i|
            m = rest[i].match(SERIES_NUMBER) || next
            next unless i == 0 || m[2].starts_with?('0')
            next if Text.tokens(m[1]).any? { |w| %w(vol volume band teil part op no nr).includes?(w) }
            series = (rest[0...i] + [m[1]]).join(" - ")
            index = m[2].to_f
            rest = rest[(i + 1)..]
            break
          end
        end
        if authors.empty? && (pa = paren_author)
          authors = split_authors(pa)
        end
        # "… - 3rd edition": a part that is only the edition
        rest = rest.reject { |p| p.matches?(/\A\(?\d{1,2}(?:st|nd|rd|th|d)?\.?\s*(?:ed(?:ition)?|aufl(?:age)?)\.?\)?\z/i) } if rest.size > 1
        title = finish_title(rest.join(" - "))
        if authors.empty? && rest.size == 1 && (m = title.match(/\A(.+?)\s+by\s+(.+)\z/i)) && side_score(m[2]) >= 2
          title = m[1]
          authors = split_authors(m[2])
        end
        # "Tested Advertising Methods (Business Classics Series)"
        if series.nil? && (m = title.match(/\A(.+?)\s*\(([^()]*\bSeries\b[^()]*)\)\z/i))
          title = m[1]
          series, index = series_index(m[2])
        end
        return nil if title.empty?
        authors = authors.map { |a| Clean.fix_name_case(a) }.reject { |a| a.empty? || Clean.unknown_author?(a) }.uniq { |a| Text.key(a) }
        publisher = publisher.try { |p| PUBLISHER_NAMES[p]? || p }
        Guess.new(title, authors, series.try(&.strip), series ? index : nil, year, "rules", publisher, year.try(&.to_s))
      end

      # {stem without junk and suffixes, publisher, year, an author in
      # trailing parentheses}; nil for a standard (Norms reads calibre's split)
      private def self.prepare(name : String) : {String, String?, Int32?, String?, Bool}?
        s = File.basename(name)
        s = s.sub(/\.[A-Za-z0-9]{2,5}\z/, "")
        return nil if s.matches?(Norms::FILE_NAME)
        s = s.unicode_normalize.gsub(/[\x{FEFF}\x{200B}-\x{200D}\x{2060}]/, "")
        s = URI.decode(s) if s.includes?("%20")
        scene = false
        if !s.includes?(' ')
          s = s.gsub('_', ' ')
          if !s.includes?(' ') && s.count('.') >= 2 && !s.matches?(/\A(?:\p{L}\.)+\z/)
            # "Wiley.Knowledge.Based.Bioinformatics.Sep.2010.eBook-ELOHiM"
            s = s.gsub('.', ' ')
            scene = true
          end
          s = s.gsub('-', ' ') if !s.includes?(' ') && s.count('-') >= 2 && s.each_char.select(&.letter?).all?(&.lowercase?)
        else
          # "Dirk W_" was "Dirk W." (no dot at the end of a file name)
          s = s.gsub(/(?<=\s\p{Lu})_(?=\s*(?:\z|[-,(]))/, ".")
          s = s.gsub("_ ", "#{MARK} ")
          s = s.gsub('_', ' ')
        end
        s = s.gsub(/\s+/, " ").strip
        # "Medtner (1880 - 1951) - Piano Quintet": life dates
        s = s.gsub(/\s*\((?:1[5-9]|20)\d\d\s*-\s*(?:(?:1[5-9]|20)\d\d)?\)/, "")
        # Clean::JUNK without its "(1)" copy marker, which would take a "(1998)"
        Clean::JUNK[0..-2].each { |j| s = s.gsub(j, "") }
        s = s.sub(/\s*[\(\[](?:\d{1,2}|copy|kopie)[\)\]]\s*\z/i, "")
        s = s.sub(HEAD_JUNK, "").sub(/-(?:en|de|eng|ger|deu)\z/, "")
        publisher = nil.as(String?)
        year = nil.as(Int32?)
        author = nil.as(String?)
        libgen = false
        if scene
          s = s.sub(TAIL_JUNK, "")
          if m = s.match(/\s(?:#{MONTHS}\s)?(#{YEAR})\z/i)
            year = m[1].to_i
            s = s[0, m.begin(0)]
          end
          if (m = s.match(/\A(\S+(?:\s(?:University|Press|Publishing|Media|Verlag))*)\s(.+)\z/)) && PUBLISHERS.includes?(Text.fold(m[1].split(' ').first))
            publisher = m[1]
            s = m[2]
          end
        end
        8.times do
          before = s
          s = s.sub(TAIL_JUNK, "").strip
          if (m = s.match(ISBN_TAIL)) && Isbn.normalize(m[1])
            s = s[0, m.begin(0)].strip
          end
          # "P. Addison 1997)": a year whose "(" got lost
          if year.nil? && (m = s.match(/\s(#{YEAR})\)\z/)) && s.count('(') < s.count(')')
            year = m[1].to_i
            s = s[0, m.begin(0)].strip
          end
          if year.nil? && (m = s.match(PUBLISHER_YEAR)) && !m[1].matches?(/\d/)
            publisher ||= m[1].strip
            year = m[2].to_i
            s = s.sub(m[0], "")
          elsif year.nil? && (m = s.match(YEAR_PUBLISHER))
            year = m[1]?.try(&.to_i)
            publisher ||= m[2].strip
            s = s.sub(m[0], "")
          elsif year.nil? && (m = s.match(YEAR_ONLY))
            year = m[1].to_i
            s = s.sub(m[0], "")
            if publisher.nil? && (p = hung_publisher(s))
              publisher, s = p
              libgen = true
            end
          elsif publisher.nil? && (m = s.match(/\s*\[([^\[\]]+)\]\s*\z/)) && publisher?(m[1])
            publisher = m[1].strip
            s = s.sub(m[0], "")
          elsif publisher.nil? && s.matches?(/\s[-–]\s/) && (p = hung_publisher(s, strict: true))
            publisher, s = p
            libgen = true
          elsif publisher.nil? && (m = s.match(/\s*\(([^()]+)\)\s*\z/)) && known_publisher?(m[1])
            # "Java 3D Programming (Manning)"
            publisher = m[1].strip
            s = s.sub(m[0], "")
          elsif author.nil? && (m = s.match(/\s*[\(\[]by\s+([^()\[\]]+)[\)\]]\s*\z/i)) && side_score(m[1]) >= 1
            # "Basic Engineering Mathematics [by John Bird]"
            author = m[1]
            s = s.sub(m[0], "")
          elsif author.nil? && (m = s.match(/\s*\(([^()]+)\)\s*\z/)) && side_score(m[1]) >= 2 && !s.sub(m[0], "").matches?(/\s[-–]\s/)
            author = m[1]
            s = s.sub(m[0], "")
          end
          s = s.strip.rstrip("-–,;: ").strip
          break if s == before
        end
        s = s.lstrip("-–,;: ").strip
        return nil if s.empty?
        {s, publisher.try { |p| p.gsub(MARK, ":").gsub(/\s+/, " ").strip.rstrip(",").strip }.presence, year, author, libgen}
      end

      # "Title-Wiley" -> {"Wiley", "Title"} when the hung part is a publisher
      private def self.hung_publisher(s : String, strict = false) : {String, String}?
        if m = s.match(HUNG_COMPOUND)
          return {m[1].strip, s[0, m.begin(0)]}
        end
        m = s.match(HUNG) || return nil
        seg = m[1].strip
        return nil unless strict ? PUBLISHERS.includes?(Text.fold(seg.split(' ').first)) : publisher?(seg)
        {seg, s[0, m.begin(0)]}
      end

      # a publisher by name: "O'Reilly", "CRC Press", "Sams Publishing"
      def self.known_publisher?(s : String) : Bool
        words = s.downcase.split(/[\s,.]+/).reject(&.empty?)
        return false if words.empty? || words.size > 3
        PUBLISHERS.includes?(words.first) && words[1..].all? { |w| PUBLISHER_WORDS.includes?(w) }
      end

      def self.publisher?(s : String) : Bool
        words = s.downcase.split(/[\s,.]+/).reject(&.empty?)
        return false if words.empty? || words.size > 6 || s.matches?(/\A\d/)
        return true if PUBLISHERS.includes?(words.first) || PUBLISHERS.includes?(words.join(" "))
        return true if words.size <= 4 && words.any? { |w| PUBLISHERS.includes?(w) }
        return true if words.any? { |w| PUBLISHER_WORDS.includes?(w) }
        # one word with a capital inside: "HarperBusiness", "ShipRise"
        words.size == 1 && s.strip.matches?(/\A\p{Lu}\p{Ll}+\p{Lu}\p{L}+\z/)
      end

      private def self.split_parts(s : String) : Array(String)
        s.split(/\s+[-–—]{1,2}\s+/).map(&.strip).reject(&.empty?)
      end

      private def self.series_index(s : String) : {String, Float64?}
        if m = s.match(/\A(.+?),?\s+(\d{1,3})\z/)
          {m[1].strip, m[2].to_f}
        else
          {s.strip, nil}
        end
      end

      private def self.finish_title(t : String) : String
        t = t.gsub(MARK, ":")
        t = t.gsub(/(?<=\p{L})- (?=\p{Lu})/, ": ")
        t = t.gsub(EDITION, "")
        t = Clean.strip_junk(t)
        # "Eyes of the Dragon, The"
        if m = t.match(/\A(.+),\s+(The|A|An|Der|Die|Das|Le|La|Les)\z/)
          t = "#{m[2]} #{m[1]}"
        end
        t = t.gsub(/\s+:/, ":").gsub(/:(?=\S)/, ": ").gsub(/\s+/, " ").strip.rstrip(":,;").strip
        t = Clean.fix_title_case(t)
        # "the Last Precinct"
        words = t.split(' ')
        t = t.sub(/\A\p{Ll}/, &.upcase) if words.size >= 2 && Clean::SMALL.includes?(words.first) && words[1..].any? { |w| w[0].uppercase? }
        t
      end

      # How much a side of " - " looks like the author(s): > 0 a person,
      # <= 0 a title. Several names: the weakest counts.
      def self.side_score(s : String) : Int32
        mark = s.matches?(PERSON_MARK) ? 2 : 0
        t = names_text(s)
        return -3 if t.empty? || t.matches?(/[!?:\d]/)
        pieces = split_names(t)
        return -3 if pieces.empty?
        several = pieces.size > 1
        # "A & B", "A, B", "A; B" are names; "Speech and Language" may be a title
        listed = several && t.matches?(/[&;,#{MARK}]/)
        scores = pieces.map { |p| piece_score(p, several && !listed) }
        inverted = !several && t.count(',') == 1 && inverted?(t)
        (scores.min + mark + (inverted ? 2 : 0) + (listed && scores.min >= 0 ? 1 : 0)).clamp(-9, 9)
      end

      # an author side without "(ed)", "et al." and the like, "J.Vince" as "J. Vince"
      private def self.names_text(s : String) : String
        s.gsub(PERSON_MARK, " ").gsub(/\s*\([^()]*\)\s*/, " ").gsub(/[\[\]]/, " ").gsub(/(?<=\b\p{Lu})\.(?=\p{Lu}\p{Ll})/, ". ").gsub(/\s+/, " ").strip
      end

      private def self.article?(s : String) : Bool
        first = s.split(' ', 2).first
        !first.matches?(INITIAL) && Clean::ARTICLES.includes?(Text.fold(first))
      end

      private def self.piece_score(p : String, several : Bool) : Int32
        tokens = p.split(/\s+/).reject(&.empty?)
        return -3 if tokens.empty? || tokens.size > 5
        tokens = [tokens.first.rstrip('.')] if tokens.size == 1 && tokens.first.size > 2
        initials = tokens.map { |w| w.matches?(INITIAL) || w.matches?(/\A\p{Lu}\z/) }
        folded = tokens.map { |w| Text.fold(w).strip(",.") }
        return -3 if known_publisher?(p) && !FIRST_NAMES.includes?(folded.first)
        score = 0
        score += 2 if tokens.size >= 2 && initials.any?
        score += 2 if folded.any? { |w| FIRST_NAMES.includes?(w) } && tokens.size >= 2 || (tokens.size == 1 && several && FIRST_NAMES.includes?(folded.first))
        titles = folded.each_with_index.count { |w, i| !initials[i] && (TITLE_NOUNS.includes?(w) || Clean::TITLE_WORDS.includes?(w)) }
        score -= 2 * titles
        if tokens.size == 1
          w = tokens.first
          surname = w.matches?(/\A(?:Mc|Mac|O['’]|D['’]|De|Di|Da|Du|La|Le|Van|Von)?\p{Lu}\p{Ll}+(?:[-'’]\p{Lu}\p{Ll}+)?\z/) && titles == 0
          score += surname ? 1 : -1
          score -= 1 if several && surname
        else
          score -= 1 if tokens.size > 3
          lower = tokens.count { |w| w[0].lowercase? && !PARTICLES.includes?(w.downcase) }
          mixed = tokens.any? { |w| w[0].uppercase? }
          score -= 2 * lower if mixed
          score -= 3 if article?(p)
          # all caps words that aren't initials: acronyms ("GAMP", "SQL")
          score -= 2 if tokens.any? { |w| w.size >= 3 && w.matches?(/\A\p{Lu}+\z/) } && !Clean.broken_case?(p)
        end
        score
      end

      # "Last, First": one comma, the part after it a first name or initials
      private def self.inverted?(s : String) : Bool
        before, after = s.split(',', 2).map(&.strip)
        a = after.split(/\s+/).reject(&.empty?)
        b = before.split(/\s+/).reject(&.empty?)
        return false if a.empty? || b.empty? || a.size > 3 || b.size > 3
        # "John Caples, Fred E. Hahn": a full name before the comma
        return false if b.size >= 2 && (FIRST_NAMES.includes?(Text.fold(b.first)) || b.first.matches?(/\A\p{Lu}\.\z/))
        # "Cussler, Clive", but not "Auer,Miller"
        return true if a.size == 1 && b.size == 1 && s.matches?(/,\s/) && a.first.matches?(/\A\p{Lu}\p{Ll}+\z/) && b.first.matches?(/\A\p{Lu}\p{Ll}+\z/)
        a.any?(&.matches?(INITIAL)) || FIRST_NAMES.includes?(Text.fold(a.first))
      end

      # A side's names: "A & B", "A and B", "A; B", "A_ B", "A, B, C"
      # (full names), "Last, First" stays one
      private def self.split_names(s : String) : Array(String)
        pieces = s.split(/\s*[;#{MARK}]\s*|\s+&\s+|,?\s+(?:and|und)\s+/i).map(&.strip).reject(&.empty?)
        pieces.flat_map do |p|
          next [p] unless p.includes?(',')
          commas = p.split(',').map(&.strip).reject(&.empty?)
          if commas.size == 2 && inverted?(p)
            [p]
          elsif commas.size >= 2 && commas.all? { |c| c.split(/\s+/).size >= 2 }
            commas
          elsif commas.size >= 4 && commas.size.even? && commas.each_slice(2).all? { |pair| inverted?(pair.join(", ")) }
            # "Jander, Johannes, Passig, Kathrin"
            commas.each_slice(2).map(&.join(", ")).to_a
          else
            commas
          end
        end
      end

      # the names of an author side, "Last, First" turned round
      def self.split_authors(s : String) : Array(String)
        split_names(names_text(s).strip(",; ")).map do |n|
          n = n.strip(",; ")
          n = n + "." if n.matches?(/\s\p{Lu}\z/) && !n.includes?(',')
          n = n.includes?(',') && inverted?(n) ? Clean.invert(n) : n.delete(',').strip
          n = n.rstrip('.') if !n.includes?(' ') && n.size > 3
          # "Shafarevich I.R", "Neapolitan R. E." -> "I. R. Shafarevich"
          words = n.split(' ')
          if words.size >= 2 && words[1..].all?(&.matches?(INITIAL)) && !words.first.matches?(INITIAL)
            n = (words[1..].map { |w| w.gsub(/(?<=\p{Lu})\.?(?=\p{Lu}|\z)/, ". ").strip } + [words.first]).join(' ').gsub(/\s+/, " ")
          end
          n
        end.reject(&.empty?)
      end

      # Per field what the file name gives a book calibre added from that
      # file: title and authors where the book has calibre's reading of the
      # name (or a title the file brought along that says nothing,
      # bad_title?), publisher, date and series only where it has none.
      # imported: the field's value when the book was added, nil when it
      # changed since (the repair; for a book just added, its value now).
      def self.changes(book : Book, name : String, guess : Guess, imported : Proc(String, JSON::Any?), source = "rules") : Array(Change)
        cg_title, cg_authors = calibre(name)
        changes = [] of Change
        title = imported.call("title").try(&.as_s?)
        authors = imported.call("authors").try(&.as_a?).try(&.map(&.as_s))
        from_name = title && same_text?(title, cg_title)
        junk_title = title && !from_name && bad_title?(title)
        if title && (from_name || junk_title) && !same_text?(book.title, guess.title) && !guess.title.empty?
          changes << Change.new("title", JSON::Any.new(book.title), JSON::Any.new(guess.title), source)
        end
        if authors
          names_from_file = same_authors?(authors, cg_authors) && cg_authors != [UNKNOWN]
          if names_from_file || (Clean.unknown_authors?(authors) || junk_title) && !guess.authors.empty?
            want = guess.authors.empty? ? [UNKNOWN] : guess.authors
            unless same_authors?(book.authors, want)
              changes << Change.new("authors", JSON.parse(book.authors.to_json), JSON.parse(want.to_json), source)
              sort = AuthorSort.for(want)
              unless book.author_sort == sort
                changes << Change.new("authorSort", JSON::Any.new(book.author_sort), JSON::Any.new(sort), source)
              end
            end
          end
        end
        if book.publisher.nil? && (p = guess.publisher) && imported.call("publisher").try(&.raw.nil?)
          changes << Change.new("publisher", JSON::Any.new(nil), JSON::Any.new(p), source)
        end
        if book.pubdate.nil? && (y = guess.year) && imported.call("pubdate").try(&.raw.nil?)
          changes << Change.new("pubdate", JSON::Any.new(nil), JSON::Any.new(y.to_s), source)
        end
        if book.series.nil? && (sr = guess.series) && imported.call("series").try(&.raw.nil?)
          changes << Change.new("series", JSON::Any.new(nil), JSON::Any.new(sr), source)
          guess.series_index.try { |i| changes << Change.new("seriesIndex", JSON::Any.new(book.series_index), JSON::Any.new(i), source) }
        end
        changes
      end
    end
  end
end
