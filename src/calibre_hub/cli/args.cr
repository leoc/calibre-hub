module CalibreHub
  module Cli
    # exit codes
    OK        = 0
    USAGE     = 1
    NOT_FOUND = 2
    CONFLICT  = 3
    AUTH      = 4
    SERVER    = 5

    # Ends a command with an exit code; data goes into the --json error body
    class Failure < Exception
      getter code : Int32
      getter data : Hash(String, JSON::Any)

      def initialize(@code : Int32, message : String, @data = {} of String => JSON::Any)
        super(message)
      end
    end

    class Usage < Failure
      getter command : String?

      def initialize(message : String, @command : String? = nil)
        super(USAGE, message)
      end
    end

    # arg: value placeholder, nil for a switch; file: the value is a path
    record Flag, name : String, arg : String? = nil, help : String = "", short : Char? = nil,
      repeat : Bool = false, choices : Array(String)? = nil, file : Bool = false

    # choices: values of the first positional (tag add|rm); files: positionals are paths
    record Command, name : String, usage : String, summary : String, flags : Array(Flag) = [] of Flag,
      choices : Array(String)? = nil, files : Bool = false do
      def all_flags : Array(Flag)
        flags + COMMON
      end
    end

    COMMON = [
      Flag.new("json", help: "JSON output for scripts"),
      Flag.new("help", short: 'h', help: "show this help"),
    ]

    SORTS      = %w(title author added modified published series rating)
    LIST_SORTS = %w(listAdded title author series)
    KINDS      = %w(kategorie tags authors series languages)
    KATEGORIE  = "category, A/B or A.B (stored as A.B)"
    EMPTY_HINT = "an empty value clears the field"

    COMMANDS = [
      Command.new("search", "search [query] [options]",
        "find books (query in calibre search syntax, e.g. 'title:dune or tags:sf')", [
        Flag.new("kategorie", "A/B", "only this category and below"),
        Flag.new("tag", "TAG", "only books with this tag (repeatable)", repeat: true),
        Flag.new("author", "NAME", "only books by this author"),
        Flag.new("series", "NAME", "only books in this series"),
        Flag.new("sort", "FIELD", "sort by #{SORTS.join(", ")}", choices: SORTS),
        Flag.new("order", "DIR", "asc or desc", choices: %w(asc desc)),
        Flag.new("limit", "N", "at most N books (default 50, max 500)"),
        Flag.new("offset", "N", "skip the first N books"),
      ]),
      Command.new("show", "show <id>", "show one book with all metadata"),
      Command.new("download", "download <id> [--format epub] [-o path]", "download a book file", [
        Flag.new("format", "FMT", "file format (default: epub if present, else the first)"),
        Flag.new("output", "PATH", "target file, - for stdout (default: 'Author - Title.fmt')", short: 'o', file: true),
      ]),
      Command.new("cover", "cover <id> -o file [--thumb]", "save the cover image", [
        Flag.new("output", "PATH", "target file, - for stdout", short: 'o', file: true),
        Flag.new("thumb", help: "small thumbnail instead of the full cover"),
      ]),
      Command.new("categories", "categories [#{KINDS.join("|")}]",
        "list categories, tags, authors, series or languages with counts", choices: KINDS),
      Command.new("edit", "edit <id> [options]", "change metadata (fails on concurrent changes)", [
        Flag.new("title", "TEXT", "title"),
        Flag.new("authors", "A,B", "authors, comma separated"),
        Flag.new("series", "NAME", "series, #{EMPTY_HINT}"),
        Flag.new("index", "N", "number in the series"),
        Flag.new("tags", "A,B", "replace all tags, comma separated"),
        Flag.new("kategorie", "A/B", "#{KATEGORIE}, #{EMPTY_HINT}"),
        Flag.new("comments-file", "PATH", "description as HTML or text, - for stdin", file: true),
        Flag.new("publisher", "NAME", "publisher, #{EMPTY_HINT}"),
        Flag.new("pubdate", "YYYY-MM-DD", "publication date, #{EMPTY_HINT}"),
        Flag.new("rating", "0-10", "rating in half stars (8 = 4 stars), 0 clears"),
        Flag.new("languages", "A,B", "language codes, comma separated (deu,eng)"),
        Flag.new("identifier", "TYPE=VALUE", "set an identifier, TYPE= removes it (repeatable)", repeat: true),
      ]),
      Command.new("tag", "tag add|rm <id...> <tag>", "add a tag to books or remove it", choices: %w(add rm)),
      Command.new("upload", "upload <files...> [options]", "send books (one per file) to the Eingang, or add a format to a book", [
        Flag.new("tag", "TAG", "tag for the new books (repeatable, comma separated)", repeat: true),
        Flag.new("kategorie", "A/B", KATEGORIE),
        Flag.new("force", help: "a book of its own even if it looks like a duplicate"),
        Flag.new("add-format-to", "ID", "add the file as a format of this book instead"),
        Flag.new("wait", "SECONDS", "wait this long for the analysis (default 120)"),
      ], files: true),
      Command.new("bulk", "bulk (--ids 1,2 | --query Q) <changes> [--yes]",
        "change many books at once as a background job", [
        Flag.new("ids", "1,2", "book ids, comma separated"),
        Flag.new("query", "Q", "all books matching this calibre search"),
        Flag.new("add-tags", "A,B", "add tags"),
        Flag.new("remove-tags", "A,B", "remove tags"),
        Flag.new("kategorie", "A/B", "#{KATEGORIE}, #{EMPTY_HINT}"),
        Flag.new("series", "NAME", "series, #{EMPTY_HINT}"),
        Flag.new("number-series", help: "number the series 1, 2, ... in the order of --ids"),
        Flag.new("yes", short: 'y', help: "don't ask for confirmation"),
      ]),
      Command.new("list", "list ls|show|create|add|rm|delete [list] [ids...] [options]",
        "reading lists: ls, show <list>, create <name>, add|rm <list> <id...>, delete <list> (list: id or name; nested as a path, Urlaub/2026)", [
        Flag.new("tree", help: "ls: the lists as a tree, sublists indented"),
        Flag.new("direct", help: "show: only the list's own books, not those of its sublists"),
        Flag.new("description", "TEXT", "create: description"),
        Flag.new("sync", help: "create: mirror the list to the reader"),
        Flag.new("favorite", help: "create: show it in the sidebar first"),
        Flag.new("default", help: "create: make it the default list (the bookmark on covers)"),
        Flag.new("visibility", "V", "create: private, readable or editable", choices: %w(private readable editable)),
        Flag.new("sort", "FIELD", "show: sort by #{LIST_SORTS.join(", ")}", choices: LIST_SORTS),
        Flag.new("order", "DIR", "show: asc or desc", choices: %w(asc desc)),
        Flag.new("limit", "N", "show: at most N books (default 50, max 500)"),
        Flag.new("offset", "N", "show: skip the first N books"),
        Flag.new("yes", short: 'y', help: "delete: don't ask for confirmation"),
      ], choices: %w(ls show create add rm delete)),
      Command.new("import", "import cleanup (--min-id N | --since TIME) [--apply] | import undo <cleanup> [--apply] | import status | import repair recheck [--run ID]",
        "take back the folder categories and tags the inbox set (dry run unless --apply); status and repair recheck are hub eingang's under their old names", [
        Flag.new("apply", help: "clean up or undo instead of a dry run"),
        Flag.new("min-id", "N", "cleanup: books with this id or higher"),
        Flag.new("max-id", "N", "cleanup: books up to this id"),
        Flag.new("since", "TIME", "cleanup: books added since (2026-11-02T18:00, local time)"),
        Flag.new("run", "ID", "repair recheck: the books of this import run"),
      ]),
      Command.new("eingang", "eingang | eingang recheck [--run ID]",
        "what is in the Eingang and how it goes on; plan the library's books again", [
        Flag.new("run", "ID", "recheck: the books of this import run"),
      ], choices: %w(recheck)),
      Command.new("tui", "tui", "browse the library in the terminal (Vim keys, ? shows them)"),
      Command.new("completion", "completion fish|bash [--prog hub|calibre-hub]",
        "print a shell completion script", [
        Flag.new("prog", "NAME", "complete only this command name", choices: %w(hub calibre-hub)),
      ], choices: %w(fish bash)),
      Command.new("help", "help [command]", "show help"),
    ]

    def self.command(name : String) : Command?
      COMMANDS.find { |c| c.name == name }
    end

    # Parsed arguments of one command: --name value, --name=value, -o value,
    # -ovalue, -- ends options.
    class Args
      getter positional = [] of String
      getter command : Command

      def initialize(@command : Command, argv : Array(String))
        @values = {} of String => Array(String)
        parse(argv)
      end

      def flag?(name : String) : Bool
        @values.has_key?(name)
      end

      def []?(name : String) : String?
        @values[name]?.try(&.last)
      end

      def all(name : String) : Array(String)
        @values[name]? || [] of String
      end

      def json? : Bool
        flag?("json")
      end

      private def parse(argv)
        i = 0
        rest = false
        while i < argv.size
          arg = argv[i]
          i += 1
          if rest || arg == "-" || !arg.starts_with?('-') || arg.matches?(/\A-\d/)
            @positional << arg
            next
          end
          if arg == "--"
            rest = true
            next
          end
          if arg.starts_with?("--")
            name, eq, value = arg[2..].partition('=')
            flag = @command.all_flags.find { |f| f.name == name } || usage("unknown option --#{name}")
          else
            flag = @command.all_flags.find { |f| f.short == arg[1] } || usage("unknown option #{arg[0, 2]}")
            eq, value = arg.size > 2 ? {"=", arg[2..]} : {"", ""}
          end
          if placeholder = flag.arg
            if eq.empty?
              value = argv[i]? || usage("--#{flag.name} needs a value (#{placeholder})")
              i += 1
            end
            if (choices = flag.choices) && !choices.includes?(value)
              usage("--#{flag.name} must be one of #{choices.join(", ")}")
            end
            list = @values[flag.name] ||= [] of String
            list.clear unless flag.repeat
            list << value
          else
            usage("--#{flag.name} takes no value") unless eq.empty?
            @values[flag.name] = ["1"]
          end
        end
      end

      private def usage(message) : NoReturn
        raise Usage.new(message, @command.name)
      end
    end
  end
end
