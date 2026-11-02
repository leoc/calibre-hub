import { useSyncExternalStore } from "react"
import type { BulkChanges, BulkTarget } from "./api"

// Background jobs started from the bulk bar or the command palette, watched
// by <JobWatcher> (src/components/job-watcher.tsx) until they finish: it
// refreshes what they changed and says so in a toast, with "Rückgängig" for
// field changes. The bulk bar shows the progress of its kind of job.

export type JobKind = "bulk" | "delete" | "metadata" | "classify" | "epubFix" | "convert"

export interface TrackedJob {
  id: string
  total: number
  kind: JobKind
  // what it does, for the toasts ("Tag ‚Krimi‘ hinzufügen (3)")
  label: string
  // for the bulk bar's retry
  target?: BulkTarget
  changes?: BulkChanges
  // a field change: the finished toast offers to undo it
  undoable?: boolean
  // the finished toast instead of "Erledigt: …"
  doneText?: string
  // the watcher is through with it
  finished?: boolean
  // the bulk bar's OK
  dismissed?: boolean
}

let jobs: TrackedJob[] = []
const listeners = new Set<() => void>()
const set = (next: TrackedJob[]) => {
  jobs = next
  listeners.forEach((l) => l())
}

export const trackedJobs = {
  get: () => jobs,
  add: (job: TrackedJob) => set([...jobs.filter((j) => j.id !== job.id), job]),
  remove: (id: string) => set(jobs.filter((j) => j.id !== id)),
  finish: (id: string) => set(jobs.flatMap((j) => (j.id !== id ? [j] : j.dismissed || !isBulkJob(j) ? [] : [{ ...j, finished: true }]))),
  // the bar's OK: gone once finished
  dismiss: (id: string) => set(jobs.flatMap((j) => (j.id !== id ? [j] : j.finished ? [] : [{ ...j, dismissed: true }]))),
  // the bar went away: what finished meanwhile is no news then
  dropFinished: () => set(jobs.filter((j) => !j.finished)),
}

export function useTrackedJobs(): TrackedJob[] {
  return useSyncExternalStore(
    (l) => {
      listeners.add(l)
      return () => listeners.delete(l)
    },
    () => jobs,
  )
}

// jobs the bulk bar shows: edits and deletes
export const isBulkJob = (j: TrackedJob) => j.kind === "bulk" || j.kind === "delete"
