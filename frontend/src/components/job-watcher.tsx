import { useEffect } from "react"
import { useQuery, useQueryClient, type QueryClient } from "@tanstack/react-query"
import { useNavigate } from "@tanstack/react-router"
import { ApiError, write, type Job } from "@/lib/api"
import { trackedJobs, useTrackedJobs, type TrackedJob } from "@/lib/jobs"
import { invalidateLibrary, invalidateMetadata } from "@/lib/mutations"
import { errorText } from "@/lib/run-action"
import { selection } from "@/lib/selection"
import { toast } from "@/lib/toast"
import { formatNumber, t } from "@/i18n"

// Follows the jobs of src/lib/jobs.ts until they finish (mounted once in the
// app shell): refreshes what they changed and says so in a toast, with
// "Rückgängig" for field changes.
export function JobWatcher() {
  const jobs = useTrackedJobs()
  return (
    <>
      {jobs
        .filter((j) => !j.finished)
        .map((j) => (
          <Watch key={j.id} job={j} />
        ))}
    </>
  )
}

export const jobQuery = (id: string) => ({
  queryKey: ["job", id],
  queryFn: () => write.job(id),
  refetchInterval: (q: { state: { data?: Job } }) => (q.state.data?.status === "running" || !q.state.data ? 700 : false),
  retry: false,
})

function Watch({ job }: { job: TrackedJob }) {
  const qc = useQueryClient()
  const navigate = useNavigate()
  const { data, error } = useQuery(jobQuery(job.id))
  // 404: the hub restarted and forgot the job
  const lost = error instanceof ApiError && error.status === 404
  const finished = !!data && data.status !== "running"
  useEffect(() => {
    if (!finished && !lost) return
    refresh(qc, job)
    void finishedToast(job, data, (to) => void navigate({ to }))
    trackedJobs.finish(job.id)
    // once
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [finished, lost])
  return null
}

function refresh(qc: QueryClient, job: TrackedJob) {
  switch (job.kind) {
    case "metadata":
      return invalidateMetadata(qc)
    case "classify":
      qc.invalidateQueries({ queryKey: ["suggestions"] })
      qc.invalidateQueries({ queryKey: ["suggestion"] })
      qc.invalidateQueries({ queryKey: ["classify-status"] })
      break
    case "delete":
      invalidateLibrary(qc)
      // the selected books are gone
      selection.clear()
      return
  }
  qc.invalidateQueries({ queryKey: ["books"] })
  qc.invalidateQueries({ queryKey: ["book"] })
  qc.invalidateQueries({ queryKey: ["categories"] })
}

async function finishedToast(job: TrackedJob, data: Job | undefined, go: (to: "/suggestions" | "/metadata") => void) {
  if (!data) return void toast.show(t("bulk.lost"))
  if (data.status === "failed" && data.error) return void toast.show(t("actions.failed", { label: job.label, error: data.error }))
  const ok = data.done - data.errors.length
  let text =
    job.kind === "delete"
      ? t("actions.deleted", { count: formatNumber(ok) })
      : (job.doneText ?? (data.errors.length ? t("actions.doneErrors", { label: job.label, errors: formatNumber(data.errors.length) }) : t("actions.done", { label: job.label })))
  if (job.kind === "epubFix") {
    const run = await write.epubFixRun(job.id).catch(() => null)
    if (run) text = `${text} · ${run.booksFixed ? t("actions.epubFixDone", { count: formatNumber(run.booksFixed) }) : t("epubFix.nothing")}`
  }
  if (job.undoable && ok > 0)
    return void toast.show(text, {
      label: t("toast.undo"),
      run: () =>
        void write
          .undoJob(job.id)
          .then((r) => trackedJobs.add({ id: r.jobId, total: r.total, kind: "bulk", label: job.label, doneText: t("actions.undone", { label: job.label }) }))
          .catch((e: unknown) => toast.show(t("list.undoFailed", { error: errorText(e) }))),
    })
  if (job.kind === "classify") return void toast.show(text, { label: t("actions.showSuggestions"), run: () => go("/suggestions") })
  if (job.kind === "metadata") return void toast.show(text, { label: t("actions.showMetadata"), run: () => go("/metadata") })
  toast.show(text)
}
