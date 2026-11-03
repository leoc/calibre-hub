require "bubbletea"
require "../cli"
require "./actions"
require "./command_line"
require "./form"

module CalibreHub
  module Tui
    # A step back of a write: what it says and the command that does it
    class Undo
      getter label : String

      def initialize(@label : String, &@run : -> Tea::Cmd?)
      end

      def run : Tea::Cmd?
        @run.call
      end
    end

    # A write finished (or failed)
    class WriteMsg < Tea::Msg
      getter text : String
      getter error : String?
      # books as the hub has them now
      getter books : Array(JSON::Any)
      # optimistic changes to take back when it failed
      getter revert : Array(Book)
      getter undo : Undo?
      # the library and sidebar again (books left the view, counts changed)
      getter? reload : Bool

      def initialize(@text, @error = nil, @books = [] of JSON::Any, @revert = [] of Book, @undo = nil, @reload = false)
      end
    end

    # A bulk job: started, still running or done. `restore`: a delete, undone
    # by restoring these books from the trash; else `undoable` by the hub
    class JobMsg < Tea::Msg
      getter id : String
      getter label : String
      getter job : JSON::Any?
      getter error : String?
      getter? undoable : Bool
      getter restore : Array(Int64)?

      def initialize(@id, @label, @job = nil, @error = nil, @undoable = false, @restore = nil)
      end
    end

    # The book to edit, read fresh (for its lastModified)
    class EditBookMsg < Tea::Msg
      getter result : JSON::Any?
      getter error : String?

      def initialize(@result = nil, @error = nil)
      end
    end

    # The form was saved: the book, or the hub's version on a conflict
    class FormSavedMsg < Tea::Msg
      getter book : JSON::Any?
      getter conflict : JSON::Any?
      getter error : String?

      def initialize(@book = nil, @conflict = nil, @error = nil)
      end
    end

    # The books a command acts on: the selection (ids in the order they were
    # selected, or `all` matches of a query, `total` of them), else the open
    # or the cursor book. `book` when it is one loaded book.
    record Target, ids : Array(Int64), book : Book?, all : Query? = nil, total : Int32 = 0 do
      def one? : Bool
        all.nil? && ids.size == 1
      end

      def size : Int32
        all ? total : ids.size
      end

      # ": Titel" or " (3)"
      def suffix : String
        (b = book) ? ": #{b.title}" : " (#{size})"
      end

      # the bulk API's target: {ids} or {query, expect, all?}
      def bulk(category_column : String?) : JSON::Any
        if q = all
          return q.bulk_target(category_column, total)
        end
        JSON.parse({"ids" => ids}.to_json)
      end
    end

    # A restore from the trash, one book at a time: what is left, what came
    # back (new ids), what failed
    class RestoreMsg < Tea::Msg
      getter label : String
      getter left : Array(Int64)
      getter restored : Array(Int64)
      getter errors : Array({Int64, String})
      getter total : Int32
      getter? undoable : Bool

      def initialize(@label, @left, @restored, @errors, @total, @undoable)
      end
    end

    # The books of a finished job that failed, for :fehler
    record JobErrors, label : String, errors : Array({Int64, String})

    class App
      # what a Proc returning a command looks like (confirm, undo)
      alias Later = Proc(Tea::Cmd?)

      getter selection = [] of Int64
      getter form : EditForm? = nil
      getter? commanding = false
      getter? picking_fast_tag = false
      getter undo_stack = [] of Undo
      # the question asked and what yes does
      getter confirm : {String, Later}? = nil
      # where the command history is kept between runs (nil: not kept)
      property history_file : String? = nil
      # between two looks at a running bulk job
      property poll_interval : Time::Span = 700.milliseconds
      # where downloads go
      property download_dir : String = "."
      @command_line : CommandLine? = nil
      # the last change, for `.`: {action id or "fastTag"/"toggleList", value}
      getter last_change : {String, String}? = nil
      # the failed books of the last job with errors
      getter job_errors : JobErrors? = nil
      getter? showing_errors = false

      # --- target -----------------------------------------------------------

      def target : Target?
        if q = @all
          return nil unless @rows.loaded?
          return Target.new([] of Int64, nil, q, @rows.size)
        end
        ids = @visual ? visual_ids[0] : @selection
        unless ids.empty?
          book = ids.size == 1 ? loaded_book(ids[0]) : nil
          return Target.new(ids.dup, book)
        end
        book = @rows[@detail || @cursor] || return nil
        Target.new([book.id], @full[book.id]? || book)
      end

      private def loaded_book(id : Int64) : Book?
        @full[id]? || @rows.index_of(id).try { |i| @rows[i] }
      end

      # the target's books as far as they are loaded
      private def target_books(t : Target) : Array(Book)
        return @rows.loaded_books if t.all
        t.ids.compact_map { |i| loaded_book(i) }
      end

      # --- completion data --------------------------------------------------

      def choices : Choices
        c = Choices.new
        cats = @sidebar.categories
        names = ->(key : String) {
          cats.try(&.[key]?).try(&.as_a?).try(&.compact_map(&.["name"]?.try(&.as_s?))) || [] of String
        }
        c.tags = names.call("tags")
        c.series = names.call("series")
        c.authors = names.call("authors")
        c.languages = names.call("languages")
        c.kategorien = [] of String
        add_paths = uninitialized Proc(Array(JSON::Any), Nil)
        add_paths = ->(nodes : Array(JSON::Any)) {
          nodes.each do |n|
            n["path"]?.try(&.as_s?).try { |p| c.kategorien << Tui.category_label(p) }
            add_paths.call(n["children"]?.try(&.as_a?) || [] of JSON::Any)
          end
          nil
        }
        add_paths.call(cats.try(&.["kategorie"]?).try(&.as_a?) || [] of JSON::Any)
        c.lists = savable_lists.map { |l| list_label(l) }.sort_by(&.downcase)
        if (t = target) && (b = t.book) && t.one?
          c.book_tags = b.tags
          ids = b.lists
          c.book_lists = savable_lists.select { |l| ids.includes?(l["id"].as_i64) }.map { |l| list_label(l) }
          c.formats = b.formats.map(&.downcase)
        end
        c
      end

      # own lists that take books by hand: no magic shelves, not read-only
      private def savable_lists : Array(JSON::Any)
        (@sidebar.lists.try(&.as_a?) || [] of JSON::Any).select do |l|
          !l["id"]?.try(&.as_i64?).nil? && l["name"]?.try(&.as_s?) &&
            l["rule"]?.try(&.raw).nil? && l["editable"]?.try(&.as_bool?) != false
        end
      end

      private def list_label(l : JSON::Any) : String
        Cli::Runner.list_path(l["name"].as_s)
      end

      private def find_list(ref : String) : JSON::Any?
        path = Cli::Runner.list_path(ref).downcase
        lists = savable_lists
        ref.lchop('#').to_i64?.try { |id| lists.find { |l| l["id"].as_i64 == id } } ||
          lists.find { |l| list_label(l).downcase == path }
      end

      # --- the command line -------------------------------------------------

      def command_line : CommandLine
        @command_line ||= CommandLine.new(@history_file, Math.max(10, @width - 4))
      end

      def open_commands(text = "") : Tea::Cmd?
        @commanding = true
        @searching = false
        command_line.open(text)
      end

      private def command_key(msg : Tea::KeyMsg) : Tea::Cmd?
        result, cmd = command_line.key(msg, choices)
        case result
        when :submit
          @commanding = false
          return execute(command_line.value)
        when :cancel
          @commanding = false
        end
        cmd
      end

      # Runs one command line (without the ":")
      def execute(line : String) : Tea::Cmd?
        text = line.strip.lchop(':').strip
        return nil if text.empty?
        action, rest = Commands.parse(text) || return fail("Unbekannter Befehl: #{text.split(' ').first} (:help zeigt alle)")
        if @trash && !TRASH_COMMANDS.includes?(action)
          return fail("Im Papierkorb: r stellt wieder her, q geht zurück")
        end
        case action
        when "line"    then @trash ? trash_to(rest.to_i - 1) : move_to(rest.to_i - 1)
        when "quit"    then Tea.quit
        when "help"    then @help = true; nil
        when "undo"    then undo
        when "edit"    then edit_book
        when "open"    then @rows.size > 0 ? open_detail(@cursor) : nil
        when "select"  then select_command(rest)
        when "goTrash" then open_trash
        when "restore" then restore_selected
        when "errors"  then show_job_errors
        when "repeat"  then repeat
        when "search"
          close_trash
          rest.empty? ? start_search : navigate(@query.copy_with(q: rest))
        when "sort" then sort_command(rest)
        else
          run_action(action, rest)
        end
      end

      private def sort_command(rest : String) : Tea::Cmd?
        field, _, order = rest.strip.partition(/\s+/)
        return fail("sort: eins von #{@query.sorts.join(", ")}") unless @query.sorts.includes?(field)
        order = order.strip.downcase
        return fail("sort: asc oder desc") unless order.empty? || {"asc", "desc"}.includes?(order)
        requery(@query.copy_with(sort: field, order: order.presence || Query.default_order(field)))
      end

      private def fail(text : String) : Nil
        show_error(text)
        nil
      end

      # --- confirm ----------------------------------------------------------

      def ask(question : String, &yes : -> Tea::Cmd?) : Tea::Cmd?
        @confirm = {question, yes}
        nil
      end

      private def confirm_key(msg : Tea::KeyMsg) : Tea::Cmd?
        question, yes = @confirm.not_nil!
        @confirm = nil
        return yes.call if {"y", "j", "enter"}.includes?(msg.key)
        @message = "Abgebrochen"
        nil
      end

      # --- book actions -----------------------------------------------------

      # A command of the web app's actions on the target, with its value as typed
      def run_action(id : String, text : String) : Tea::Cmd?
        waiting, cmd = settle_visual { run_action(id, text) }
        return cmd if waiting
        action = Tui.book_action(id) || return fail("Unbekannter Befehl: #{id}")
        t = target || return fail(@all ? "Die Treffer laden noch" : "Kein Buch")
        if action.many && t.all
          return fail("#{action.label}: nur für ausgewählte Bücher, nicht für alle Treffer")
        end
        return fail("#{action.label}: nur für mehrere ausgewählte Bücher (Leertaste wählt aus)") if action.many && t.one?
        @last_change = {id, text} unless {"download", "newList"}.includes?(id)
        case id
        when "addToList", "removeFromList", "newList" then return list_action(action, t, text)
        when "download"                               then return download(t, text)
        when "delete"
          what = (b = t.book) ? "„#{b.title}“" : (t.all ? "Alle #{t.size} Treffer" : "#{t.size} Bücher")
          return ask("#{what} in den Papierkorb verschieben?") { delete(t) }
        end
        changes = begin
          Changes.for(action, text)
        rescue bad : Invalid
          return fail(bad.message || "")
        end
        label = "#{action.label}#{t.suffix}"
        if t.size > CONFIRM_ABOVE
          return ask("#{label}: #{t.size} Bücher ändern?") { change(t, changes, label) }
        end
        change(t, changes, label)
      end

      # `.`: the last change again, on what is the target now
      def repeat : Tea::Cmd?
        kind, value = @last_change || return fail("Nichts zu wiederholen")
        case kind
        when "fastTag"    then toggle_tag(value)
        when "toggleList" then toggle_default_list
        else                   run_action(kind, value)
        end
      end

      # One loaded book: PATCH at once, optimistically; several: a bulk job
      private def change(t : Target, changes : Hash(String, JSON::Any), label : String) : Tea::Cmd?
        if t.one? && (book = t.book)
          return patch(book, Changes.patch(changes, book), label)
        end
        bulk(t.bulk(@category_column), changes, label)
      end

      # Shows the change now, sends it, takes it back if the hub refuses
      def patch(book : Book, body : Hash(String, JSON::Any), label : String, undoable = true) : Tea::Cmd?
        store(Changes.apply(book, body, @category_column))
        back = Changes.undo(body, book, @category_column)
        source = @source
        app = self
        Tea.cmd do
          begin
            result = source.patch_book(book.id, body)
            undo = if undoable
                     u = back.dup
                     result["lastModified"]?.try { |lm| u["lastModified"] = lm }
                     Undo.new(label) { app.undo_patch(book.id, u, label) }
                   end
            WriteMsg.new(label, books: [result], undo: undo).as(Tea::Msg)
          rescue ex
            WriteMsg.new(label, error: App.error_text(ex), revert: [book]).as(Tea::Msg)
          end
        end
      end

      # the step back of a PATCH, on the book as it is now
      def undo_patch(id : Int64, body : Hash(String, JSON::Any), label : String) : Tea::Cmd?
        book = loaded_book(id) || return reload_with(id)
        patch(book, body, "Zurückgenommen: #{label}", undoable: false)
      end

      private def reload_with(id : Int64) : Tea::Cmd?
        fail("Buch ##{id} ist nicht mehr geladen")
      end

      # `restore`: the ids of a delete (its undo), nil for a field change
      private def bulk(target : JSON::Any, changes : Hash(String, JSON::Any), label : String,
                       restore : Array(Int64)? = nil) : Tea::Cmd?
        source = @source
        @message = "#{label} …"
        delete = changes.has_key?("delete")
        Tea.cmd do
          begin
            started = source.bulk(target, changes)
            JobMsg.new(started["jobId"].as_s, label, undoable: !delete, restore: restore).as(Tea::Msg)
          rescue ex : Cli::HttpError
            # all matches: the library changed since they were counted
            if ex.status == 409 && (found = ex.body["found"]?)
              WriteMsg.new(label, error: "die Suche trifft jetzt #{found} statt #{ex.body["expected"]?} Bücher, nichts geändert – Ansicht neu geladen",
                reload: true).as(Tea::Msg)
            else
              WriteMsg.new(label, error: App.error_text(ex)).as(Tea::Msg)
            end
          rescue ex
            WriteMsg.new(label, error: App.error_text(ex)).as(Tea::Msg)
          end
        end
      end

      # looks at a job until it is no longer running
      private def poll(msg : JobMsg, wait : Bool) : Tea::Cmd
        source = @source
        interval = @poll_interval
        Tea.cmd do
          sleep interval if wait
          begin
            JobMsg.new(msg.id, msg.label, source.job(msg.id), undoable: msg.undoable?, restore: msg.restore).as(Tea::Msg)
          rescue ex
            JobMsg.new(msg.id, msg.label, error: App.error_text(ex)).as(Tea::Msg)
          end
        end
      end

      private def job(msg : JobMsg) : Tea::Cmd?
        if err = msg.error
          return fail("#{msg.label}: #{err}")
        end
        job = msg.job || return poll(msg, wait: false)
        status = job["status"]?.try(&.as_s?) || "running"
        if {"running", "queued", "pending"}.includes?(status)
          @message = "#{msg.label}: #{Tui.progress(job["done"]?.try(&.as_i64?) || 0_i64, job["total"]?.try(&.as_i64?))}"
          return poll(msg, wait: true)
        end
        errors = job["errors"]?.try(&.as_a?) || [] of JSON::Any
        total = job["total"]?.try(&.as_i64?) || 0_i64
        text = "#{msg.label}: #{total - errors.size} von #{total} erledigt"
        unless errors.empty?
          failed = errors.map { |e| {e["bookId"]?.try(&.as_i64?) || 0_i64, e["error"]?.try(&.as_s?) || e.to_json} }
          @job_errors = JobErrors.new(msg.label, failed)
          text += ", #{errors.size} Fehler (:fehler zeigt sie): #{failed.first(2).map { |(id, e)| "##{id} #{e}" }.join("; ")}"
        end
        if status == "failed"
          show_error("#{text}#{job["error"]?.try { |e| " – #{e}" }}")
        elsif errors.empty?
          @message = text
        else
          show_error(text)
        end
        if (ids = msg.restore) && status != "failed"
          failed = errors.compact_map(&.["bookId"]?.try(&.as_i64?))
          back = ids - failed
          push_undo(Undo.new(msg.label) { restore(back, msg.label) }) unless back.empty?
          @selection -= back
        elsif msg.undoable? && status == "done"
          id = msg.id
          label = msg.label
          push_undo(Undo.new(label) { undo_job(id, label) })
        end
        refresh
      end

      def undo_job(id : String, label : String) : Tea::Cmd?
        source = @source
        back = "Zurückgenommen: #{label}"
        Tea.cmd do
          begin
            started = source.undo_job(id)
            JobMsg.new(started["jobId"].as_s, back).as(Tea::Msg)
          rescue ex : Cli::HttpError
            text = ex.status == 404 ? "dieser Hub kann Massenänderungen noch nicht zurücknehmen" : App.error_text(ex)
            WriteMsg.new(back, error: text).as(Tea::Msg)
          rescue ex
            WriteMsg.new(back, error: App.error_text(ex)).as(Tea::Msg)
          end
        end
      end

      private def delete(t : Target) : Tea::Cmd?
        label = "In den Papierkorb#{t.suffix}"
        if t.all
          # the ids aren't known here: no undo, the trash (gt) has them
          @all = nil
          return bulk(t.bulk(@category_column), {"delete" => JSON::Any.new(true)}, "#{label} (zurück über gt)")
        end
        return bulk(t.bulk(@category_column), {"delete" => JSON::Any.new(true)}, label, restore: t.ids) unless t.one?
        id = t.ids[0]
        source = @source
        app = self
        Tea.cmd do
          begin
            source.delete_book(id)
            WriteMsg.new(label, undo: Undo.new(label) { app.restore([id], label) }, reload: true).as(Tea::Msg)
          rescue ex
            WriteMsg.new(label, error: App.error_text(ex)).as(Tea::Msg)
          end
        end
      end

      # Books back from the trash, one request after the other with the
      # progress in the status line. `undoable`: u deletes them again (not
      # when this is the undo of a delete)
      def restore(ids : Array(Int64), label : String, undoable = false) : Tea::Cmd?
        return nil if ids.empty?
        restore_step(RestoreMsg.new(label, ids, [] of Int64, [] of {Int64, String}, ids.size, undoable))
      end

      private def restore_step(msg : RestoreMsg) : Tea::Cmd
        source = @source
        Tea.cmd do
          id = msg.left.first
          restored = msg.restored.dup
          errors = msg.errors.dup
          begin
            r = source.restore_book(id)
            r["book"]?.try(&.["id"]?).try(&.as_i64?).try { |n| restored << n }
          rescue ex
            errors << {id, App.error_text(ex)}
          end
          RestoreMsg.new(msg.label, msg.left[1..], restored, errors, msg.total, msg.undoable?).as(Tea::Msg)
        end
      end

      private def restored(msg : RestoreMsg) : Tea::Cmd?
        unless msg.left.empty?
          @message = "Wiederherstellen: #{Tui.progress((msg.total - msg.left.size).to_i64, msg.total.to_i64)}"
          return restore_step(msg)
        end
        n = msg.total - msg.errors.size
        text = msg.total == 1 && n == 1 ? "Wiederhergestellt: #{msg.label}" : "Wiederhergestellt: #{n} von #{msg.total}"
        if msg.errors.empty?
          @message = text
        else
          @job_errors = JobErrors.new("Wiederherstellen", msg.errors)
          show_error("#{text}, #{msg.errors.size} Fehler (:fehler zeigt sie): #{msg.errors.first(2).map { |(id, e)| "##{id} #{e}" }.join("; ")}")
        end
        if msg.undoable? && !msg.restored.empty?
          ids = msg.restored
          push_undo(Undo.new(text) { bulk(JSON.parse({"ids" => ids}.to_json), {"delete" => JSON::Any.new(true)}, "Zurückgenommen: #{text}") })
        end
        Tea.batch(refresh, @trash ? load_trash : nil)
      end

      # --- lists ------------------------------------------------------------

      private def list_action(action : BookAction, t : Target, text : String) : Tea::Cmd?
        name = text.strip
        return fail("#{action.label}: welche Liste?") if name.empty?
        if action.id == "newList"
          return create_list_with(Cli::Runner.list_path(name), t)
        end
        remove = action.id == "removeFromList"
        if l = find_list(name)
          return list_books(l["id"].as_i64, list_label(l), t, remove)
        end
        return fail("Liste #{name} nicht gefunden") if remove
        path = Cli::Runner.list_path(name)
        ask("Liste „#{path}“ gibt es nicht. Anlegen und #{t.one? ? "das Buch" : "#{t.size} Bücher"} hinzufügen?") do
          create_list_with(path, t)
        end
      end

      private def create_list_with(name : String, t : Target) : Tea::Cmd?
        source = @source
        column = @category_column
        Tea.cmd do
          begin
            l = source.create_list(name)
            id = l["id"].as_i64
            r = t.all ? source.list_target(id, t.bulk(column), false) : source.list_books(id, t.ids, false)
            WriteMsg.new("Neue Liste #{name} mit #{r["added"]?.try(&.as_a?.try(&.size)) || t.size} #{t.one? ? "Buch" : "Büchern"}",
              reload: true).as(Tea::Msg)
          rescue ex
            WriteMsg.new("Neue Liste #{name}", error: App.error_text(ex)).as(Tea::Msg)
          end
        end
      end

      def list_books(list : Int64, name : String, t : Target, remove : Bool, undoable = true) : Tea::Cmd?
        source = @source
        app = self
        column = @category_column
        Tea.cmd do
          begin
            r = t.all ? source.list_target(list, t.bulk(column), remove) : source.list_books(list, t.ids, remove)
            changed = (r[remove ? "removed" : "added"]?.try(&.as_a?) || [] of JSON::Any).compact_map(&.as_i64?)
            n = changed.size
            text = "#{n} #{n == 1 ? "Buch" : "Bücher"} #{remove ? "aus #{name} entfernt" : "zu #{name} hinzugefügt"}"
            text += " (#{t.size - n} #{remove ? "waren nicht drin" : "waren schon drin"})" if n < t.size
            undo = if undoable && n > 0
                     Undo.new(text) { app.list_books(list, name, Target.new(changed, nil), !remove, undoable: false) }
                   end
            WriteMsg.new(text, undo: undo, reload: n > 0).as(Tea::Msg)
          rescue ex
            WriteMsg.new(name, error: App.error_text(ex)).as(Tea::Msg)
          end
        end
      end

      # t: the default list ("Leseliste") on or off, as in the web app
      def toggle_default_list : Tea::Cmd?
        waiting, cmd = settle_visual { toggle_default_list }
        return cmd if waiting
        t = target || return fail("Kein Buch")
        l = savable_lists.find { |x| x["isDefault"]?.try(&.as_bool?) } ||
            return fail("Keine Standardliste (:list add NAME setzt eine beliebige)")
        @last_change = {"toggleList", ""}
        id = l["id"].as_i64
        books = target_books(t)
        # all matches not all loaded: added, like the web app
        on = books.size < t.size || !books.all?(&.lists.includes?(id))
        list_books(id, list_label(l), t, !on)
      end

      # --- fast tags --------------------------------------------------------

      def fast_tags : Array(String)
        @sidebar.fast_tags
      end

      private def start_fast_tag : Tea::Cmd?
        return fail("Keine Fast-Tags eingerichtet") if fast_tags.empty?
        return fail("Kein Buch") unless target
        @picking_fast_tag = true
        nil
      end

      private def fast_tag_key(msg : Tea::KeyMsg) : Tea::Cmd?
        @picking_fast_tag = false
        n = msg.key.to_i? || return nil
        tag = fast_tags[n - 1]? || return fail("Kein Fast-Tag #{n}")
        toggle_tag(tag)
      end

      # on for all when one lacks it, else off; optimistic for one book
      def toggle_tag(tag : String) : Tea::Cmd?
        waiting, cmd = settle_visual { toggle_tag(tag) }
        return cmd if waiting
        t = target || return fail("Kein Buch")
        @last_change = {"fastTag", tag}
        books = target_books(t)
        has = ->(b : Book) { b.tags.any? { |x| x.downcase == tag.downcase } }
        on = books.size < t.size || !books.all? { |b| has.call(b) }
        action = Tui.book_action(on ? "addTags" : "removeTags").not_nil!
        change(t, {action.id => JSON.parse([tag].to_json)}, "Tag #{tag} #{on ? "an" : "aus"}#{t.suffix}")
      end

      # --- download ---------------------------------------------------------

      private def download(t : Target, format : String) : Tea::Cmd?
        return fail("Herunterladen: nicht für alle Treffer, nur für ausgewählte Bücher") if t.all
        books = t.ids.compact_map { |i| loaded_book(i) }
        return fail("Bücher noch nicht geladen") if books.empty?
        wanted = format.strip.downcase.presence
        dir = @download_dir
        source = @source
        Tea.cmd do
          saved = [] of String
          errors = [] of String
          books.each do |b|
            formats = b.formats.map(&.downcase)
            f = wanted || (formats.includes?("epub") ? "epub" : formats.first?)
            unless f && formats.includes?(f)
              errors << "#{b.title}: kein #{(f || "Format").upcase}"
              next
            end
            path = File.join(dir, Cli::Runner.file_name(b.json, f))
            begin
              bytes = source.download(b.id, f, path)
              saved << "#{path} (#{Cli::Output.size(bytes)})"
            rescue ex
              errors << "#{b.title}: #{App.error_text(ex)}"
            end
          end
          text = saved.size == 1 ? "Gespeichert: #{saved[0]}" : "#{saved.size} Dateien gespeichert in #{dir}"
          WriteMsg.new(text, error: errors.empty? ? nil : errors.first(3).join("; ")).as(Tea::Msg)
        end
      end

      # --- undo -------------------------------------------------------------

      private def push_undo(u : Undo) : Nil
        @undo_stack << u
        @undo_stack.shift if @undo_stack.size > 20
      end

      def undo : Tea::Cmd?
        u = @undo_stack.pop? || return fail("Nichts zurückzunehmen")
        @message = "Nehme zurück: #{u.label} …"
        u.run
      end

      # --- results ----------------------------------------------------------

      private def written(msg : WriteMsg) : Tea::Cmd?
        msg.revert.each { |b| store(b) }
        if err = msg.error
          fail("#{msg.text}: #{err}")
          return msg.reload? ? refresh : nil
        end
        msg.books.each { |j| store(Book.new(j), full: true) }
        @message = msg.text
        msg.undo.try { |u| push_undo(u) }
        msg.reload? ? refresh : nil
      end

      # a changed book in the rows and the detail; lists stay as they were
      # when the answer has none
      private def store(book : Book, full = false) : Nil
        old = loaded_book(book.id)
        if old && !book.json["lists"]? && (l = old.json["lists"]?)
          book = book.merge({"lists" => l})
        end
        @rows.replace(book)
        if full || @full.has_key?(book.id)
          if !full && (o = @full[book.id]?)
            book = book.merge({"comments" => o.json["comments"]? || JSON::Any.new(nil)}) unless book.json["comments"]?
          end
          @full[book.id] = book
        end
        @detail_for = nil
      end

      # the library as the hub has it now, the cursor where it was
      def refresh : Tea::Cmd?
        @rows.reset
        @full.clear
        @detail_for = nil
        Tea.batch(load_visible, load_meta)
      end

      def self.error_text(ex : Exception) : String
        ex.message.presence || ex.class.name
      end

      # --- the edit form ----------------------------------------------------

      def edit_book : Tea::Cmd?
        book = @rows[@detail || @cursor] || return fail("Kein Buch")
        id = book.id
        source = @source
        @message = "Lädt …"
        Tea.cmd do
          begin
            EditBookMsg.new(source.book(id)).as(Tea::Msg)
          rescue ex
            EditBookMsg.new(error: App.error_text(ex)).as(Tea::Msg)
          end
        end
      end

      private def open_form(msg : EditBookMsg) : Tea::Cmd?
        json = msg.result || return fail("Bearbeiten: #{msg.error}")
        @message = nil
        @confirm = nil
        f = EditForm.new(Book.new(json), @category_column, @width, body_height)
        @form = f
        f.start
      end

      private def form_key(msg : Tea::KeyMsg) : Tea::Cmd?
        f = @form.not_nil!
        key = msg.key == "ctrl+c" ? Tea::KeyMsg.new("esc") : msg
        result, cmd = f.key(key, choices)
        case result
        when :save   then return save_form(f)
        when :mine   then f.keep_mine; @message = "Deine Änderungen liegen auf der neuen Fassung – Strg+S speichert"
        when :theirs then f.take_theirs; @message = "Neue Fassung übernommen"
        when :cancel
          return ask("Änderungen verwerfen?") { close_form } if f.dirty?
          return close_form
        end
        cmd
      end

      private def close_form : Tea::Cmd?
        @form = nil
        @detail_for = nil
        nil
      end

      private def save_form(f : EditForm) : Tea::Cmd?
        body = begin
          f.patch
        rescue bad : Invalid
          f.error = bad.message
          return nil
        end
        unless body
          @message = "Nichts geändert"
          return close_form
        end
        f.saving = true
        source = @source
        id = f.base.id
        Tea.cmd do
          begin
            FormSavedMsg.new(source.patch_book(id, body)).as(Tea::Msg)
          rescue ex : Cli::HttpError
            if ex.status == 409 && (current = ex.body["book"]?)
              FormSavedMsg.new(conflict: current).as(Tea::Msg)
            else
              FormSavedMsg.new(error: App.error_text(ex)).as(Tea::Msg)
            end
          rescue ex
            FormSavedMsg.new(error: App.error_text(ex)).as(Tea::Msg)
          end
        end
      end

      private def form_saved(msg : FormSavedMsg) : Tea::Cmd?
        f = @form || return nil
        f.saving = false
        if c = msg.conflict
          f.conflict = Book.new(c)
          return nil
        end
        if err = msg.error
          f.error = "Nicht gespeichert: #{err}"
          return nil
        end
        book = Book.new(msg.book.not_nil!)
        body = (f.patch rescue nil) || {} of String => JSON::Any
        back = Changes.undo(body, f.base, @category_column)
        book.last_modified.try { |lm| back["lastModified"] = JSON::Any.new(lm) }
        label = "Bearbeitet: #{book.title}"
        id = book.id
        push_undo(Undo.new(label) { undo_patch(id, back, label) }) unless back.empty?
        store(book, full: true)
        @message = "Gespeichert: #{book.title}"
        close_form
      end

      # --- keys of the write modes, before the normal ones ------------------

      # nil when no write mode has the key
      private def write_key(msg : Tea::KeyMsg) : {Bool, Tea::Cmd?}
        return {true, confirm_key(msg)} if @confirm
        return {true, form_key(msg)} if @form
        return {true, command_key(msg)} if @commanding
        return {true, fast_tag_key(msg)} if @picking_fast_tag
        {false, nil}
      end

      private def write_act(action : Action) : {Bool, Tea::Cmd?}
        case action
        when .commands?      then {true, open_commands}
        when .undo?          then {true, undo}
        when .edit?          then {true, edit_book}
        when .toggle_select? then {true, toggle_select}
        when .repeat?        then {true, repeat}
        when .toggle_list?   then {true, toggle_default_list}
        when .fast_tag?      then {true, start_fast_tag}
        when .delete?        then {true, run_action("delete", "")}
        when .download?      then {true, run_action("download", "")}
        else                      {false, nil}
        end
      end

      private def write_msg(msg : Tea::Msg) : {Bool, Tea::Cmd?}
        case msg
        when WriteMsg     then {true, written(msg)}
        when JobMsg       then {true, job(msg)}
        when RestoreMsg   then {true, restored(msg)}
        when TrashMsg     then {true, trash_loaded(msg)}
        when EditBookMsg  then {true, open_form(msg)}
        when FormSavedMsg then {true, form_saved(msg)}
        else                   {false, nil}
        end
      end

      # the status line of the write modes, nil otherwise
      private def write_status : String?
        if c = @confirm
          return Theme.error.render(Text.truncate("#{c[0]} [j/N]", @width))
        end
        return command_line.view if @commanding
        if @picking_fast_tag
          tags = fast_tags.first(9).map_with_index { |t, i| "#{i + 1} #{t}" }.join(" · ")
          return Theme.accent.render(Text.truncate("Fast-Tag umschalten: #{tags} (Esc: nichts)", @width))
        end
        if f = @form
          return Theme.muted.render(Text.truncate("speichert …", @width)) if f.saving?
          return nil if @message
          hint = f.conflict ? "m meine behalten · t neue übernehmen · Esc abbrechen" : "Tab ergänzen/weiter · ↑/↓ Feld · Strg+S speichern · Esc abbrechen"
          return Theme.muted.render(Text.truncate(hint, @width))
        end
        nil
      end
    end
  end
end
