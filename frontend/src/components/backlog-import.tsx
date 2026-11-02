import { useQuery } from "@tanstack/react-query"
import { importStatusQuery } from "@/lib/queries"
import type { ImportRun } from "@/lib/api"
import { formatNumber, locale, t } from "@/i18n"

const dateTime = (iso: string) => new Date(iso).toLocaleString(locale, { dateStyle: "medium", timeStyle: "short" })
const n = (v: number | undefined | null) => formatNumber(v ?? 0)

// Backlog import (hub import): the last runs with their summary and
// progress, and the inbox cleanups; started from the CLI or the API
export function BacklogImport() {
  const { data } = useQuery(importStatusQuery)
  if (!data || (!data.enabled && data.cleanups.length === 0)) return null
  return (
    <section className="space-y-2" aria-labelledby="backlog-import">
      <h2 id="backlog-import" className="text-lg font-semibold">
        {t("import.title")}
      </h2>
      {data.enabled && <p className="text-sm text-muted-foreground eink:text-black">{t("import.hint", { roots: (data.roots ?? []).join(", ") })}</p>}
      {data.hooksPaused && (
        <p role="status" className="text-sm">
          {t("import.paused")}
        </p>
      )}
      <ul className="space-y-2">
        {(data.runs ?? []).map((run) => (
          <RunItem key={run.id} run={run} />
        ))}
        {data.cleanups.map((c) => (
          <li key={c.id} className="text-sm">
            {t("import.cleanup", { id: c.id, count: n(c.total) })} · {dateTime(c.createdAt)}
            {c.job && ` · ${c.job.status === "running" ? t("import.progress", { done: n(c.job.done), total: n(c.job.total) }) : c.job.status === "done" ? t("import.status.done") : t("import.status.failed")}`}
            {c.undoJob && ` · ${t("import.undone")}`}
          </li>
        ))}
      </ul>
    </section>
  )
}

// the scan first (files and books found, then the duplicate check), then
// the dry run's plan or the import's progress
function runState(run: ImportRun) {
  if (run.status === "scanning") {
    const scan = run.scan ?? { files: 0, units: 0, planned: 0 }
    return scan.planned > 0
      ? t("import.checking", { done: n(scan.planned), total: n(scan.units) })
      : t("import.scanning", { files: n(scan.files), books: n(scan.units) })
  }
  const finished = t(run.status === "done" ? "import.status.done" : run.status === "failed" ? "import.status.failed" : "import.status.gone")
  if (run.dryRun) return run.status === "planned" ? t("import.dryRun") : `${t("import.dryRun")}: ${finished}`
  return run.status === "running" ? t("import.progress", { done: n(run.done), total: n(run.total) }) : finished
}

function RunItem({ run }: { run: ImportRun }) {
  const scanning = run.status === "scanning"
  return (
    <li className="space-y-0.5 text-sm">
      <div className="flex flex-wrap gap-x-2">
        <span className="font-medium break-all">{(run.paths ?? [run.path]).join(", ")}</span>
        <span className="text-muted-foreground eink:text-black">{dateTime(run.createdAt)}</span>
        <span role={scanning ? "status" : undefined} className="tabular-nums">
          {runState(run)}
        </span>
        {run.error && <span className="text-destructive">{run.error}</span>}
      </div>
      {run.summary && <Summary run={run} summary={run.summary} />}
    </li>
  )
}

function Summary({ run, summary: s }: { run: ImportRun; summary: NonNullable<ImportRun["summary"]> }) {
  const r = run.results
  return (
    <>
      <p className="tabular-nums">
        {t("import.found", {
          books: n(s.books),
          calibre: n(s.calibreFolders),
          add: n(s.toAdd),
          formats: n(s.toAddFormats),
          duplicates: n(s.duplicates.total),
          already: n(s.alreadyImported),
          skipped: n(s.skipped.total),
        })}
      </p>
      {run.limit != null && s.selected && (
        <p className="tabular-nums">{t("import.limit", { books: n(s.selected.books), limit: n(run.limit), deferred: n(s.deferred) })}</p>
      )}
      {!run.dryRun && (
        <p className="tabular-nums">
          {t("import.results", { imported: n(r.imported), formats: n(r.formatAdded), duplicates: n(r.duplicate), failed: n(r.failed) })}
        </p>
      )}
      <a className="underline-offset-2 hover:underline eink:inline-flex eink:min-h-11 eink:items-center touch:inline-flex touch:min-h-11 touch:items-center" href={`/api/import/runs/${run.id}/report`} target="_blank" rel="noreferrer">
        {t("import.report")}
      </a>
    </>
  )
}
