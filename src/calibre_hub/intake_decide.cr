require "./intake"

module CalibreHub
  # The Eingang's trash: one folder for everything thrown away, with a folder
  # per source below it (inbox/, upload/, backlog/ for what is left of those
  # days) and the path below the source under that, so a file can be brought
  # back. It doesn't show on the hub's Papierkorb page and nothing here deletes
  # what it wasn't sure to have: Arthur empties it by hand. One rename per file
  # where that works, so a move is whole or didn't happen. Between two file
  # systems, or two mounts of ReadWritePaths, the file is copied, compared byte
  # for byte and only then removed at its source; a copy that fails leaves the
  # source as it was, and the entry says why.
  class IntakeTrash
    getter dir : String
    # a file system's part of a move; a spec has them fail
    property rename : Proc(String, String, Nil) = ->(from : String, to : String) { File.rename(from, to) }
    property copy : Proc(String, String, Nil) = ->(from : String, to : String) { IntakeTrash.copy_file(from, to) }

    def initialize(dir : String)
      @dir = File.expand_path(dir)
    end

    # what stands against throwing anything away, for the log at the start:
    # a decision that runs into it says so itself
    def problem : String?
      Dir.mkdir_p(@dir)
      File::Info.writable?(@dir) ? nil : "#{@dir} is not writable for the hub"
    rescue ex : File::Error
      ex.message
    end

    # Moves files or folders of a source to the trash folder, under their path
    # below root, which a source no longer there hasn't got. Returns where
    # they went.
    def move(origin : String, root : String?, paths : Array(String)) : Array(String)
      paths.map do |path|
        target = IntakeTrash.free(target(origin, root, path))
        Dir.mkdir_p(File.dirname(target))
        place(path, target)
        target
      end
    end

    # where a path of a source belongs in the trash folder
    def target(origin : String, root : String?, path : String) : String
      return File.join(@dir, origin, path.lchop('/')) unless root
      below = root.rstrip('/') + "/"
      raise File::Error.new("not below #{root}", file: path) unless path.starts_with?(below)
      File.join(@dir, origin, path.lchop(below))
    end

    private def place(path : String, target : String)
      @rename.call(path, target)
    rescue ex : File::Error
      raise ex unless ex.os_error == Errno::EXDEV
      carry(path, target)
    end

    # by way of a name nobody takes for a book
    private def carry(path : String, target : String)
      part = "#{target}.part"
      begin
        copy_all(path, part)
        File.rename(part, target)
      rescue ex : File::Error | IO::Error
        # half a copy of the hub's own, the source is untouched
        remove_all(part) if File.info?(part, follow_symlinks: false)
        raise File::Error.new("not moved to the trash, it stays where it is: #{ex.message}", file: path)
      end
      begin
        remove_all(path)
      rescue ex : File::Error
        # the file is whole where it was: not in two places. Of a folder some
        # may be gone, the copy stays.
        File.delete?(target) unless File.directory?(target)
        raise File::Error.new("not moved to the trash, can't remove it from where it is: #{ex.message}", file: path)
      end
    end

    private def copy_all(path : String, to : String)
      info = File.info(path, follow_symlinks: false)
      if info.directory?
        Dir.mkdir(to)
        Dir.each_child(path) { |name| copy_all(File.join(path, name), File.join(to, name)) }
      elsif info.symlink?
        File.symlink(File.readlink(path), to)
      else
        @copy.call(path, to)
        raise IO::Error.new("the copy of #{path} isn't the same") unless BookFiles.same_content?(path, to)
      end
    end

    private def remove_all(path : String)
      info = File.info(path, follow_symlinks: false)
      if info.directory?
        Dir.each_child(path) { |name| remove_all(File.join(path, name)) }
        Dir.delete(path)
      else
        File.delete(path)
      end
    end

    # on disk before the source goes, with the source's time
    def self.copy_file(from : String, to : String)
      info = File.info(from)
      File.open(from) do |source|
        File.open(to, "w", info.permissions) do |copy|
          IO.copy(source, copy)
          copy.fsync
        end
      end
      File.utime(info.modification_time, info.modification_time, to)
    end

    # A file of that name stays what it is: the next free one, „a (2).pdf“
    def self.free(target : String) : String
      return target unless File.info?(target, follow_symlinks: false)
      ext = File.directory?(target) ? "" : File.extname(target)
      stem = target.rchop(ext)
      (2..).each do |n|
        name = "#{stem} (#{n})#{ext}"
        return name unless File.info?(name, follow_symlinks: false)
      end
      target
    end
  end

  # Decisions as jobs, one entry after the other, in a queue of their own: a
  # bulk of a thousand doesn't wait in a request, the entries leave the list
  # when it is queued. Accepting goes through the import (Importer#import
  # with what was chosen), so a book gets what any imported book gets and
  # a backlog file is in import_files, an inbox file or an upload moves to
  # _imported; a trashed file goes to the trash folder (IntakeTrash). An entry
  # whose decision fails is back in the list and says why.
  class IntakeJobs < Jobs
    def initialize(db : DB::Database, calibre : Calibre, writer : Writer, @imports : Importer, @intake : Intake)
      super(db, calibre, writer, nil, "intake_jobs")
    end

    def queue(ids : Array(Int64), changes : Hash(String, JSON::Any)) : Job
      job = enqueue(ids, changes)
      @intake.waiting(ids, job.id)
      job
    end

    protected def apply(job : Job, index : Int32, id : Int64, resumed : Bool)
      # handled just before the hub stopped, or gone by itself
      e = @intake[id]? || return
      unless @intake.unchanged?(e)
        @intake.finish(e)
        return
      end
      begin
        if job.changes["decision"] == "trash"
          @intake.trash(e)
        else
          take(e, job)
        end
      rescue ex : Jobs::Abort
        @intake.release(job.id, ex.message)
        raise ex
      rescue ex
        @intake.failed(e, ex.message || ex.class.name)
        raise ex
      end
    end

    private def take(e : Intake::Entry, job : Job)
      unit = e.unit
      ix = @imports.index_for("#{Intake::RUN}-#{job.id}")
      if book = job.changes["book"]?.try(&.as_i64?)
        @imports.add_to(unit, ix, book)
      else
        @imports.import(unit, ix, @intake.chosen(e, job.changes))
      end
      if unit.status == "duplicate"
        @intake.duplicate(e, unit, ix)
      else
        @intake.taken(e, unit)
      end
    end
  end
end
