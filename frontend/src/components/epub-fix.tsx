import { useEffect, useState } from "react"
import { useQuery, useQueryClient } from "@tanstack/react-query"
import { FileCheck, Loader2, Wrench } from "lucide-react"
import { ApiError, write, type Book, type EpubFixRun } from "@/lib/api"
import { formatNumber, t } from "@/i18n"
import type { MessageKey } from "@/i18n/de"
import { Button } from "./ui/button"

const errorText = (e: unknown) => (e instanceof ApiError ? e.message : String(e))

export function codeLabel(code: string): string {
  const key = `epubFix.code.${code}` as MessageKey
  const text = t(key)
  return text === undefined ? code : text
}

const labels = (counts: Record<string, number>) =>
  Object.entries(counts)
    .map(([code, n]) => `${codeLabel(code)} ${formatNumber(n)}`)
    .join(", ")

// Starts a fixer run and follows it until it is done
function useEpubFix(onDone?: (run: EpubFixRun) => void) {
  const [jobId, setJobId] = useState<string | null>(null)
  const [error, setError] = useState<unknown>(null)
  const [starting, setStarting] = useState(false)
  const { data: run } = useQuery({
    queryKey: ["epub-fix", jobId],
    queryFn: () => write.epubFixRun(jobId!),
    enabled: !!jobId,
    refetchInterval: (q) => (q.state.data?.status === "running" || !q.state.data ? 1000 : false),
    retry: false,
  })
  const finished = run && run.status !== "running" ? run : null
  useEffect(() => {
    if (finished) onDone?.(finished)
    // once per finished run
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [finished?.id])
  const start = (dryRun: boolean, ids?: number[]) => {
    setStarting(true)
    setError(null)
    write
      .epubFix(dryRun, ids)
      .then((r) => setJobId(r.jobId), setError)
      .finally(() => setStarting(false))
  }
  return { run, error, running: starting || run?.status === "running", start }
}

function RunStatus({ run }: { run: EpubFixRun }) {
  if (run.status === "running") return <>{t("epubFix.running", { done: formatNumber(run.done), total: formatNumber(run.total) })}</>
  if (run.status === "failed" && run.error) return <>{t("meta.runFailed", { error: run.error })}</>
  const count = run.dryRun ? run.booksWithFixes : run.booksFixed
  const parts = [count === 0 ? t("epubFix.nothing") : t(run.dryRun ? "epubFix.found" : "epubFix.fixed", { count: formatNumber(count) })]
  if (Object.keys(run.fixes).length) parts[0] += ` (${labels(run.fixes)})`
  if (run.booksWithProblems) parts.push(`${t("epubFix.problems", { count: formatNumber(run.booksWithProblems) })} (${labels(run.problems)})`)
  if (run.errors.length) parts.push(t("meta.runDone", { done: formatNumber(run.done), errors: formatNumber(run.errors.length) }))
  return <>{parts.join(" · ")}</>
}

// Metadaten page: check the library (dry run) or repair it
export function EpubFixLibrary() {
  const { run, error, running, start } = useEpubFix()
  return (
    <div className="space-y-2">
      <div className="flex flex-wrap gap-2">
        <Button variant="outline" disabled={running} onClick={() => start(true)}>
          {running ? <Loader2 className="animate-spin eink:animate-none" /> : <FileCheck />} {t("epubFix.check")}
        </Button>
        <Button variant="outline" disabled={running} onClick={() => start(false)}>
          <Wrench /> {t("epubFix.apply")}
        </Button>
      </div>
      {run && (
        <p role="status" className="text-sm tabular-nums">
          <RunStatus run={run} />
        </p>
      )}
      {error != null && (
        <p role="alert" className="text-sm text-destructive">
          {t("epubFix.error")}: {errorText(error)}
        </p>
      )}
    </div>
  )
}

// Book detail: repair this book's EPUB
export function EpubFixButton({ book }: { book: Book }) {
  const qc = useQueryClient()
  const { run, error, running, start } = useEpubFix((r) => {
    if (r.booksFixed) qc.invalidateQueries({ queryKey: ["book", book.id] })
  })
  if (!book.formats.includes("EPUB")) return null
  const result = run?.status === "done" ? run.results.find((r) => r.bookId === book.id) : undefined
  return (
    <>
      <Button type="button" variant="outline" disabled={running} onClick={() => start(false, [book.id])}>
        {running ? <Loader2 className="animate-spin eink:animate-none" /> : <Wrench />} {t("epubFix.book")}
      </Button>
      {run && run.status !== "running" && (
        <p role="status" className="w-full text-sm">
          {result?.fixes.length
            ? `${t("epubFix.bookFixed")}: ${[...new Set(result.fixes.map((f) => codeLabel(f.code)))].join(", ")}`
            : run.status === "failed"
              ? (run.error ?? run.errors[0]?.error)
              : t("epubFix.nothing")}
          {result?.problems.length ? ` · ${result.problems.map((p) => p.detail).join("; ")}` : ""}
        </p>
      )}
      {error != null && (
        <p role="alert" className="w-full text-sm text-destructive">
          {t("epubFix.error")}: {errorText(error)}
        </p>
      )}
    </>
  )
}
