require "json"

module CalibreHub
  module Cli
    class Runner
      # hub import <path> [--apply] | status | cleanup ... | undo <id>
      private def import(args : Args)
        first = args.positional.first? || raise Usage.new("path, status, cleanup or undo expected", "import")
        case first
        when "status"  then import_status
        when "cleanup" then import_cleanup(args)
        when "undo"    then import_undo(args)
        else                import_path(first, args)
        end
      end

      private def import_path(path : String, args : Args)
        apply = args.flag?("apply")
        # a path on the hub's host; relative to its first import root
        run = client.post("/api/import", {"path" => path, "dryRun" => !apply})
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

      private def save_report(run : JSON::Any, args : Args)
        file = args["report"]? || return
        File.write(file, client.get("/api/import/runs/#{run["id"]}/report").to_pretty_json)
        @err.puts "report saved to #{file}" unless @json
      end

      private def import_summary(run : JSON::Any)
        s = run["summary"]
        counts = ->(h : JSON::Any) { h.as_h.reject { |k, _| k == "total" }.map { |k, v| "#{k} #{v}" }.join(", ") }
        @out.puts "#{run["path"]} (run #{run["id"]})"
        @out.puts "  #{s["books"]} books in #{s["files"]} files (#{counts.call(s["formats"])})"
        @out.puts "  #{s["calibreFolders"]} from calibre folders (#{s["withCover"]} with cover), #{s["plainFiles"]} from plain files"
        @out.puts "  to add: #{s["toAdd"]}, formats for books in the library: #{s["toAddFormats"]}"
        d = s["duplicates"]
        @out.puts "  duplicates: #{d["total"]}#{d.as_h.size > 1 ? " (#{counts.call(d)})" : ""}"
        @out.puts "  imported before: #{s["alreadyImported"]}" if s["alreadyImported"].as_i > 0
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
            progress = r["dryRun"].as_bool ? "dry run" : "#{r["status"]} #{r["done"]}/#{r["total"]}"
            results = r["results"].as_h.map { |k, v| "#{v} #{k}" }.join(", ")
            @out.puts "  #{r["id"]}  #{r["createdAt"]}  #{r["path"]}  #{progress}  #{r["summary"]["books"]} books  #{results}"
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
