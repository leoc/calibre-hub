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
        when "repair"  then import_repair(args)
        when "quality" then import_quality(args)
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
          st["phase"]?.try(&.as_s?).try { |p| @out.puts "phase: #{p}" }
          st["backlog"]?.try(&.as_h?).try { |b| backlog_line(b) }
          st["followup"]?.try(&.as_h?).try do |f|
            queues = f["queues"].as_h.map { |k, v| "#{k} #{v}" }.join(", ")
            @out.puts "followup: #{f["total"]} books#{queues.empty? ? "" : " (#{queues})"}#{f["paused"].as_bool ? ", waiting for the import" : ""}"
          end
          st["runs"].as_a.each do |r|
            progress = case
                       when r["status"] == "scanning" && r["phase"]? == "check"
                         scan = r["scan"]
                         "checking #{scan["planned"]}/#{scan["units"]} books"
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
            run_details(r)
          end
        end
        st["cleanups"].as_a.each do |c|
          @out.puts "  cleanup #{c["id"]}  #{c["createdAt"]}  #{c["total"]} books  #{c["job"]["status"]? || "-"}#{c["undoJob"].raw ? ", undone: #{c["undoJob"]["status"]}" : ""}"
        end
      end

      # imported of the backlog's new books, what is open by the latest run
      private def backlog_line(b : Hash(String, JSON::Any))
        imported = b["imported"].as_i64
        total = b["total"].as_i64
        open = b["open"]
        pct = total > 0 ? " (#{(imported * 100.0 / total).round(1)} %)" : ""
        eta = b["etaSeconds"]?.try(&.as_i64?).try { |s| ", about #{Runner.duration(s)} left" } || ""
        @out.puts "backlog: #{imported} of ~#{total} new books imported#{pct}, #{b["formatAdded"]} with formats added, #{b["duplicates"]} duplicates#{eta}"
        basis = b["basis"]?.try(&.as_h?).try { |r| " (by run #{r["runId"]}: #{r["paths"].as_a.join(", ")})" } || ""
        @out.puts "  open: #{open["books"]} books, #{open["formats"]} with formats to add, #{open["duplicates"]} duplicates, #{open["failed"]} failed#{basis}"
      end

      # where a scanning or running run is, its times and failed books
      private def run_details(r : JSON::Any)
        if {"scanning", "running"}.includes?(r["status"]?.try(&.as_s?))
          parts = [] of String
          r["elapsedSeconds"]?.try(&.as_i64?).try { |s| parts << "running #{Runner.duration(s)}" }
          r["filesPerSecond"]?.try(&.as_f?).try { |v| parts << "#{v} files/s" }
          r["booksPerMinute"]?.try(&.as_f?).try { |v| parts << "#{v} books/min" }
          r["etaSeconds"]?.try(&.as_i64?).try { |s| parts << "about #{Runner.duration(s)} left" }
          @out.puts "    #{parts.join(", ")}" unless parts.empty?
          r["current"]?.try(&.as_s?).try { |c| @out.puts "    at #{c}" }
        end
        failures = r["failures"]?.try(&.as_a?) || [] of JSON::Any
        failures.first(5).each { |f| @out.puts "    failed: #{f["path"]}: #{f["detail"]? || "-"}" }
        n = r["results"]["failed"]?.try(&.as_i?) || failures.size
        @out.puts "    … #{n - 5} more failed" if n > 5
      end

      # 3725 -> "1h 02m", 250 -> "4m 10s"
      def self.duration(seconds : Int64) : String
        h, rest = seconds.divmod(3600)
        m, s = rest.divmod(60)
        return "#{h}h #{m.to_s.rjust(2, '0')}m" if h > 0
        return "#{m}m #{s.to_s.rjust(2, '0')}s" if m > 0
        "#{s}s"
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

      # hub import quality [--run ID] [--since TIME] [--min-id N] [--max-id N]
      private def import_quality(args : Args)
        query = URI::Params.build do |q|
          args["run"]?.try { |v| q.add("run", v) }
          args["since"]?.try { |v| q.add("since", v) }
          args["min-id"]?.try { |v| q.add("minId", Runner.id(v).to_s) }
          args["max-id"]?.try { |v| q.add("maxId", Runner.id(v).to_s) }
        end
        report = client.get("/api/import/quality#{query.empty? ? "" : "?#{query}"}")
        return @out.puts report.to_json if @json
        @out.puts "#{report["suspect"]} of #{report["total"]} books suspicious"
        report["reasons"].as_h.each { |reason, count| @out.puts "  #{reason}: #{count}" unless count == 0 }
        report["runs"].as_a.each { |r| @out.puts "  run #{r["run"]}  #{r["at"]}  #{r["suspect"]} of #{r["total"]}" }
        if bands = report["bands"]?
          @out.puts "confidence: #{bands.as_h.map { |band, count| "#{band} #{count}" }.join(", ")}"
          isbn = report["isbn"]
          @out.puts "ISBN: #{isbn["with"]} books (#{isbn["sources"].as_h.map { |s, count| "#{s} #{count}" }.join(", ")}), #{isbn["without"]} without"
          c = report["conflicts"]
          @out.puts "conflicts: #{c["duplicateCount"]} ISBNs on two books, #{c["notedCount"]} books noted"
          report["samples"].as_a.each { |s| @out.puts "  sample #{s["band"]}: #{s["correct"]} of #{s["checked"]} right" }
        end
        rows = report["books"].as_a.map { |b| [b["id"].to_s, b["title"].as_s, b["authors"].as_a.join(", "), b["reasons"].as_a.join(", ")] }
        Output.table(@out, ["ID", "Title", "Authors", "Why"], rows) unless rows.empty?
      end

      # hub import repair [--library] [--since TIME] [--min-id N] [--max-id N] [--apply]
      private def import_repair(args : Args)
        body = {} of String => JSON::Any
        args["since"]?.try { |s| body["since"] = JSON::Any.new(s) }
        args["min-id"]?.try { |v| body["minId"] = JSON::Any.new(Runner.id(v)) }
        args["max-id"]?.try { |v| body["maxId"] = JSON::Any.new(Runner.id(v)) }
        body["library"] = JSON::Any.new(true) if args.flag?("library")
        apply = args.flag?("apply")
        body["dryRun"] = JSON::Any.new(!apply)
        # the plan is a job (the book's pages, the catalogs, the model)
        result = client.post("/api/import/repair", body)
        job = wait_job(result["job"]["id"].as_s, result["books"].as_i64)
        raise Failure.new(SERVER, "repair #{job["status"]}: #{job["error"]? || ""}") unless job["status"]? == "done"
        if apply
          return @out.puts job.to_json if @json
          errors = job["errors"]?.try(&.as_a.size) || 0
          @out.puts "repair: done, #{job["done"]} books checked#{errors > 0 ? ", #{errors} failed" : ""} (the rest waits for a review; revert: Metadaten page or POST /api/metadata/changes/revert)"
          return
        end
        review = client.get("/api/import/repair")
        return @out.puts review.to_json if @json
        rows = review["entries"].as_a.flat_map do |e|
          e["changes"].as_a.map do |c|
            [e["bookId"].to_s, c["field"].as_s, Output.value(c["old"]?), Output.value(c["new"]?),
             e["decided"]?.try(&.as_s?) || "-", e["confidence"]?.try(&.as_i?).try(&.to_s) || "-",
             e["level"]?.try(&.as_i?).try(&.to_s) || "-", File.basename(e["file"].as_s.presence || "-")]
          end
        end
        Output.table(@out, ["ID", "Field", "Now", "Proposed", "Decided by", "Sure", "Level", "File"], rows) unless rows.empty?
        @out.puts "#{review["entries"].as_a.size} books, #{rows.size} changes to review (import page; --apply accepts what is 90 or surer)"
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
