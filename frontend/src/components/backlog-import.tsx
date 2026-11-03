import { useQuery } from "@tanstack/react-query"
import { Link } from "@tanstack/react-router"
import { ArrowRight } from "lucide-react"
import { importStatusQuery } from "@/lib/queries"
import type { ImportBacklog, ImportFollowup, ImportRun, ImportStatus } from "@/lib/api"
import { activeRuns, followupQueues, formatDuration, hookLabel, live, percent, runProgress } from "@/lib/import"
import { formatNumber, locale, t } from "@/i18n"
import { cn } from "@/lib/utils"

const dateTime = (iso: string) => new Date(iso).toLocaleString(locale, { dateStyle: "medium", timeStyle: "short" })
const n = (v: number | undefined | null) => formatNumber(v ?? 0)
const muted = "text-muted-foreground eink:text-black"
const tapLink = "underline-offset-2 hover:underline eink:inline-flex eink:min-h-11 eink:items-center touch:inline-flex touch:min-h-11 touch:items-center"

// Backlog import on the Metadaten page: where it is and the whole
// backlog's progress, with a link to the import page
export function BacklogImport() {
  const { data } = useQuery(importStatusQuery)
  if (!data || (!data.enabled && data.cleanups.length === 0)) return null
  const runs = data.enabled ? activeRuns(data) : []
  return (
    <section className="space-y-2" aria-labelledby="backlog-import">
      <h2 id="backlog-import" className="text-lg font-semibold">
        {t("import.title")}
      </h2>
      {data.enabled && <p className={cn("text-sm", muted)}>{t("import.hint", { roots: (data.roots ?? []).join(", ") })}</p>}
      {data.enabled && <PhaseLine status={data} />}
      {runs.map((run) => (
        <p key={run.id} role="status" className="text-sm tabular-nums">
          {runState(run)}
        </p>
      ))}
      {data.backlog && <BacklogBar backlog={data.backlog} />}
      <Link to="/import" className={cn(tapLink, "inline-flex items-center gap-1 text-sm font-medium")}>
        {t("import.details")} <ArrowRight className="size-4" aria-hidden />
      </Link>
    </section>
  )
}

// The import page's body: phase, the whole backlog, the live runs with
// rates and ETA, the followup, and every run with its result
export function ImportOverview({ status }: { status: ImportStatus }) {
  const runs = activeRuns(status)
  return (
    <div className="space-y-6">
      <PhaseLine status={status} />
      {status.hooksPaused && (
        <p role="status" className="text-sm">
          {t("import.paused")}
        </p>
      )}
      <section className="space-y-2" aria-labelledby="import-backlog">
        <h2 id="import-backlog" className="text-lg font-semibold">
          {t("import.backlog")}
        </h2>
        {status.backlog ? <BacklogDetails backlog={status.backlog} /> : <p className={cn("text-sm", muted)}>{t("import.backlog.none")}</p>}
      </section>
      {runs.map((run) => (
        <ActiveRun key={run.id} run={run} />
      ))}
      {status.followup && <Followup followup={status.followup} />}
      <section className="space-y-2" aria-labelledby="import-runs">
        <h2 id="import-runs" className="text-lg font-semibold">
          {t("import.runs")}
        </h2>
        <ul className="divide-y border-y eink:divide-y-2 eink:border-y-2">
          {(status.runs ?? []).map((run) => (
            <RunItem key={run.id} run={run} />
          ))}
          {status.cleanups.map((c) => (
            <li key={c.id} className="py-2 text-sm">
              {t("import.cleanup", { id: c.id, count: n(c.total) })} · {dateTime(c.createdAt)}
              {c.job && ` · ${c.job.status === "running" ? t("import.progress", { done: n(c.job.done), total: n(c.job.total) }) : c.job.status === "done" ? t("import.status.done") : t("import.status.failed")}`}
              {c.undoJob && ` · ${t("import.undone")}`}
            </li>
          ))}
        </ul>
      </section>
    </div>
  )
}

