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
    # What a name gives is decided as a pair (changes, decide): title and
    # authors go together where the book has what an import left. Pure, so
    # every rule is tested with real names (spec/filename_spec.cr,
    # spec/quality_spec.cr).
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
      EDITION = /(?:,\s*|\s+)(?:\d{1,2}(?:st|nd|rd|th|d)?\.?\s*(?:ed(?:n|ition)?|aufl(?:age)?)\.?|\d{1,2}e|\d{1,2}ed|edn\.?\s*[\d.]+|[\(\[]\d{1,2}(?:st|nd|rd|th|d)?\.?\s*(?:ed(?:ition)?|aufl(?:age)?)\.?[\)\]])(?=\s|\z|[,:\[\(\]])/i
      # spelled out, at the end: ", Second Edition", "(Anniversary Edition)"
      EDITION_WORD = /,\s*\d{1,2}(?:st|nd|rd|th)\z|(?:,?\s+|\s*[\(\[])(?:first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|revised|anniversary|updated|international|expanded)\s+edition[\)\]]?\s*\z/i
      # a note in lower case at the end: "[computer arithmetic]", "[bw]"
      NOTE = /\s*\[(?!by\s)\p{Ll}[^\[\]]*\]\s*\z/
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
                       "infinity", "premier", "pfeiffer", "glencoe", "capstone", "rodale", "puffin", "picador", "macgraw", "tor",
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
                        "road", "sea", "island", "approach", "approaches", "paradigms", "foundation", "foundations",
                        "concepts", "perspective", "perspectives", "overview", "evolution", "implementation",
                        "economics", "drugs", "manual", "review", "tutorial", "handbooks"}
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
        "sigmund", "maxwell", "chet", "timothy", "lawrence", "karren", "hermann", "thomas", "friedrich",
      }
      # publishers that are surnames as well: alone, in a folder of "Author -
      # Title" names, they are the author
      SURNAMES = Set{"yale", "cambridge", "oxford", "princeton", "harvard", "chicago", "norton", "simon", "crown", "dover"}
      # words that are one word, not two run together
      COMPOUNDS = Set{"javascript", "typescript", "coffeescript", "actionscript", "postscript", "powershell", "playstation", "wordpress", "youtube"}
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
      # "logik-stud.dvi", "file:///F|/…", "test", "untitled", "()", "8508 Fm
      # Frame", "19 3.eps", "MMMonth". "Chapter 1: Reasoning in Geometry" says
      # something.
      BAD_TITLE = /\A(?:test|click here to log on|untitled(?: document)?|unbenannt|title|titel|unknown|document|dokument|vorlage|cover|book\d*|doc\d*|new document|new page \d+|djvu document|e-?book\s*pdf|microsoft word.*|chap(?:ter)?\s*\d+(?:\s+\d+\.\.\d+)?|chap\d+.*|ch\d+.*|app\d+|rev\d+|\p{L}?\d+\s+\d+\.\.\d+|pii:.*|\S+\.(?:dvi|docx?|indd|qxd|tex|ps|rtf|html?|pdf|p65|pm\d|fm|wpd|txt))\z/i
      FRAME_FILE = /\.(?:qxd|indd|dvi|p65)\b|\.(?:eps|vp|fm|key|tiff?)\z|\bfm\s+(?:frame|r\d)\b|\bfrontmatter\b|\bsup\s+tm\b|\bopener\z/i

      # the code of a collection in front of a title
      CODE_PREFIX = /\A\p{Lu}{2,5}\d{2,3}\s*[-–:]\s/

      def self.bad_title?(t : String) : Bool
        s = t.strip
        # "1984", "2001"
        return false if s.matches?(/\A\d{1,4}\z/)
        return true if s.count(&.letter?) < 3
        return true if s.matches?(BAD_TITLE)
        return true if s.matches?(/\A(?:file|https?):\//i) || s.matches?(FRAME_FILE)
        # "CBEAll", "MMMonth": no word, no acronym
        return true if s.matches?(/\A\p{Lu}{3,}\p{Ll}+\z/)
        # mostly digits and codes: "0375505784 4p Fm R1"
        s.count(&.ascii_number?) > s.count(&.letter?)
      end

      # A title that is what an import left, not what the book is called:
      # one that says nothing, a list number, a publisher or a person in
      # front, a ripper, an edition or a release in it. The name decides.
      def self.leftover_title?(t : String) : Bool
        return true if bad_title?(t)
        s = t.strip
        return true if s.matches?(Clean::RIPPER) || s.matches?(/\bripped\s+by\b/i)
        # "HIT04 - So Long, and Thanks for All the Fish": a collection's code
        return true if s.matches?(CODE_PREFIX)
        # "4. Thomas S. Kuhn - The Structure…", "07 - Compilers"
        return true if s.matches?(/\A\d{1,3}(?:\.\s|\s+[-–]\s)/)
        # "Cambridge Quantum Processes Mar 2009 eBook-ELOHiM"
        return true if s.matches?(/\s#{MONTHS}\s#{YEAR}(?:\s|\z)/i)
        # "Logic in Computer Science 2nd ed"
        return true if s.matches?(/\s\d{1,2}(?:st|nd|rd|th|d)?\.?\s*(?:ed|edn|aufl)\.?(?=\s|\z)/i)
        # "AI Techniques For Game Programming (Premier Press, 2002)"
        return true if s.matches?(PUBLISHER_YEAR) || s.matches?(/-\s*\S+\s+(?:US|UK)\z/)
        parts = split_parts(s)
        return false if parts.size < 2
        # "Addison Wesley - Hacker's Delight", "Alexander Shulgin - Drugs of Abuse"
        publisher?(parts.first) && !title_side?(parts.first) || side_score(parts.first) >= 2
      end

      private def self.title_side?(s : String) : Bool
        Text.tokens(s).any? { |w| TITLE_NOUNS.includes?(w) || Clean::TITLE_WORDS.includes?(w) }
      end

      # the title again with its edition: a book without an ISBN (a catalog's
      # title may name the edition)
      def self.leftover_title?(book : Book) : Bool
        return true if leftover_title?(book.title)
        book.identifiers["isbn"]?.nil? && book.title.matches?(/\s\d{1,2}(?:st|nd|rd|th)\s+edition\b/i)
      end

      # who a tool or a typesetter put into this library's files as author
      FILE_OWNERS = Set{"administrator", "besitzer", "jasmine fradique", "danny", "owner", "user"}

      # Not a person: a tool or owner of the file, a publisher, an edition,
      # a title or a subtitle
      def self.bad_author?(a : String) : Bool
        return true if Clean.unknown_author?(a)
        s = a.strip
        return true if FILE_OWNERS.includes?(Text.tokens(s).join(' '))
        return true if s.matches?(/[\d()\[\]]|\/\/|https?:|\.(?:com|org|net)\b|\bedition\b/i) || s.matches?(/\Aauthor:/i)
        organization?(s) || title_like?(s)
      end

      # An organisation or event, not a person: "Symposium on Mathematical
      # Modelling", "Electronic Publishing", "McKinsey & Co", "Compliance"
      ORGANIZATION = /\b(?:symposium|conference|congress|workshop|seminar|meeting|proceedings|institute?|institut|university|universit[aä]t|college|society|gesellschaft|association|committee|commission|council|board|foundation|stiftung|corporation|incorporated|company|ministry|department|agency|academy|akademie|laboratory|laboratories|compliance|co|corp)\b\.?/i

      def self.organization?(s : String) : Bool
        s.matches?(ORGANIZATION) || publisher_name?(s)
      end

      # What is left of a name with notes around it: "Beck (Hg.)", "Author:
      # David Buckles", "Blake Masters // formatting by Max Olson", "Paul C.
      # Anagnostopoulos 101 2000 Sep 01", "(Genetic Engineering) Barbara Hough"
      def self.clean_author(a : String) : String
        a.sub(/\s*\/\/.*\z/, "").sub(/\Aauthor:\s*/i, "").sub(/\s+\d.*\z/, "").gsub(/\s*\([^()]*\)\s*/, " ").strip
      end

      # a title or subtitle in the authors: a person has a first name or
      # initials, or at most a word of a title among others
      def self.title_like?(s : String) : Bool
        words = s.split(/\s+/).reject(&.empty?)
        folded = words.map { |w| Text.fold(w).strip(",.") }
        return false if words.any? { |w| w.matches?(INITIAL) } || FIRST_NAMES.includes?(folded.first?)
        return true if article?(s) || words.size > 6 || s.matches?(/[!?:]/)
        titles = folded.count { |w| TITLE_NOUNS.includes?(w) || Clean::TITLE_WORDS.includes?(w) }
        titles >= 1 && titles * 3 >= words.size
      end

      # a publisher, not a person: "Pearson", "Glencoe/McGraw-Hill", "Gale Group"
      def self.publisher_name?(s : String) : Bool
        return true if s.includes?('/') && s.split(/[\/\s-]+/).any? { |w| PUBLISHERS.includes?(Text.fold(w)) }
        return true if known_publisher?(s) && !FIRST_NAMES.includes?(Text.fold(s.split(/\s+/).first))
        s.split(/\s+/).last.downcase.rstrip(".,").in?("press", "publishing", "publications", "publishers", "verlag", "gmbh", "inc", "llc", "ltd", "group", "media")
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
        readings(name, hint).try(&.[0].first?)
      end

      # How the name was decided: by the name score, by the folder (a tie),
      # or unclear (a tie without a folder, or no person on either side)
      NAME    = "name"
      FOLDER  = "folder"
      UNCLEAR = "unclear"

      # The readings of the file name, the one to take first, and how it
      # was decided. Unclear: the author first, last and none (the most
      # likely first, as parse takes it), for others to decide
      # (Metadata#decide: the file, the online sources, the model).
      def self.readings(name : String, hint : Symbol? = nil) : {Array(Guess), String}?
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
        # "Title -- Author -- 1 Auflage, München -- Publisher": Anna's Archive
        anna = parts.size >= 3 && s.includes?(" -- ") && side_score(parts[1]) >= 0
        if anna
          publisher ||= parts[3]?.try { |p| p if publisher?(p) }
          parts = parts.first(2).reverse
        end
        # "HIT04 - So Long, and Thanks for All the Fish - Douglas Adams": the
        # code of a collection, no part of the title
        parts.shift if parts.size >= 3 && parts.first.matches?(/\A\p{Lu}{2,5}\d{2,3}\z/)
        # "07 - Compilers - Principles…": a number in a list of files, whose
        # names need a clear person to have an author
        numbered = parts.size >= 2 && parts.first.matches?(/\A\d{1,3}\.?\z/)
        parts.shift if numbered
        # "O'Reilly - Server Load Balancing", "CRC Press - Dictionary … - D. Clark";
        # not "Yale - Geometry and Symmetry" in a folder of "Author - Title" names
        if parts.size >= 2 && known_publisher?(parts.first) && !(hint == :first && SURNAMES.includes?(Text.fold(parts.first)))
          publisher ||= parts.first
          parts.shift
        end
        # "Wireless Networks for Dummies--For Dummies": the name twice
        parts.pop if parts.size >= 2 && Text.key(parts[-2]).ends_with?(Text.key(parts.last.gsub(EDITION, "")))
        publisher = publisher.try { |p| PUBLISHER_NAMES[p]? || p }
        make = ->(side : Symbol?) { build(parts, side, series, index, paren_author, year, publisher) }
        return make.call(nil).try { |g| {[g], NAME} } if parts.size < 2
        return make.call(:first).try { |g| {[g], NAME} } if anna
        sf, sl = side_score(parts.first), side_score(parts.last)
        # "13 - Peopleware - Productive Projects and Teams"
        return make.call(nil).try { |g| {[g], NAME} } if numbered && sf < 2 && sl < 2
        # "Encyclopedia of Mathematics - Gale Group (Vol.1 Ab-Cy)": a publisher
        # is nobody
        if publisher_name?(names_text(parts.last))
          publisher ||= names_text(parts.last)
          volume = parts.last[/\([^()]*\bvol[^()]*\)/i]?
          parts = parts[0..-2]
          parts[-1] = "#{parts.last} #{volume}" if volume
          return make_title(parts, series, index, paren_author, year, publisher)
        end
        side, how = if sf == sl && sf >= 0 && hint
                      # a tie: as the folder's other files
                      {hint, FOLDER}
                    elsif sf == sl && sf >= 0
                      # a tie (both names, or neither): calibre's "Title -
                      # Author" first when neither side is a name
                      {sf == 0 ? :last : :first, UNCLEAR}
                    elsif sf >= 1 && sf >= sl
                      {:first, NAME}
                    elsif libgen && sf >= 0 && sf > sl
                      # "Morgan Housel - The Psychology of Money-Harriman House (2020)"
                      {:first, NAME}
                    elsif sl >= 1 && sl > sf
                      {:last, NAME}
                    elsif sl == 0 && sf <= -2 && parts.first.split(' ').size >= 2 && !parts.last.matches?(/\s(?:and|und)\s/i)
                      # "An Introduction to Genetic Algorithms - Melanie Mitchell"
                      {:last, NAME}
                    elsif sf < 0 && sl < 0
                      # no person on either side ("The Road to Reality - A
                      # Complete Guide"): title and subtitle
                      {nil, NAME}
                    else
                      # "Wine Tasting - A Professional Handbook", "Sigmund
                      # Freud - The Interpretation of Dreams": a title first
                      {nil, UNCLEAR}
                    end
        first = make.call(side) || return nil
        return {[first], how} unless how == UNCLEAR
        others = [:first, :last, nil].reject { |x| x == side }.compact_map { |x| make.call(x) }
        {[first] + others, how}
      end

      private def self.make_title(parts : Array(String), series : String?, index : Float64?, paren_author : String?,
                                  year : Int32?, publisher : String?) : {Array(Guess), String}?
        build(parts, nil, series, index, paren_author, year, publisher).try { |g| {[g], NAME} }
      end

      # one reading: the author on that side (nil: none), the rest the title
      private def self.build(parts : Array(String), side : Symbol?, series : String?, index : Float64?,
                             paren_author : String?, year : Int32?, publisher : String?) : Guess?
        authors = [] of String
        rest = parts
        if parts.size >= 2
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
        title = finish_title(join_title(rest))
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
        Guess.new(title, authors, series.try(&.strip), series ? index : nil, year, "rules", publisher, year.try(&.to_s))
      end

      # "Title - Subtitle" -> "Title: Subtitle"; "How to Charge - and Get -
      # What You're Worth" is one sentence
      private def self.join_title(parts : Array(String)) : String
        return parts.first if parts.size == 1
        return parts.join(" - ") if parts.any? { |p| p.includes?(':') || p.includes?(MARK) } || parts[1..].any?(&.[0].lowercase?)
        "#{parts.first}#{MARK} #{parts[1..].join(" - ")}"
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
          # "Baerwolff---Hoehere-Mathematik-fuer-Ingenieure"
          s = s.gsub(/-{3,}/, " - ").gsub(/(?<=\p{L})-(?=\p{L})/, " ") if s.matches?(/-{3,}/)
        else
          # "Dirk W_" was "Dirk W." (no dot at the end of a file name)
          s = s.gsub(/(?<=\s\p{Lu})_(?=\s*(?:\z|[-,(]))/, ".")
          s = s.gsub("_ ", "#{MARK} ")
          s = s.gsub('_', ' ')
        end
        # "100 Great Artists~A Visual Journey", "Leary, Timothy--The Tibetan Book"
        s = s.gsub(/\s*~\s*(?=\p{L})/, "#{MARK} ").gsub(/(?<=\S)--(?=\S)/, " -- ")
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
        # "(Delmar) Digital Signal Processing"
        if (m = s.match(/\A\(([^()]+)\)\s+(.+)\z/)) && known_publisher?(m[1])
          publisher = m[1]
          s = m[2]
        end
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
          s = s.sub(TAIL_JUNK, "").sub(Clean::RIPPER, "").sub(NOTE, "").strip
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
          elsif publisher.nil? && (p = hung_publisher(s, strict: true))
            # "Data Science & Classification-Springer"
            publisher, s = p
            libgen = true if s.matches?(/\s[-–]\s/)
          elsif publisher.nil? && (m = s.match(/\s*\(([^()]+)\)\s*\z/)) && known_publisher?(m[1])
            # "Java 3D Programming (Manning)"
            publisher = m[1].strip
            s = s.sub(m[0], "")
          elsif (m = s.match(/\s*\([^()]*\([^()]*\)[^()]*\)\s*\z/))
            # "(Ultimate Consultant (Pfeiffer))": a series with its publisher
            s = s.sub(m[0], "")
          elsif author.nil? && (m = s.match(/\s*[\(\[]by\s+([^()\[\]]+)[\)\]]\s*\z/i)) && side_score(m[1]) >= 1
            # "Basic Engineering Mathematics [by John Bird]"
            author = m[1]
            s = s.sub(m[0], "")
          elsif author.nil? && (m = s.match(/\s*\(([^()]+)\)\s*\z/)) && side_score(m[1]) >= 2 && !s.sub(m[0], "").matches?(/\s[-–]\s/) &&
                !m[1].matches?(/\A(?:rev|ver|vol|bd|nr|no)\b/i)
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

      # a title from anywhere, cleaned like a name's
      def self.clean_title(t : String) : String
        finish_title(t)
      end

      private def self.finish_title(t : String) : String
        t = t.gsub(MARK, ":")
        t = t.gsub(/(?<=\p{L})- (?=\p{Lu})/, ": ").gsub(/(?<=\p{Ll})-(?=(?:The|A|An|Der|Die|Das)\s)/, ": ")
        t = t.gsub(EDITION, "").sub(EDITION_WORD, "")
        t = Clean.strip_junk(t)
        # "AkteurGehirn", "CompilerConstruction1"
        if t.matches?(/\A(?:\p{Lu}\p{Ll}{2,}){2,}\d*\z/) && !COMPOUNDS.includes?(Text.key(t))
          t = t.gsub(/(?<=\p{Ll})(?=\p{Lu}|\d)/, " ")
        end
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

      # "A Professional Handbook", not "A. Knapp"
      def self.article?(s : String) : Bool
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

      # A book's title and authors as a decision sees them. open: nobody
      # edited it since the import. left: what an import left there (calibre's
      # reading of the name, a title that says nothing, a tool, publisher or
      # subtitle as author), not what the book is called. from_name: the
      # authors are calibre's reading of the name.
      record Names, title_open : Bool, title_left : Bool, authors_open : Bool, authors_left : Bool, from_name : Bool = false

      def self.names(book : Book, name : String, imported : Proc(String, JSON::Any?)) : Names
        cg_title, cg_authors = calibre(name)
        title = imported.call("title").try(&.as_s?)
        authors = imported.call("authors").try(&.as_a?).try(&.map(&.as_s))
        from_name = !authors.nil? && same_authors?(authors, cg_authors) && cg_authors != [UNKNOWN]
        # with an ISBN the title isn't the name's, whatever calibre read
        calibre_title = same_text?(title, cg_title) && !checked?(book)
        Names.new(!title.nil?, !title.nil? && (calibre_title || leftover_title?(book)),
          !authors.nil?, !authors.nil? && (from_name || weak_authors?(book)), from_name)
      end

      # an ISBN: a catalog knows the book
      def self.checked?(book : Book) : Bool
        !book.identifiers["isbn"]?.nil?
      end

      # no author worth keeping, or one that isn't a person
      def self.weak_authors?(book : Book) : Bool
        return true if Clean.unknown_authors?(book.authors)
        !checked?(book) && book.authors.any? { |a| bad_author?(a) || Text.key(a) == Text.key(book.title) }
      end

      # the book's authors without the notes around them and those that
      # are no persons; a single word next to a title's words is one of them
      private def self.kept_authors(book : Book) : Array(String)
        clean = book.authors.map { |a| clean_author(a) }.reject { |a| a.empty? || bad_author?(a) }
        return clean if clean.size == book.authors.size
        clean.select { |a| a.includes?(' ') }
      end

      # the same book: one title in the other (a subtitle more or less)
      def self.same_book?(a : String, b : String) : Bool
        ka, kb = Text.key(a), Text.key(b)
        ka.includes?(kb) || kb.includes?(ka) || Text.similarity(a, b) >= 0.6
      end

      # Per field what the file name gives a book calibre added from that
      # file: title and authors together, where the book has what the import
      # left (Names): a name with an author replaces both, as does a title of
      # the file that isn't this name's book; publisher, date and series only
      # where it has none. imported: the field's value when the book was
      # added, nil when it changed since (the repair; for a book just added,
      # its value now): such a field stays.
      def self.changes(book : Book, name : String, guess : Guess, imported : Proc(String, JSON::Any?), source = "rules") : Array(Change)
        plan(book, guess, names(book, name, imported), imported, source)
      end

      private def self.take_title?(book : Book, guess : Guess, n : Names) : Bool
        n.title_left || n.title_open && n.authors_left && !guess.authors.empty? && !same_book?(book.title, guess.title)
      end

      private def self.plan(book : Book, guess : Guess, n : Names, imported : Proc(String, JSON::Any?), source : String) : Array(Change)
        changes = [] of Change
        named = !guess.authors.empty?
        take_title = take_title?(book, guess, n) && !same_text?(book.title, guess.title) && !guess.title.empty?
        changes << Change.new("title", JSON::Any.new(book.title), JSON::Any.new(guess.title), source) if take_title
        # "Frank Herbert" of the file for the name's "Herbert" stays
        same_people = named && guess.authors.all? { |a| Score.authors([a], book.authors) >= 0.8 }
        if n.authors_left || n.authors_open && take_title && named && !same_people
          kept = n.from_name ? [] of String : kept_authors(book).reject { |a| Text.key(a) == Text.key(guess.title) }
          want = named ? guess.authors : (kept.empty? ? [UNKNOWN] : kept)
          unless same_authors?(book.authors, want)
            changes << Change.new("authors", JSON.parse(book.authors.to_json), JSON.parse(want.to_json), source)
            sort = AuthorSort.for(want)
            unless book.author_sort == sort
              changes << Change.new("authorSort", JSON::Any.new(book.author_sort), JSON::Any.new(sort), source)
            end
          end
        end
        # a publisher in the authors moves where it belongs
        moved = n.authors_left && !n.from_name ? book.authors.find { |a| publisher_name?(a) && !Clean.unknown_author?(a) } : nil
        if book.publisher.nil? && (p = guess.publisher || moved) && imported.call("publisher").try(&.raw.nil?)
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

      NAME_FIELDS = {"title", "authors", "authorSort"}
      # who decided an unclear name: the file (decide_by_file), a metadata
      # source, the model
      UNSURE = "unsure"
      # the "change" with what the catalogs suggest for a book they couldn't
      # confirm: for the review, never applied
      CANDIDATE = "candidate"

      # Decides between the readings of an unclear name (Metadata#decide):
      # {reading, who decided}, nil when it can't
      alias Decider = Proc(Book, String, Array(Guess), {Guess, String}?)
      # Asks the catalogs about a reading without an author (Metadata#check)
      alias Checker = Proc(Book, Guess, Verdict?)

      # The changes from the file name (changes) and who decided: the name,
      # the folder, or for an unclear name that would change title or
      # authors, the file's own metadata, then the decider (the metadata
      # sources, the model). Still unclear: title and authors stay, the book
      # gets Meta.unsure_tag for a manual review. A reading without an author
      # goes to the catalogs (finish). nil: not a name to read (a standard).
      def self.decide(book : Book, name : String, hint : Symbol?, imported : Proc(String, JSON::Any?),
                      decider : Decider? = nil, checker : Checker? = nil, source = "rules") : {Array(Change), String}?
        read = readings(name, hint) || return nil
        gs, how = read
        # "chap01.pdf", "eBookPDF.pdf": the name says nothing
        return decide_own(book, imported, checker, source) || {[] of Change, NAME} if bad_title?(gs.first.title)
        n = names(book, name, imported)
        guess = gs.first
        # the file's title as its author: "Understanding Bluetooth" by the same
        n = n.copy_with(authors_left: true) if n.authors_open && book.authors.any? { |a| Text.key(a) == Text.key(guess.title) }
        if how == UNCLEAR
          if plan(book, guess, n, imported, source).none? { |c| NAME_FIELDS.includes?(c.field) }
            # title and authors stay anyway: nothing to decide
            how = NAME
          elsif g = decide_by_file(book, name, gs)
            guess, how = g, "file"
          elsif d = decider.try(&.call(book, name, gs))
            guess, how = d
          else
            # a subtitle is no author, whoever the other side is; which name
            # of two is the author nobody can tell, they stay
            changes = plan(book, guess, n, imported, source)
            changes = changes.reject { |c| NAME_FIELDS.includes?(c.field) } unless guess.authors.empty?
            return {changes + unsure_tag(book, source), UNSURE}
          end
        end
        finish(book, own_person(book, guess, n), how, n, imported, checker, source)
      end

      # A book without a file name to read (an upload, the inbox, a calibre
      # folder): its title read like a name, where its names are what a file
      # or an import left. nil: they aren't.
      def self.decide_own(book : Book, imported : Proc(String, JSON::Any?), checker : Checker? = nil, source = "rules") : {Array(Change), String}?
        title_open = !imported.call("title").nil?
        authors_open = !imported.call("authors").nil?
        title_left = title_open && leftover_title?(book)
        authors_left = authors_open && weak_authors?(book)
        return nil unless title_left || authors_left
        guess = Guess.new(book.title, [] of String)
        unless bad_title?(book.title)
          gs, how = readings("#{book.title}.pdf") || {[guess], NAME}
          guess = (how == UNCLEAR ? gs.find(&.authors.empty?) : nil) || gs.first
          # the title has the author in it, or has the shape of a file's name
          title_left ||= title_open && authors_left && !book.title.includes?(':')
        end
        # "Chet Holmes" by "The Ultimate Sales Machine", the wrong way round
        if authors_left && !Clean.unknown_authors?(book.authors) && side_score(book.title) >= 1 && title_like?(book.authors.first)
          guess = Guess.new(finish_title(join_title(book.authors)), split_authors(book.title))
          title_left = title_open
        end
        n = Names.new(title_open, title_left && !bad_title?(guess.title), authors_open, authors_left)
        changes, how = finish(book, own_person(book, guess, n), NAME, n, imported, checker, source)
        changes.empty? ? nil : {changes, how}
      end

      # The changes of the reading; a reading without an author asks the
      # catalogs where the book has none worth keeping or its title goes: a
      # confirmed author is taken, anything less is the unsure tag and what
      # they suggest (CANDIDATE) for the review. So is an own title and author
      # that are another book than the name's, and a book nothing is known of.
      private def self.finish(book : Book, guess : Guess, how : String, n : Names, imported : Proc(String, JSON::Any?),
                              checker : Checker?, source : String) : {Array(Change), String}
        changes = plan(book, guess, n, imported, source)
        names_left = changes.any? { |c| c.field == "title" } || n.authors_left
        unsure = false
        if guess.authors.empty? && n.authors_open && names_left
          if verdict = checker.try(&.call(book, guess))
            if verdict.confirmed
              return {plan(book, guess.copy_with(authors: verdict.authors), n.copy_with(authors_left: true), imported, source), verdict.source}
            end
            changes << Change.new(CANDIDATE, JSON::Any.new(nil), JSON.parse({title: verdict.title, authors: verdict.authors, source: verdict.source}.to_json), source)
            unsure = true
          end
        end
        title = changes.find { |c| c.field == "title" }.try(&.new.as_s?) || book.title
        # another title, the file's author stays: nobody vouches for it
        unsure ||= guess.authors.empty? && !n.authors_left && !checked?(book) && !same_book?(book.title, title)
        unsure ||= bad_title?(title) && Clean.unknown_authors?(book.authors)
        if !unsure && !guess.authors.empty? && !n.title_left && !n.authors_left && !checked?(book) &&
           !same_book?(book.title, guess.title) && Score.authors(guess.authors, book.authors) < 0.5
          # "Cole - Network Security Bible" with another book's metadata
          changes = [] of Change
          unsure = true
        end
        return {changes, how} unless unsure
        {changes + unsure_tag(book, source), UNSURE}
      end

      private def self.unsure_tag(book : Book, source : String) : Array(Change)
        have = Merge.value(book, "tags").as_a.map(&.as_s)
        return [] of Change if have.includes?(Meta.unsure_tag)
        [Change.new("tags", JSON.parse(have.to_json), JSON.parse((have + [Meta.unsure_tag]).to_json), source)]
      end

      # "Alexander Shulgin - Drugs of Abuse in the Future": the file's own
      # title has the author of the name, in full, and the book's real title
      private def self.own_person(book : Book, guess : Guess, n : Names) : Guess
        return guess unless n.title_open && n.authors_open
        parts = split_parts(book.title)
        return guess unless parts.size >= 2 && side_score(parts.first) >= 2
        return guess unless guess.authors.empty? || Score.authors(guess.authors, [parts.first]) >= 0.8
        title = finish_title(join_title(parts[1..]))
        return guess if leftover_title?(title)
        # "Alan Weiss - Value-Based Fees" cut short: the name has more of it
        return guess.copy_with(authors: split_authors(parts.first)) if same_book?(title, guess.title)
        guess.copy_with(title: title, authors: split_authors(parts.first))
      end

      # The reading the file's own metadata names (a PDF's info dict, an
      # EPUB's OPF, as calibre read them): one with an author of the file,
      # else the only one with the file's title
      def self.decide_by_file(book : Book, name : String, readings : Array(Guess)) : Guess?
        cg_title, cg_authors = calibre(name)
        unless same_authors?(book.authors, cg_authors) || Clean.unknown_authors?(book.authors)
          own = book.authors.flat_map { |a| Text.tokens(a) }.select { |w| w.size > 2 }.to_set
          hits = readings.select { |r| r.authors.flat_map { |a| Text.tokens(a) }.any? { |w| own.includes?(w) } }
          return hits.first if hits.size == 1
        end
        unless same_text?(book.title, cg_title) || bad_title?(book.title)
          hits = readings.select { |r| Text.similarity(r.title, book.title) >= 0.8 }
          return hits.first if hits.size == 1
        end
        # the file has an author of its own, the name none of it: only a title
        return readings.find(&.authors.empty?) unless same_authors?(book.authors, cg_authors) || weak_authors?(book)
        nil
      end
    end
  end
end
