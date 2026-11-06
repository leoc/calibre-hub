require "./intake"

module CalibreHub
  # The Eingang's trash: a folder next to the root, <root>-papierkorb, that
  # the hub only ever moves files into. It doesn't show on the hub's
  # Papierkorb page and nothing here deletes: Arthur empties it by hand. One
  # rename per file, so a move is whole or didn't happen; a rename between
  # two file systems fails and the entry stays in the list.
  module IntakeTrash
    SUFFIX = "-papierkorb"

    # Moves files or folders below a root to the trash folder, under their
    # path in the root. Returns where they went.
    def self.move(roots : Array(String), paths : Array(String)) : Array(String)
      paths.map do |path|
        target = free(target(roots, path))
        Dir.mkdir_p(File.dirname(target))
        File.rename(path, target)
        target
      end
    end

    # where a path of a root belongs in that root's trash folder
    def self.target(roots : Array(String), path : String) : String
      root = roots.select { |r| path.starts_with?(r.rstrip('/') + "/") }.max_by?(&.size)
      raise File::Error.new("not below an import root", file: path) unless root
      root = root.rstrip('/')
      root + SUFFIX + path.lchop(root)
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
  # when it is queued. Accepting goes through the import (ImportJobs#import
  # with what was chosen), so a book gets what any imported book gets and
  # the file is in import_files; a trashed file moves (IntakeTrash). An entry
  # whose decision fails is back in the list and says why.
  class IntakeJobs < Jobs
    def initialize(db : DB::Database, calibre : Calibre, writer : Writer, @imports : ImportJobs, @intake : Intake)
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
      @imports.import(unit, ix, @intake.chosen(e, job.changes))
      if unit.status == "duplicate"
        @intake.duplicate(e, unit, ix)
      else
        @imports.handled(unit, Intake::RUN)
        @intake.finish(e)
      end
    end
  end
end