function PhaseLine({ status }: { status: ImportStatus }) {
  const phase = status.phase ? t(`import.phase.${status.phase}`) : t("import.phase.idle")
  return <p className="text-sm font-medium">{t("import.phase", { phase })}</p>
}

function Bar({ label, done, total }: { label: string; done: number; total: number }) {
  const pct = percent(done, total)
  return (
    <div
      role="progressbar"
      aria-label={label}
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={pct}
      aria-valuetext={`${pct} %`}
      className="h-3 overflow-hidden rounded-full bg-muted eink:h-4 eink:rounded-none eink:border-2 eink:border-black eink:bg-white"
    >
      <div className="h-full bg-primary eink:bg-black" style={{ width: `${pct}%` }} />
    </div>
  )
}

function BacklogBar({ backlog: b }: { backlog: ImportBacklog }) {
  if (!b.basis && b.total === 0) return null
  return (
    <div className="space-y-1">
      <Bar label={t("import.backlog.bar")} done={b.imported} total={b.total} />
      <p className="text-sm tabular-nums">{t("import.backlog.done", { imported: n(b.imported), total: n(b.total), percent: percent(b.imported, b.total) })}</p>
    </div>
  )
}

function BacklogDetails({ backlog: b }: { backlog: ImportBacklog }) {
  return (
    <div className="space-y-1 text-sm tabular-nums">
      <BacklogBar backlog={b} />
      <p>{t("import.backlog.open", { books: n(b.open.books), formats: n(b.open.formats), duplicates: n(b.open.duplicates), failed: n(b.open.failed) })}</p>
      <p>{t("import.backlog.handled", { formats: n(b.formatAdded), duplicates: n(b.duplicates) })}</p>
      {b.etaSeconds != null && <p>{t("import.backlog.eta", { eta: formatDuration(b.etaSeconds) })}</p>}
      {b.basis && (
        <p className={cn("break-all", muted)}>{t("import.backlog.basis", { date: dateTime(b.basis.createdAt), paths: b.basis.paths.join(", ") })}</p>
      )}
      {!b.basis && <p className={muted}>{t("import.backlog.none")}</p>}
    </div>
  )
}

// elapsed time, rate and ETA of a run
function timing(run: ImportRun): string[] {
  const parts: string[] = []
  if (run.elapsedSeconds != null) parts.push(t(live(run) ? "import.run.elapsed" : "import.run.took", { elapsed: formatDuration(run.elapsedSeconds) }))
  if (run.filesPerSecond != null) parts.push(t("import.run.filesRate", { rate: formatNumber(run.filesPerSecond) }))
  if (run.booksPerMinute != null) parts.push(t("import.run.booksRate", { rate: formatNumber(run.booksPerMinute) }))
  if (run.etaSeconds != null && live(run)) parts.push(t("import.run.eta", { eta: formatDuration(run.etaSeconds) }))
  return parts
}

function ActiveRun({ run }: { run: ImportRun }) {
  const progress = runProgress(run)
  const phase = run.phase === "scan" || run.phase === "check" || run.phase === "import" ? t(`import.phase.${run.phase}`) : run.status
  const id = `import-run-${run.id}`
  const times = timing(run)
  return (
    <section className="space-y-2 rounded-md border p-3 eink:rounded-none eink:border-2 eink:border-black" aria-labelledby={id}>
      <h2 id={id} className="text-lg font-semibold">
        {run.dryRun ? `${t("import.dryRun")}: ${phase}` : phase}
      </h2>
      <p className="font-medium break-all text-sm">{(run.paths ?? [run.path]).join(", ")}</p>
      {progress && <Bar label={t("import.run.bar")} done={progress.done} total={progress.total} />}
      <p role="status" className="text-sm tabular-nums">
        {runState(run)}
      </p>
      {run.current && <p className="text-sm break-all">{t("import.run.at", { path: run.current })}</p>}
      {times.length > 0 && <p className="text-sm tabular-nums">{times.join(" · ")}</p>}
      {!run.dryRun && run.summary && <Results run={run} />}
      <Failures run={run} />
    </section>
  )
}

