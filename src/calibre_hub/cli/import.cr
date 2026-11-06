require "json"

module CalibreHub
  module Cli
    class Runner
      # hub import cleanup ... | undo <id>. status, analysis and repair recheck
      # are the old names of hub eingang's.
      private def import(args : Args)
        first = args.positional.first? || raise Usage.new("cleanup or undo expected", "import")
        case first
        when "status"   then import_status
        when "cleanup"  then import_cleanup(args)
        when "undo"     then import_undo(args)
        when "analysis" then import_analysis(args)
        when "repair"
          raise Usage.new("only repair recheck is left, the books' proposals are in the Eingang", "import") unless args.positional[1]? == "recheck"
          import_recheck(args)
        else
          raise Usage.new("#{first}: a backlog is imported through the Eingang now, cleanup or undo expected", "import")
        end
      end

      # the Eingang and the cleanups there are to undo
      private def import_status
        eingang_status
        return if @json
        client.get("/api/import/cleanups").as_a.each do |c|
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

      # hub eingang: what is in the list, by source, and what happens by itself
      private def eingang(args : Args)
        case args.positional.first?
        when nil        then eingang_status
        when "analysis" then import_analysis(args)
        when "recheck"  then import_recheck(args)
        else                 raise Usage.new("analysis or recheck expected", "eingang")
        end
      end

      private def eingang_status
        st = client.get("/api/intake?limit=1")
        return @out.puts st.to_json if @json
        unless st["enabled"].as_bool
          @out.puts "the Eingang is off"
          return
        end
        p = st["progress"]
        @out.puts "eingang: #{p["total"]} books, #{p["analysed"]} analysed, analysis #{p["state"]}"
        p["current"]?.try(&.as_s?).try { |c| @out.puts "  at #{c}" }
        origins = st["origins"].as_h.map { |k, v| "#{k} #{v}" }.join(", ")
        @out.puts "  from: #{origins}" unless origins.empty?
        takes = st["thresholds"].as_h.map { |k, v| v.raw.nil? ? "#{k} off" : "#{k} from #{v}" }.join(", ")
        @out.puts "  taken by itself: #{takes}"
        pending = st["pending"].as_i64
        @out.puts "  #{pending} decided, on their way" if pending > 0
      end

      # hub eingang analysis off|on: stops the backlog's analysis or lets it
      # go on; the inbox and uploads don't stop
      private def import_analysis(args : Args)
        on = case args.positional[1]?
             when "on"  then true
             when "off" then false
             else            raise Usage.new("on or off expected", "eingang")
             end
        result = client.post("/api/intake/analysis", {"on" => on})
        return @out.puts result.to_json if @json
        @out.puts "analysis: #{result["state"]}, #{result["done"]} of #{result["total"]}"
      end

      # plans the books no plan got to; runs behind the analysis, so it isn't
      # waited for
      private def import_recheck(args : Args)
        body = {} of String => JSON::Any
        args["run"]?.try { |r| body["run"] = JSON::Any.new(r) }
        result = client.post("/api/import/repair/recheck", body)
        return @out.puts result.to_json if @json
        @out.puts "recheck: #{result["books"]} books, job #{result["job"]["id"]} (proposals land in the Eingang under „Schon in der Bibliothek“)"
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
