require "json"

module CalibreHub
  module Cli
    class Runner
      # hub import <path>... [--apply] [--limit N] | status | cleanup ... | undo <id>
      private def import(args : Args)
        first = args.positional.first? || raise Usage.new("path, status, cleanup or undo expected", "import")
        case first
        when "status"  then import_status
        when "cleanup" then import_cleanup(args)
        when "undo"    then import_undo(args)
        else                import_paths(args.positional, args)
        end
      end

      private def import_paths(paths : Array(String), args : Args)
        apply = args.flag?("apply")
        # paths on the hub's host; relative to its first import root
        body = {} of String => JSON::Any
        if paths.size == 1
          body["path"] = JSON::Any.new(paths.first)
        else
          body["paths"] = JSON.parse(paths.to_json)
        end
        body["dryRun"] = JSON::Any.new(!apply)
        if l = args["limit"]?
          n = l.to_i? || 0
          raise Usage.new("--limit: a number of 1 or more expected", "import") if n < 1
          body["limit"] = JSON::Any.new(n.to_i64)
        end
        run = wait_scan(client.post("/api/import", body))
        unless run["summary"]?.try(&.as_h?)
          error = run["error"]?.try(&.as_s?) || run["status"]?.to_s
          raise Failure.new(SERVER, "scan of #{run["path"]} failed: #{error}")
        end
        if apply
          job = wait_job(run["jobId"].as_s, run["total"]?.try(&.as_i64?) || 0_i64)
          run = client.get("/api/import/runs/#{run["id"]}")
          save_report(run, args)
          if @json
            @out.puts run.to_json
          else
            import_summary(run)
            results = run["results"].as_h.map { |k, v| "#{v} #{k}" }.join(", ")
            @out.puts "#{job["status"]}: #{results}#{job["error"]?.try(&.as_s?).try { |e| " (#{e})" }}"
          end
          raise Failure.new(SERVER, "") unless job["status"]? == "done"
        else
          save_report(run, args)
          return @out.puts run.to_json if @json
          import_summary(run)
          @out.puts "dry run, nothing imported (--apply imports)"
        end
      end

      # Polls a run while its job scans, with the files and books so far
      private def wait_scan(run : JSON::Any) : JSON::Any
        progress = !@json && @err.as?(IO::FileDescriptor).try(&.tty?)
        while run["status"]?.try(&.as_s?) == "scanning"
          if progress && (scan = run["scan"]?.try(&.as_h?))
            planned = scan["planned"]?.try(&.as_i?) || 0
            @err.print "\rscanning: #{scan["files"]? || 0} files, #{scan["units"]? || 0} books#{planned > 0 ? ", #{planned} checked" : ""}"
            @err.flush
          end
          sleep @poll_interval
          run = client.get("/api/import/runs/#{run["id"]}")
        end
        @err.print "\r\e[K" if progress
        run
      end

      private def save_report(run : JSON::Any, args : Args)
        file = args["report"]? || return
        File.write(file, client.get("/api/import/runs/#{run["id"]}/report").to_pretty_json)
        @err.puts "report saved to #{file}" unless @json
      end

      private def import_summary(run : JSON::Any)
        s = run["summary"]
        counts = ->(h : JSON::Any) { h.as_h.reject { |k, _| k == "total" }.map { |k, v| "#{k} #{v}" }.join(", ") }
        @out.puts "#{run["path"]} (run #{run["id"]})"
        @out.puts "  scanned #{run["scan"]["files"]} files" if run["scan"]?.try(&.as_h?)
        @out.puts "  #{s["books"]} books in #{s["files"]} files (#{counts.call(s["formats"])})"
        @out.puts "  #{s["calibreFolders"]} from calibre folders (#{s["withCover"]} with cover), #{s["plainFiles"]} from plain files"
        @out.puts "  to add: #{s["toAdd"]}, formats for books in the library: #{s["toAddFormats"]}"
        d = s["duplicates"]
        @out.puts "  duplicates: #{d["total"]}#{d.as_h.size > 1 ? " (#{counts.call(d)})" : ""}"
        @out.puts "  imported before: #{s["alreadyImported"]}" if s["alreadyImported"].as_i > 0
        if (limit = s["limit"]?.try(&.as_i?)) && (sel = s["selected"]?)
          @out.puts "  this run (--limit #{limit}): #{sel["books"]} books: add #{sel["toAdd"]}, formats #{sel["toAddFormats"]}, duplicates #{sel["duplicates"]}; #{s["deferred"]} left for later runs"
        end
        sk = s["skipped"]
        @out.puts "  skipped: #{sk["total"]} (#{counts.call(sk["byReason"])})"
        types = sk["byType"].as_h.first(15).map { |k, v| "#{k} #{v}" }.join(", ")
        @out.puts "    by type: #{types}" unless types.empty?
        sk["byFolder"].as_a.first(10).each do |f|
          @out.puts "    #{f["folder"]}: #{f["count"]} (#{f["types"].as_h.first(5).map { |k, v| "#{k} #{v}" }.join(", ")})"
        end
      end

      private def import_status
        st = client.get("/api/import")
        return @out.puts st.to_json if @json
        unless st["enabled"].as_bool
          @out.puts "backlog import is off (no backlogImport.roots)"
        else
          @out.puts "roots: #{st["roots"].as_a.join(", ")}#{st["running"].as_bool ? ", an import is running (hooks paused)" : ""}"
          st["runs"].as_a.each do |r|
            progress = case
                       when r["status"] == "scanning"
                         "scanning #{r["scan"]?.try(&.as_h?).try(&.["files"]?) || 0} files"
                       when r["dryRun"].as_bool
                         r["status"] == "planned" ? "dry run" : "dry run #{r["status"]}"
                       else
                         "#{r["status"]} #{r["done"]}/#{r["total"]}"
                       end
            books = r["summary"]?.try(&.as_h?).try(&.["books"]?).try { |b| "  #{b} books" } || ""
            results = r["results"].as_h.map { |k, v| "#{v} #{k}" }.join(", ")
            @out.puts "  #{r["id"]}  #{r["createdAt"]}  #{r["path"]}  #{progress}#{books}  #{results}"
          end
        end
        st["cleanups"].as_a.each do |c|
          @out.puts "  cleanup #{c["id"]}  #{c["createdAt"]}  #{c["total"]} books  #{c["job"]["status"]? || "-"}#{c["undoJob"].raw ? ", undone: #{c["undoJob"]["status"]}" : ""}"
        end
      end

      private def import_cleanup(args : Args)
        body = {} of String => JSON::Any
        args["since"]?.try { |s| body["since"] = JSON::Any.new(s) }
        args["min-id"]?.try { |v| body["minId"] = JSON::Any.new(Runner.id(v)) }
        args["max-id"]?.try { |v| body["maxId"] = JSON::Any.new(Runner.id(v)) }
        raise Usage.new("--since or --min-id expected", "import") if body.empty?
        apply = args.flag?("apply")
        body["dryRun"] = JSON::Any.new(!apply)
        result = client.post("/api/import/cleanup", body)
        if apply
          job = wait_job(result["job"]["id"].as_s, result["entries"].as_a.size.to_i64)
          return @out.puts client.get("/api/import/cleanups/#{result["id"]}").to_json if @json
          @out.puts "cleanup #{result["id"]}: #{job["status"]}, #{job["done"]} books (undo: #{prog} import undo #{result["id"]} --apply)"
          raise Failure.new(SERVER, "") unless job["status"]? == "done"
        else
          return @out.puts result.to_json if @json
          cleanup_entries(result["entries"].as_a)
          @out.puts "#{result["total"]} books, dry run (--apply changes them)"
        end
      end

      private def import_undo(args : Args)
        id = args.positional[1]? || raise Usage.new("cleanup id expected", "import")
        apply = args.flag?("apply")
        result = client.post("/api/import/cleanups/#{id}/undo", {"dryRun" => !apply})
        if apply
          job = wait_job(result["undoJob"]["id"].as_s, result["entries"].as_a.size.to_i64)
          return @out.puts job.to_json if @json
          @out.puts "undo of #{id}: #{job["status"]}, #{job["done"]} books"
          raise Failure.new(SERVER, "") unless job["status"]? == "done"
        else
          return @out.puts result.to_json if @json
          cleanup_entries(result["entries"].as_a)
          @out.puts "#{result["total"]} books get their category and tags back, dry run (--apply does it)"
        end
      end

      private def cleanup_entries(entries : Array(JSON::Any))
        rows = entries.map do |e|
          [e["bookId"].to_s, Output.value(e["title"]?), e["clearKategorie"].as_bool ? e["kategorie"].to_s : "",
           e["removeTags"].as_a.join(", ")]
        end
        Output.table(@out, ["ID", "Title", "Category cleared", "Tags removed"], rows) unless rows.empty?
      end
    end
  end
end