function Results({ run }: { run: ImportRun }) {
  const r = run.results
  const s = run.summary
  return (
    <p className="text-sm tabular-nums">
      <span className="font-medium">{t("import.run.result")}: </span>
      {t("import.run.results", {
        imported: n(r.imported),
        formats: n(r.formatAdded),
        duplicates: n(r.duplicate),
        failed: n(r.failed),
        pending: n(r.pending),
        deferred: n(r.deferred),
        skipped: n((s?.skipped.total ?? 0) + (s?.alreadyImported ?? 0)),
      })}
    </p>
  )
}

function Failures({ run }: { run: ImportRun }) {
  const list = run.failures ?? []
  if (!list.length) return null
  const more = (run.results.failed ?? list.length) - list.length
  return (
    <div className="space-y-1 text-sm">
      <h3 className="font-medium">{t("import.run.failures")}</h3>
      <ul className="space-y-1">
        {list.map((f) => (
          <li key={f.path} className="break-all">
            {f.path}
            {f.detail && <span className="text-destructive eink:text-black">: {f.detail}</span>}
          </li>
        ))}
      </ul>
      {more > 0 && <p className={muted}>{t("import.run.moreFailures", { count: n(more) })}</p>}
    </div>
  )
}

function Followup({ followup: f }: { followup: ImportFollowup }) {
  const queues = followupQueues(f.queues)
  return (
    <section className="space-y-1" aria-labelledby="import-followup">
      <h2 id="import-followup" className="text-lg font-semibold">
        {t("import.followup")}
      </h2>
      {queues.length === 0 || f.total === 0 ? (
        <p className="text-sm">{t("import.followup.empty")}</p>
      ) : (
        <p className="text-sm tabular-nums">{t("import.followup.queues", { queues: queues.map(([k, v]) => `${hookLabel(k)} ${n(v)}`).join(", ") })}</p>
      )}
      {f.paused && f.total > 0 && <p className={cn("text-sm", muted)}>{t("import.followup.paused")}</p>}
    </section>
  )
}

// the scan first (files and books found, then the duplicate check), then
// the dry run's plan or the import's progress
function runState(run: ImportRun) {
  if (run.status === "scanning") {
    const scan = run.scan ?? { files: 0, units: 0, planned: 0 }
    return scan.planned > 0 || run.phase === "check"
      ? t("import.checking", { done: n(scan.planned), total: n(scan.units) })
      : t("import.scanning", { files: n(scan.files), books: n(scan.units) })
  }
  const finished = t(run.status === "done" ? "import.status.done" : run.status === "failed" ? "import.status.failed" : "import.status.gone")
  if (run.dryRun) return run.status === "planned" ? t("import.dryRun") : `${t("import.dryRun")}: ${finished}`
  return run.status === "running" ? t("import.progress", { done: n(run.done), total: n(run.total) }) : finished
}

function RunItem({ run }: { run: ImportRun }) {
  const times = live(run) ? [] : timing(run)
  return (
    <li className="space-y-0.5 py-2 text-sm">
      <div className="flex flex-wrap gap-x-2">
        <span className="font-medium break-all">{(run.paths ?? [run.path]).join(", ")}</span>
        <span className={muted}>{dateTime(run.createdAt)}</span>
        <span className="tabular-nums">{runState(run)}</span>
        {times.length > 0 && <span className="tabular-nums">{times.join(" · ")}</span>}
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
      <a className={tapLink} href={`/api/import/runs/${run.id}/report`} target="_blank" rel="noreferrer">
        {t("import.report")}
      </a>
    </>
  )
}
