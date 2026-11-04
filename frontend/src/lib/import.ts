import type { ImportRun, ImportStatus } from "./api"
import { t } from "@/i18n"

const pad = (n: number) => String(n).padStart(2, "0")

// 3725 -> "1 Std. 02 Min.", 250 -> "4 Min. 10 s", 12 -> "12 s"
export function formatDuration(seconds: number): string {
  const total = Math.max(0, Math.round(seconds))
  const h = Math.floor(total / 3600)
  const m = Math.floor((total % 3600) / 60)
  const s = total % 60
  if (h > 0) return t("import.duration.h", { h, m: pad(m) })
  if (m > 0) return t("import.duration.m", { m, s: pad(s) })
  return t("import.duration.s", { s })
}

// whole percent, never 100 before it is done and never 0 once something is
export function percent(done: number, total: number): number {
  if (total <= 0) return 0
  const p = Math.round((done / total) * 100)
  if (done > 0 && p === 0) return 1
  if (done < total && p === 100) return 99
  return p
}

export const live = (run: ImportRun) => run.status === "scanning" || run.status === "running"

// the runs going on: the import's first, then a dry run's scan
export function activeRuns(status: ImportStatus): ImportRun[] {
  return (status.runs ?? []).filter(live).sort((a, b) => Number(a.dryRun) - Number(b.dryRun))
}

// the size of a portion, as `hub import --limit` takes it
export const PORTION = 500
const MAX_LIMIT = 2_147_483_647

// a whole number from 1 up, else null
export function portionLimit(text: string): number | null {
  const n = Number(text)
  return Number.isInteger(n) && n >= 1 && n <= MAX_LIMIT ? n : null
}

// The dry run a portion goes by: the newest run, nothing ran since. Of the
// first root, or the one asked for here (checked; the hub answers with the
// folder's real path, a root may be a link). Without a limit it's no portion.
export function portionRun(status: ImportStatus, checked: string | null): ImportRun | null {
  const run = status.runs?.[0]
  if (!run?.dryRun || run.limit == null) return null
  return run.id === checked || run.path === status.roots?.[0] ? run : null
}

// Why no portion can begin now. planning: a repair plan runs. A dry run
// beside an import would become the backlog's basis and stay there with
// books the import takes meanwhile; open proposals don't matter here.
export function portionBlock(status: ImportStatus, planning: boolean): "import" | "scan" | "followup" | "repair" | null {
  if (status.running) return "import"
  if (status.scanning) return "scan"
  if (status.followup?.total) return "followup"
  return planning ? "repair" : null
}

// The latest scanned run went through the whole first root and left
// nothing; a run of a subfolder says nothing about the rest
export function backlogDone(status: ImportStatus): boolean {
  const b = status.backlog
  const root = status.roots?.[0]
  if (!b?.basis || !root || !b.basis.paths.includes(root)) return false
  return b.open.books + b.open.formats + b.open.duplicates === 0
}

// {done, total} of a live run's bar; null while the scan walks the
// folders (their size isn't known yet)
export function runProgress(run: ImportRun): { done: number; total: number } | null {
  if (run.status === "running") return { done: run.done ?? 0, total: run.total }
  if (run.status === "scanning" && run.phase === "check" && run.scan) return { done: run.scan.planned, total: run.scan.units }
  return null
}

// the hooks in a fixed order, then any the hub adds later
const HOOKS = ["metadata", "classify", "convert", "embed"] as const
export type Hook = (typeof HOOKS)[number]
export const hookLabel = (name: string) => ((HOOKS as readonly string[]).includes(name) ? t(`import.followup.${name as Hook}`) : name)

export function followupQueues(queues: Record<string, number>): [string, number][] {
  const rank = (k: string) => {
    const i = (HOOKS as readonly string[]).indexOf(k)
    return i < 0 ? HOOKS.length : i
  }
  return Object.entries(queues).sort(([a], [b]) => rank(a) - rank(b) || a.localeCompare(b))
}
