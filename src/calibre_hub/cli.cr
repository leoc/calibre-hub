require "json"
require "http"
require "./cli/args"
require "./cli/client"
require "./cli/output"
require "./cli/completion"
require "./cli/import"
require "./tui"

module CalibreHub
  # Command line client for a running hub: `calibre-hub cli <command>` or
  # `hub <command>`. Talks to the JSON API with an API token.
  module Cli
    def self.run(argv : Array(String), stdout : IO = STDOUT, stderr : IO = STDERR, stdin : IO = STDIN,
                 env : Hash(String, String) = ENV.to_h) : Int32
      Runner.new(stdout, stderr, stdin, env).run(argv)
    end

    class Runner
      property poll_interval : Time::Span = 500.milliseconds
      # the client, for specs; otherwise built from the environment
      setter client : Client?

      def initialize(@out : IO, @err : IO, @in : IO, @env : Hash(String, String))
      end

      def run(argv : Array(String)) : Int32
        name = argv.first?
        if name.nil? || {"--help", "-h"}.includes?(name)
          help
          return name ? OK : USAGE
        end
        command = Cli.command(name) || raise Usage.new("unknown command: #{name}")
        args = Args.new(command, argv[1..])
        if args.flag?("help")
          help(command)
          return OK
        end
        @json = args.json?
        dispatch(command, args)
        OK
      rescue ex : Usage
        @err.puts "error: #{ex.message}"
        cmd = ex.command
        @err.puts "usage: #{prog} #{cmd ? Cli.command(cmd).try(&.usage) : "<command>"} (see --help)"
        failed(ex)
      rescue ex : Failure
        @err.puts "error: #{ex.message}" unless ex.message.to_s.empty?
        failed(ex)
      end

      private def failed(ex : Failure) : Int32
        # an empty failure means the command printed its result already
        if @json && !(ex.message.to_s.empty? && ex.data.empty?)
          body = {"error" => JSON::Any.new(ex.message.to_s), "exitCode" => JSON::Any.new(ex.code.to_i64)}
          @out.puts body.merge(ex.data).to_json
        end
        ex.code
      end

      @json = false
      @category : String? = nil
      @category_read = false

      private def prog : String
        File.basename(PROGRAM_NAME) == "hub" ? "hub" : "calibre-hub cli"
      end

      private def client : Client
        @client ||= Client.from_env(@env)
      end

      private def dispatch(command : Command, args : Args)
        case command.name
        when "search"     then search(args)
        when "show"       then show(args)
        when "download"   then download(args)
        when "cover"      then cover(args)
        when "categories" then categories(args)
        when "edit"       then edit(args)
        when "tag"        then tag(args)
        when "upload"     then upload(args)
        when "bulk"       then bulk(args)
        when "list"       then list(args)
        when "import"     then import(args)
        when "completion" then completion(args)
        when "tui"        then tui
        when "help"
          help(args.positional.first?.try { |n| Cli.command(n) || raise Usage.new("unknown command: #{n}") })
        end
      end

      # --- help -------------------------------------------------------------

      def help(command : Command? = nil)
        if c = command
          @out.puts "usage: #{prog} #{c.usage}"
          @out.puts
          @out.puts c.summary
          @out.puts
          @out.puts "options:"
          left = c.all_flags.map { |f| "#{f.short ? "-#{f.short}, " : "    "}--#{f.name}#{f.arg ? " #{f.arg}" : ""}" }
          width = left.max_of(&.size)
          c.all_flags.each_with_index { |f, i| @out.puts "  #{left[i].ljust(width)}  #{f.help}" }
          return
        end
        @out.puts "usage: #{prog} <command> [options]"
        @out.puts
        width = COMMANDS.max_of(&.name.size)
        COMMANDS.each { |cmd| @out.puts "  #{cmd.name.ljust(width)}  #{cmd.summary}" }
        @out.puts <<-TXT

          Every command takes --json (output for scripts) and --help.
          Environment: CALIBRE_HUB_URL (default #{Client::DEFAULT_URL}), the API token in
          CALIBRE_HUB_TOKEN, CALIBRE_HUB_TOKEN_FILE or ~/.config/#{Client::DEFAULT_FILE}.
          Exit codes: 0 ok, 1 usage or invalid input, 2 not found, 3 conflict or duplicate,
          4 not authorized, 5 server unavailable or failed.
          TXT
      end

      # --- tui --------------------------------------------------------------

      private def tui
        raise Usage.new("tui needs a terminal", "tui") unless @in.tty? && @out.tty?
        Tui.run(client)
      end

      # --- read -------------------------------------------------------------

      private def search(args : Args)
        params = HTTP::Params.new
        query = args.positional.join(" ")
        params["q"] = query unless query.empty?
        args["kategorie"]?.presence.try { |k| params["kategorie"] = Runner.kategorie(k) }
        args.all("tag").each { |t| params.add("tag", t) }
        {"author", "series", "sort", "order"}.each { |k| args[k]?.presence.try { |v| params[k] = v } }
        {"limit", "offset"}.each { |k| args[k]?.try { |v| params[k] = Runner.int(k, v, min: 0).to_s } }
        result = client.get("/api/books", params)
        return @out.puts result.to_json if @json
        books = result["books"].as_a
        if books.empty?
          @out.puts "no books found"
          return
        end
        Output.books(@out, books, category)
        offset = result["offset"].as_i64
        total = result["total"].as_i64
        if books.size < total
          @out.puts "#{offset + 1}-#{offset + books.size} of #{total} books (--offset #{offset + books.size} for more)"
        else
          @out.puts "#{total} #{total == 1 ? "book" : "books"}"
        end
      end

      private def show(args : Args)
        book = fetch(id_arg(args))
        @json ? @out.puts(book.to_json) : Output.book(@out, book)
      end

      private def download(args : Args)
        id = id_arg(args)
        book = fetch(id)
        formats = book["formats"].as_a.map(&.as_s.downcase)
        format = args["format"]?.try(&.downcase) || (formats.includes?("epub") ? "epub" : formats.first?)
        raise Failure.new(NOT_FOUND, "book #{id} has no files") unless format
        unless formats.includes?(format)
          raise Failure.new(NOT_FOUND, "book #{id} has no #{format.upcase} (has #{formats.map(&.upcase).join(", ")})")
        end
        path = args["output"]? || Runner.file_name(book, format)
        bytes = save("/api/books/#{id}/download/#{format}", path)
        report_file(path, bytes, "#{Output.value(book["title"]?)} (#{format.upcase})", format: format)
      end

      private def cover(args : Args)
        id = id_arg(args)
        path = args["output"]? || raise Usage.new("-o file is required", "cover")
        bytes = save("/api/books/#{id}/cover#{args.flag?("thumb") ? "?size=thumb" : ""}", path)
        report_file(path, bytes, "cover of ##{id}")
      end

      private def categories(args : Args)
        kind = args.positional.first?
        raise Usage.new("unknown kind: #{kind}", "categories") if kind && !KINDS.includes?(kind)
        cats = client.get("/api/categories")
        return @out.puts((kind ? cats[kind] : cats).to_json) if @json
        (kind ? [kind] : KINDS).each_with_index do |k, i|
          items = cats[k]?.try(&.as_a) || [] of JSON::Any
          unless kind
            @out.puts if i > 0
            @out.puts "#{k.capitalize}:"
          end
          if items.empty?
            @out.puts "  (none)"
          elsif k == "kategorie"
            Output.tree(@out, items, kind ? 0 : 1)
          else
            Output.counts(@out, items)
          end
        end
      end

      # --- write ------------------------------------------------------------

      private def edit(args : Args)
        id = id_arg(args)
        changes = Runner.edit_changes(args, @in)
        raise Usage.new("nothing to change", "edit") if changes.empty?
        read = fetch(id)
        if ids = changes.delete("identifier")
          changes["identifiers"] = Runner.identifiers(read["identifiers"]?, ids.as_a.map(&.as_s))
        end
        changes["lastModified"] = read["lastModified"]
        begin
          book = client.patch("/api/books/#{id}", changes)
        rescue ex : HttpError
          raise ex unless ex.status == 409 && (current = ex.body["book"]?)
          conflict(id, read, current, changes)
        end
        if @json
          @out.puts book.to_json
        else
          Output.book(@out, book)
        end
      end

      private def conflict(id : Int64, read : JSON::Any, current : JSON::Any, changes : Hash(String, JSON::Any)) : NoReturn
        unless @json
          fields = Output.changed(read, current)
          @err.puts "conflict: book #{id} was changed while you edited it, nothing was written"
          unless fields.empty?
            rows = fields.map do |f|
              mine = Runner.edit_key(f).try { |k| changes[k]? }
              [f, Output.value(Output.field(read, f)), Output.value(Output.field(current, f)), mine ? Output.value(mine) : ""]
            end
            Output.table(@err, ["Field", "Read", "Now", "Yours"], rows, [nil, 40, 40, 40])
          end
          @err.puts "run the command again to apply your change to the current version"
        end
        raise Failure.new(CONFLICT, "", {"error" => JSON::Any.new("conflict"), "read" => read, "current" => current})
      end

      private def tag(args : Args)
        action = args.positional[0]? || raise Usage.new("add or rm expected", "tag")
        raise Usage.new("add or rm expected, not #{action}", "tag") unless {"add", "rm"}.includes?(action)
        raise Usage.new("ids and a tag expected", "tag") if args.positional.size < 3
        tag = args.positional.last
        ids = args.positional[1..-2].map { |i| Runner.id(i) }
        key = action == "add" ? "addTags" : "removeTags"
        results = ids.map do |id|
          begin
            {id, client.patch("/api/books/#{id}", {key => [tag]}).as(JSON::Any | Failure)}
          rescue ex : Failure
            {id, ex.as(JSON::Any | Failure)}
          end
        end
        errors = results.compact_map { |(_, r)| r.as?(Failure) }
        if @json
          @out.puts(results.map do |(id, r)|
            r.is_a?(Failure) ? {"id" => id, "error" => r.message} : {"id" => id, "book" => r}
          end.to_json)
        else
          books = results.compact_map { |(_, r)| r.as?(JSON::Any) }
          Output.table(@out, ["ID", "Title", "Tags"], books.map { |b| [b["id"].to_s, Output.value(b["title"]?), Output.value(b["tags"]?)] }, [nil, 50]) unless books.empty?
          results.each { |(id, r)| @err.puts "##{id}: #{r.message}" if r.is_a?(Failure) }
        end
        raise Failure.new(errors.first.code, "") unless errors.empty?
      end

      private def upload(args : Args)
        files = args.positional
        raise Usage.new("files expected", "upload") if files.empty?
        tags = args.all("tag").flat_map { |t| Runner.list(t) }
        kategorie = args["kategorie"]?.presence.try { |k| Runner.kategorie(k) }
        add_to = args["add-format-to"]?.try { |i| Runner.id(i) }
        results = files.map { |f| upload_one(f, tags, kategorie, args.flag?("force"), add_to) }
        @out.puts results.to_json if @json
        codes = results.compact_map { |r| r["exitCode"]?.try(&.as_i) }
        # a duplicate is the most likely thing to act on
        raise Failure.new(codes.includes?(CONFLICT) ? CONFLICT : codes.first, "") unless codes.empty?
      end

      private def upload_one(path, tags, kategorie, force, add_to) : Hash(String, JSON::Any)
        result = {"file" => JSON::Any.new(path)}
        raise Failure.new(USAGE, "no such file") unless File.file?(path)
        form = Runner.multipart(path, tags, kategorie, force, add_to)
        answer = begin
          File.open(form) do |body|
            client.json("POST", "/api/books", body, HTTP::Headers{
              "Content-Type"   => "multipart/form-data; boundary=#{BOUNDARY}",
              "Content-Length" => body.size.to_s,
            })
          end
        ensure
          File.delete?(form)
        end
        book = answer["book"]
        result["status"] = JSON::Any.new(add_to ? "formatAdded" : "added")
        result["book"] = book
        verb = add_to ? "format added to" : "added as"
        @out.puts "#{path}: #{verb} ##{book["id"]} #{Output.value(book["title"]?)} (#{Output.value(book["authors"]?)})" unless @json
        result
      rescue ex : HttpError
        if ex.status == 409 && (dups = ex.body["duplicates"]?)
          result.not_nil!["status"] = JSON::Any.new("duplicate")
          result.not_nil!["duplicates"] = dups
          result.not_nil!["exitCode"] = JSON::Any.new(CONFLICT.to_i64)
          unless @json
            @err.puts "#{path}: duplicate, not added (--force adds it anyway); matches:"
            dups.as_a.each { |b| @err.puts "  ##{b["id"]}  #{Output.value(b["title"]?)} (#{Output.value(b["authors"]?)})" }
            titles = ex.body["titles"]?.try(&.as_a?) || [] of JSON::Any
            titles.each { |t| @err.puts "  #{t}" } if dups.as_a.empty?
          end
          result.not_nil!
        else
          upload_error(path, ex)
        end
      rescue ex : Failure
        upload_error(path, ex)
      end

      private def upload_error(path, ex : Failure) : Hash(String, JSON::Any)
        @err.puts "#{path}: #{ex.message}" unless @json
        {"file" => JSON::Any.new(path), "status" => JSON::Any.new("error"),
         "error" => JSON::Any.new(ex.message.to_s), "exitCode" => JSON::Any.new(ex.code.to_i64)}
      end

      private def bulk(args : Args)
        if args.flag?("number-series")
          # numbered in the order of the ids, so a query has no order to use
          raise Usage.new("--number-series needs --ids and --series", "bulk") unless args["ids"]? && args["series"]?.presence
        end
        target, count = bulk_target(args)
        changes = Runner.bulk_changes(args)
        raise Usage.new("nothing to change", "bulk") if changes.empty?
        if count == 0
          raise Failure.new(NOT_FOUND, "no books match")
        end
        unless args.flag?("yes")
          confirm("Change #{count} #{count == 1 ? "book" : "books"}: #{Runner.describe(changes)}?")
        end
        started = client.post("/api/books/bulk", {"target" => target, "changes" => changes})
        job = wait_job(started["jobId"].as_s, started["total"]?.try(&.as_i64) || count)
        errors = job["errors"]?.try(&.as_a) || [] of JSON::Any
        if @json
          @out.puts job.to_json
        else
          total = job["total"]?.try(&.as_i64) || count
          @out.puts "#{job["status"]}: #{total - errors.size} of #{total} books changed#{errors.empty? ? "" : ", #{errors.size} failed:"}"
          Output.table(@out, ["ID", "Error"], errors.map { |e| [e["bookId"].to_s, e["error"].to_s] }) unless errors.empty?
        end
        return if errors.empty? && job["status"]? == "done"
        code = !errors.empty? && errors.all? { |e| e["error"]? == "not found" } ? NOT_FOUND : SERVER
        raise Failure.new(code, "")
      end

      private def bulk_target(args : Args) : {Hash(String, JSON::Any), Int64}
        ids = args["ids"]?
        query = args["query"]?
        raise Usage.new("--ids or --query expected", "bulk") unless ids || query
        raise Usage.new("--ids and --query cannot be combined", "bulk") if ids && query
        if ids
          list = Runner.list(ids).map { |i| Runner.id(i) }.uniq
          raise Usage.new("--ids is empty", "bulk") if list.empty?
          { {"ids" => JSON.parse(list.to_json)}, list.size.to_i64 }
        else
          q = query.not_nil!
          total = client.get("/api/books", HTTP::Params{"q" => q, "limit" => "1"})["total"].as_i64
          { {"query" => JSON::Any.new({"q" => JSON::Any.new(q)})}, total }
        end
      end

      # --- lists ------------------------------------------------------------

      private def list(args : Args)
        action = args.positional[0]? || raise Usage.new("ls, show, create, add, rm or delete expected", "list")
        rest = args.positional[1..]
        case action
        when "ls"
          lists = client.get("/api/lists")
          return @out.puts lists.to_json if @json
          return @out.puts "no lists" if lists.as_a.empty?
          if args.flag?("tree")
            Output.table(@out, ["ID", "Name", "Books", "Total", "Flags"], Runner.list_tree(lists.as_a), [nil, 50])
          else
            Output.table(@out, ["ID", "Name", "Books", "Flags"], lists.as_a.map { |l| [l["id"].to_s, l["name"].as_s, l["count"].to_s, Runner.list_flags(l)] }, [nil, 50])
          end
        when "show"
          raise Usage.new("one list expected", "list") unless rest.size == 1
          l, path, owner = find_node(rest[0])
          params = l ? HTTP::Params{"list" => l["id"].to_s} : HTTP::Params{"listPath" => path, "listOwner" => owner}
          params["direct"] = "1" if args.flag?("direct")
          {"sort", "order"}.each { |k| args[k]?.presence.try { |v| params[k] = v } }
          {"limit", "offset"}.each { |k| args[k]?.try { |v| params[k] = Runner.int(k, v, min: 0).to_s } }
          page = client.get("/api/books", params)
          return @out.puts({list: l, path: path, books: page}.to_json) if @json
          if l
            n = l["count"].as_i64
            total = l["totalCount"]?.try(&.as_i64?) || n
            with_sub = total == n ? "" : ", #{total} with sublists#{args.flag?("direct") ? "" : " (shown)"}"
            @out.puts "#{l["name"].as_s} (##{l["id"]}, #{n} #{n == 1 ? "book" : "books"}#{with_sub}#{(f = Runner.list_flags(l)) == "-" ? "" : ", #{f}"})"
            l["description"].as_s.presence.try { |d| @out.puts d }
          else
            @out.puts "#{path}/ (no list of its own, the books of its sublists)"
          end
          books = page["books"].as_a
          @out.puts
          books.empty? ? @out.puts("no books") : Output.books(@out, books, category)
          total = page["total"].as_i64
          offset = page["offset"].as_i64
          @out.puts "#{offset + 1}-#{offset + books.size} of #{total} books (--offset #{offset + books.size} for more)" if books.size < total && !books.empty?
        when "create"
          raise Usage.new("one name expected", "list") unless rest.size == 1
          body = {"name" => JSON::Any.new(rest[0])}
          args["description"]?.try { |d| body["description"] = JSON::Any.new(d) }
          args["visibility"]?.try { |v| body["visibility"] = JSON::Any.new(v) }
          {"sync" => "sync", "favorite" => "favorite", "default" => "isDefault"}.each do |flag, key|
            body[key] = JSON::Any.new(true) if args.flag?(flag)
          end
          l = client.post("/api/lists", body)
          @json ? @out.puts(l.to_json) : @out.puts("created list ##{l["id"]} #{l["name"].as_s}")
        when "add", "rm"
          raise Usage.new("a list and book ids expected", "list") if rest.size < 2
          l = find_list(rest[0])
          ids = rest[1..].map { |i| Runner.id(i) }
          path = action == "add" ? "/api/lists/#{l["id"]}/books" : "/api/lists/#{l["id"]}/books/remove"
          r = client.post(path, {"bookIds" => ids})
          return @out.puts r.to_json if @json
          changed = (r[action == "add" ? "added" : "removed"]?.try(&.as_a) || [] of JSON::Any).map(&.as_i64)
          verb = action == "add" ? "added to" : "removed from"
          @out.puts "#{changed.size} #{changed.size == 1 ? "book" : "books"} #{verb} #{r["list"]["name"].as_s} (now #{r["list"]["count"]})"
          skipped = ids - changed
          @err.puts "#{action == "add" ? "already in the list or unknown" : "not in the list"}: #{skipped.join(", ")}" unless skipped.empty?
        when "delete"
          raise Usage.new("one list expected", "list") unless rest.size == 1
          l = find_list(rest[0])
          confirm("Delete the list #{l["name"].as_s} (#{l["count"]} books stay in the library)?", "list") unless args.flag?("yes")
          r = client.json("DELETE", "/api/lists/#{l["id"]}")
          @json ? @out.puts(r.to_json) : @out.puts("deleted list #{l["name"].as_s}")
        else
          raise Usage.new("ls, show, create, add, rm or delete expected, not #{action}", "list")
        end
      end

      # a list by id or name/path (ignoring case, "Urlaub / 2026" is
      # "Urlaub/2026")
      private def find_list(ref : String) : JSON::Any
        find_list?(client.get("/api/lists").as_a, ref) || raise Failure.new(NOT_FOUND, "list #{ref} not found")
      end

      private def find_list?(lists : Array(JSON::Any), ref : String) : JSON::Any?
        path = Runner.list_path(ref)
        ref.to_i64?.try { |id| lists.find { |l| l["id"].as_i64 == id } } ||
          lists.find { |l| Runner.list_path(l["name"].as_s).downcase == path.downcase }
      end

      # A list, or a path with sublists but no list of its own: {nil, path,
      # owner} (own lists come first)
      private def find_node(ref : String) : {JSON::Any?, String, String}
        lists = client.get("/api/lists").as_a
        if l = find_list?(lists, ref)
          return {l, l["name"].as_s, l["owner"].as_s}
        end
        path = Runner.list_path(ref)
        below = lists.find { |x| Runner.list_path(x["name"].as_s).downcase.starts_with?("#{path.downcase}/") }
        raise Failure.new(NOT_FOUND, "list #{ref} not found") unless below && !path.empty?
        {nil, Runner.list_path(below["name"].as_s)[0, path.size], below["owner"].as_s}
      end

      def self.list_path(name : String) : String
        name.split('/').map(&.strip).reject(&.empty?).join('/')
      end

      # ls --tree: one row per level, indented; a level without a list of
      # its own ends in "/". Others' trees carry the owner.
      def self.list_tree(lists : Array(JSON::Any)) : Array(Array(String))
        rows = [] of Array(String)
        groups = lists.group_by { |l| l["owner"]?.try(&.as_s?) || "" }
        first = groups.keys.first?
        groups.each do |owner, ls|
          named = ls.to_h { |l| {list_path(l["name"].as_s).downcase, l} }
          paths = {} of String => Array(String)
          ls.each do |l|
            levels = list_path(l["name"].as_s).split('/')
            levels.size.times { |i| paths[levels[0..i].join('/').downcase] ||= levels[0..i] }
          end
          paths.values.sort_by(&.map(&.downcase)).each do |levels|
            l = named[levels.join('/').downcase]?
            name = "#{"  " * (levels.size - 1)}#{levels.last}#{l ? "" : "/"}"
            name += " (#{owner})" if levels.size == 1 && owner != first
            rows << if l
              [l["id"].to_s, name, l["count"].to_s, (l["totalCount"]? || l["count"]).to_s, list_flags(l)]
            else
              ["-", name, "-", "-", "-"]
            end
          end
        end
        rows
      end

      def self.list_flags(l : JSON::Any) : String
        flags = [] of String
        flags << "shelf" if (r = l["rule"]?) && !r.raw.nil?
        flags << "default" if l["isDefault"]?.try(&.as_bool?)
        flags << "sync" if l["sync"]?.try(&.as_bool?)
        flags << "favorite" if l["favorite"]?.try(&.as_bool?)
        vis = l["visibility"]?.try(&.as_s?)
        flags << vis if vis && vis != "private"
        flags << "read-only" if l["editable"]?.try(&.as_bool?) == false
        flags.empty? ? "-" : flags.join(", ")
      end

      private def confirm(question : String, command = "bulk")
        tty = @in.as?(IO::FileDescriptor).try(&.tty?)
        raise Usage.new("#{question} Add --yes to confirm without a terminal", command) unless tty
        @err.print "#{question} [y/N] "
        @err.flush
        answer = @in.gets.to_s.strip.downcase
        raise Failure.new(USAGE, "cancelled") unless {"y", "yes", "j", "ja"}.includes?(answer)
      end

      # polls until the job is no longer queued or running
      private def wait_job(id : String, total : Int64) : JSON::Any
        progress = !@json && @err.as?(IO::FileDescriptor).try(&.tty?)
        loop do
          job = begin
            client.get("/api/jobs/#{id}")
          rescue ex : HttpError
            raise ex unless ex.status == 404
            raise Failure.new(SERVER, "job #{id} is gone (hub restarted?)")
          end
          status = job["status"]?.try(&.as_s?) || "running"
          if progress
            @err.print "\r#{job["done"]? || 0}/#{job["total"]? || total}"
            @err.flush
          end
          unless {"running", "queued", "pending"}.includes?(status)
            @err.print "\r" if progress
            return job
          end
          sleep @poll_interval
        end
      end

      # --- helpers ----------------------------------------------------------

      private def completion(args : Args)
        shell = args.positional.first? || raise Usage.new("fish or bash expected", "completion")
        progs = args["prog"]?.try { |p| [p] } || ["hub", "calibre-hub"]
        case shell
        when "fish" then @out.print Completion.fish(progs)
        when "bash" then @out.print Completion.bash(progs)
        else             raise Usage.new("fish or bash expected", "completion")
        end
      end

      private def fetch(id : Int64) : JSON::Any
        client.get("/api/books/#{id}")
      rescue ex : HttpError
        raise ex unless ex.status == 404
        raise Failure.new(NOT_FOUND, "book #{id} not found", ex.data)
      end

      # the custom column shown as category (from /api/config)
      private def category : String?
        unless @category_read
          @category = client.get("/api/config")["categoryColumn"]?.try(&.as_s?)
          @category_read = true
        end
        @category
      end

      private def id_arg(args : Args) : Int64
        raise Usage.new("one book id expected", args.command.name) unless args.positional.size == 1
        Runner.id(args.positional.first)
      end

      # streams a binary answer into path (- for stdout), via a .part file
      private def save(api_path : String, path : String) : Int64
        bytes = 0_i64
        if path == "-"
          client.download(api_path) { |r| bytes = IO.copy(r.body_io, @out) }
          return bytes
        end
        part = "#{path}.part"
        begin
          client.download(api_path) do |r|
            File.open(part, "w") { |f| bytes = IO.copy(r.body_io, f) }
          end
          File.rename(part, path)
        ensure
          File.delete?(part)
        end
        bytes
      rescue ex : File::Error
        raise Failure.new(USAGE, "cannot write #{path}: #{ex.message}")
      end

      private def report_file(path : String, bytes : Int64, what : String, format : String? = nil)
        return if path == "-"
        if @json
          @out.puts({path: path, bytes: bytes, format: format}.to_json)
        else
          @out.puts "#{what}: #{Output.size(bytes)} saved to #{path}"
        end
      end

      BOUNDARY = "calibre-hub-cli-boundary-7d3f1a"

      # the multipart body as a temp file, so it goes out with a length
      def self.multipart(path : String, tags : Array(String), kategorie : String?, force : Bool, add_to : Int64?) : String
        tmp = File.tempfile("hub-upload")
        HTTP::FormData.build(tmp, BOUNDARY) do |form|
          File.open(path) do |f|
            form.file("file", f, HTTP::FormData::FileMetadata.new(filename: File.basename(path)))
          end
          tags.each { |t| form.field("tags", t) }
          kategorie.try { |k| form.field("kategorie", k) }
          form.field("force", "1") if force
          add_to.try { |i| form.field("addFormatTo", i.to_s) }
        end
        tmp.close
        tmp.path
      end

      # --- pure helpers (specced) ------------------------------------------

      def self.id(text : String) : Int64
        text.lchop('#').to_i64? || raise Usage.new("book id expected, not #{text.inspect}")
      end

      def self.int(name : String, text : String, min = 0) : Int64
        n = text.to_i64? || raise Usage.new("--#{name} needs a number, not #{text.inspect}")
        raise Usage.new("--#{name} must be at least #{min}") if n < min
        n
      end

      def self.list(text : String) : Array(String)
        text.split(',').map(&.strip).reject(&.empty?).uniq
      end

      # A/B and A.B both mean the category A.B
      def self.kategorie(text : String) : String
        text.split(/[\/.]/).map(&.strip).reject(&.empty?).join('.')
      end

      def self.file_name(book : JSON::Any, format : String) : String
        author = book["authors"]?.try(&.as_a.first?).try(&.as_s?)
        title = book["title"]?.try(&.as_s?) || "book-#{book["id"]}"
        name = [author, title].compact.join(" - ").gsub(/[\/\\:*?"<>|\x00-\x1f]/, "_").strip
        "#{name[0, 150]}.#{format}"
      end

      # PATCH body from the edit options; "" clears optional fields
      def self.edit_changes(args : Args, stdin : IO) : Hash(String, JSON::Any)
        c = {} of String => JSON::Any
        args["title"]?.try { |v| c["title"] = JSON::Any.new(v) }
        args["authors"]?.try { |v| c["authors"] = JSON.parse(list(v).to_json) }
        {"series" => "series", "publisher" => "publisher"}.each do |opt, key|
          args[opt]?.try { |v| c[key] = JSON::Any.new(v.strip.presence) }
        end
        args["index"]?.try do |v|
          n = v.to_f? || raise Usage.new("--index needs a number, not #{v.inspect}", "edit")
          raise Usage.new("--index must not be negative", "edit") if n < 0
          c["seriesIndex"] = JSON::Any.new(n)
        end
        args["tags"]?.try { |v| c["tags"] = JSON.parse(list(v).to_json) }
        args["languages"]?.try { |v| c["languages"] = JSON.parse(list(v).to_json) }
        args["kategorie"]?.try { |v| c["kategorie"] = JSON::Any.new(kategorie(v).presence) }
        args["comments-file"]?.try do |path|
          text = path == "-" ? stdin.gets_to_end : (File.read(path) rescue raise Usage.new("cannot read #{path}", "edit"))
          c["comments"] = JSON::Any.new(text.strip.presence)
        end
        args["pubdate"]?.try do |v|
          raise Usage.new("--pubdate must be YYYY-MM-DD", "edit") unless v.empty? || v.matches?(/\A\d{4}-\d{2}-\d{2}\z/)
          c["pubdate"] = JSON::Any.new(v.presence)
        end
        args["rating"]?.try do |v|
          r = v.empty? ? 0_i64 : (v.to_i64? || raise Usage.new("--rating must be 0-10", "edit"))
          raise Usage.new("--rating must be 0-10", "edit") unless 0 <= r <= 10
          c["rating"] = JSON::Any.new(r)
        end
        unless (ids = args.all("identifier")).empty?
          ids.each { |i| raise Usage.new("--identifier must be TYPE=VALUE, not #{i.inspect}", "edit") unless i.matches?(/\A[^=\s]+=/) }
          # merged into the book's identifiers once they are read
          c["identifier"] = JSON.parse(ids.to_json)
        end
        c
      end

      # the API replaces all identifiers; TYPE= removes one
      def self.identifiers(current : JSON::Any?, given : Array(String)) : JSON::Any
        result = (current.try(&.as_h?) || {} of String => JSON::Any).transform_values(&.to_s)
        given.each do |i|
          key, _, value = i.partition('=')
          value.strip.empty? ? result.delete(key.strip) : (result[key.strip] = value.strip)
        end
        JSON.parse(result.to_json)
      end

      # PATCH key for a book field in a conflict diff
      def self.edit_key(field : String) : String?
        case field
        when "seriesIndex", "title", "authors", "series", "tags", "publisher", "pubdate",
             "rating", "languages", "identifiers", "comments"
          field
        when "formats" then nil
        else                "kategorie" # custom column
        end
      end

      def self.bulk_changes(args : Args) : Hash(String, JSON::Any)
        c = {} of String => JSON::Any
        args["add-tags"]?.try { |v| c["addTags"] = JSON.parse(list(v).to_json) }
        args["remove-tags"]?.try { |v| c["removeTags"] = JSON.parse(list(v).to_json) }
        args["kategorie"]?.try { |v| c["kategorie"] = JSON::Any.new(kategorie(v).presence) }
        args["series"]?.try { |v| c["series"] = JSON::Any.new(v.strip.presence) }
        c["numberSeries"] = JSON::Any.new(true) if args.flag?("number-series")
        c
      end

      def self.describe(changes : Hash(String, JSON::Any)) : String
        changes.map do |k, v|
          case k
          when "addTags"      then "add tags #{Output.value(v)}"
          when "removeTags"   then "remove tags #{Output.value(v)}"
          when "numberSeries" then "number the series"
          else                     v.raw.nil? ? "clear #{k}" : "#{k} = #{Output.value(v)}"
          end
        end.join(", ")
      end
    end
  end
end
