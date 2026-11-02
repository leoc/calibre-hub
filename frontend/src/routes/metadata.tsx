import { useEffect, useMemo, useRef, useState } from "react"
import { useQuery, useQueryClient } from "@tanstack/react-query"
import { Link } from "@tanstack/react-router"
import { ArrowLeft, ArrowRight, FileOutput, Loader2, RotateCcw, UsersRound, WandSparkles } from "lucide-react"
import { ApiError, write, type MetadataChange, type MetadataStatus, type MetadataTarget } from "@/lib/api"
import { metadataChangesQuery, metadataStatusQuery } from "@/lib/queries"
import { invalidateMetadata, RevertConflictError, useRevertMetadataChange, useRevertMetadataChanges, useStartMetadataRun } from "@/lib/mutations"
import { fieldLabel, formatValue, groupChanges, sourceLabel, type BookChanges } from "@/lib/metadata"
import { formatDate, formatNumber, locale, t } from "@/i18n"
import { cn } from "@/lib/utils"
import { Button, buttonVariants } from "@/components/ui/button"
import { BookCover } from "@/components/book-cover"
import { ErrorMessage } from "@/components/error-view"
import { LibraryLink } from "@/components/library-link"
import { EpubFixLibrary } from "@/components/epub-fix"
import { BacklogImport } from "@/components/backlog-import"

const errorText = (e: unknown) => (e instanceof ApiError ? e.message : String(e))
const dateTime = (iso: string) => new Date(iso).toLocaleString(locale, { dateStyle: "medium", timeStyle: "short" })
const source = (s: string) => {
  const key = sourceLabel(s)
  return key ? t(key) : s
}
const tapLink = "underline-offset-2 hover:underline eink:inline-flex eink:min-h-11 eink:items-center touch:inline-flex touch:min-h-11 touch:items-center"

// What the metadata cleanup changed, per book, with revert; starts runs.
export function MetadataPage() {
  const [showReverted, setShowReverted] = useState(false)
  const { data, error, refetch } = useQuery(metadataChangesQuery(showReverted ? {} : { reverted: false }))
  const { data: status } = useQuery(metadataStatusQuery)
  const revert = useRevertMetadataChanges()
  const groups = useMemo(() => (data ? groupChanges(data.changes, data.books) : []), [data])
  // only books with something left to revert can be selected
  const ids = useMemo(() => groups.filter((g) => g.book && g.active.length).map((g) => g.bookId), [groups])
  const [selected, setSelected] = useState<Set<number>>(new Set())
  const chosen = ids.filter((id) => selected.has(id))
  const toggle = (id: number, on: boolean) =>
    setSelected((s) => {
      const next = new Set(s)
      if (on) next.add(id)
      else next.delete(id)
      return next
    })

  return (
    <div className="mx-auto max-w-4xl space-y-5 p-4 lg:p-6">
      <LibraryLink search={{}} className={buttonVariants({ variant: "ghost", className: "-ml-2" })}>
        <ArrowLeft /> {t("book.back")}
      </LibraryLink>
      <div className="space-y-1">
        <h1 className="text-2xl font-semibold">{t("meta.title")}</h1>
        <p className="text-sm text-muted-foreground eink:text-black">{t("meta.hint")}</p>
        {status && <StatusLine status={status} />}
      </div>
      <MetadataRun />
      <ConvertRun />
      <EpubFixLibrary />
      <BacklogImport />
      {revert.data && (
        <p role="status" className="text-sm">
          {t("meta.revertedCount", { count: formatNumber(revert.data.reverted.length) })}
          {revert.data.errors.length > 0 && ` · ${revert.data.errors.map((e) => `#${e.bookId}: ${e.error}`).join(", ")}`}
        </p>
      )}
      {revert.error && (
        <p role="alert" className="text-sm text-destructive">
          {t("meta.revertError")}: {errorText(revert.error)}
        </p>
      )}

      <div className="flex flex-wrap items-center gap-x-5 gap-y-1">
        {ids.length > 0 && (
          <label className="flex items-center gap-2 text-sm eink:min-h-11 touch:min-h-11">
            <input
              type="checkbox"
              className="size-4 eink:size-6"
              checked={chosen.length === ids.length}
              onChange={(e) => setSelected(new Set(e.target.checked ? ids : []))}
            />
            {t("suggest.selectAll")}
          </label>
        )}
        <label className="flex items-center gap-2 text-sm eink:min-h-11 touch:min-h-11">
          <input type="checkbox" className="size-4 eink:size-6" checked={showReverted} onChange={(e) => setShowReverted(e.target.checked)} />
          {t("meta.showReverted")}
        </label>
        <span className="flex-1" />
        {ids.length > 0 && (
          <Button
            size="sm"
            variant="outline"
            disabled={!chosen.length || revert.isPending}
            onClick={() => revert.mutate({ bookIds: chosen }, { onSuccess: () => setSelected(new Set()) })}
          >
            <RotateCcw /> {t("meta.revertSelected", { count: formatNumber(chosen.length) })}
          </Button>
        )}
      </div>

      {error && !data ? (
        <ErrorMessage error={error} onRetry={() => refetch()} />
      ) : !data ? (
        <p className="py-12 text-center text-muted-foreground">{t("loading")}</p>
      ) : groups.length === 0 ? (
        <p className="py-12 text-center text-lg">{t("meta.empty")}</p>
      ) : (
        <ul className="divide-y border-y eink:divide-y-2 eink:border-y-2" aria-label={t("meta.changes")}>
          {groups.map((g) => (
            <BookGroup key={g.bookId} group={g} selected={selected.has(g.bookId)} onSelect={(on) => toggle(g.bookId, on)} />
          ))}
        </ul>
      )}
    </div>
  )
}

function StatusLine({ status }: { status: MetadataStatus }) {
  const parts = [
    status.sources?.length ? t("meta.sources", { sources: status.sources.map(source).join(", ") }) : null,
    status.model ? t("meta.model", { model: status.model }) : null,
    status.nightly ? t("meta.nightly", { time: status.nightly }) : null,
  ].filter(Boolean)
  const second = [
    status.lastRun ? t("meta.lastRun", { date: dateTime(status.lastRun.startedAt) }) : null,
    status.changedBooks != null ? t("meta.changedBooks", { count: formatNumber(status.changedBooks) }) : null,
  ].filter(Boolean)
  return (
    <>
      {parts.length > 0 && <p className="text-xs text-muted-foreground eink:text-black">{parts.join(" · ")}</p>}
      {second.length > 0 && <p className="text-xs text-muted-foreground eink:text-black">{second.join(" · ")}</p>}
    </>
  )
}

function BookGroup({ group: g, selected, onSelect }: { group: BookChanges; selected: boolean; onSelect: (on: boolean) => void }) {
  const revertAll = useRevertMetadataChanges()
  const title = g.book?.title ?? t("meta.deleted", { id: g.bookId })
  const selectable = !!g.book && g.active.length > 0
  return (
    <li className="flex flex-wrap items-start gap-3 py-3" aria-label={title}>
      {/* the label is the tap target: 44 px on touch screens and E-Ink */}
      <label className={cn("flex size-6 shrink-0 cursor-pointer items-center justify-center eink:-m-2.5 eink:size-11 touch:-m-2.5 touch:size-11", !selectable && "invisible")}>
        <input
          type="checkbox"
          className="size-4 eink:size-6"
          checked={selected}
          disabled={!selectable}
          onChange={(e) => onSelect(e.target.checked)}
          aria-label={`${t("suggest.select")}: ${title}`}
        />
      </label>
      {g.book && (
        <Link to="/books/$id" params={{ id: g.book.id }} search={{}} className="shrink-0" tabIndex={-1} aria-hidden>
          <BookCover book={g.book} compact className="w-12" />
        </Link>
      )}
      <div className="min-w-0 flex-1 basis-56 space-y-2">
        <div className="flex flex-wrap items-start gap-x-3 gap-y-1">
          <div className="min-w-0 flex-1">
            {g.book ? (
              <Link to="/books/$id" params={{ id: g.book.id }} search={{}} className={cn("font-medium", tapLink)}>
                {g.book.title}
              </Link>
            ) : (
              <p className="font-medium">{title}</p>
            )}
            {g.book && <p className="text-sm text-muted-foreground eink:text-black">{g.book.authors.join(", ")}</p>}
          </div>
          {g.book && g.active.length > 1 && (
            <Button size="sm" variant="outline" disabled={revertAll.isPending} onClick={() => revertAll.mutate({ bookIds: [g.bookId] })} aria-label={`${t("meta.revertAll")}: ${title}`}>
              <RotateCcw /> {t("meta.revertAll")}
            </Button>
          )}
        </div>
        {revertAll.data?.errors.map((e) => (
          <p key={e.changeId} role="alert" className="text-sm text-destructive">
            {t("meta.revertError")}: {e.error}
          </p>
        ))}
        {revertAll.error && (
          <p role="alert" className="text-sm text-destructive">
            {t("meta.revertError")}: {errorText(revertAll.error)}
          </p>
        )}
        <ul className="divide-y rounded-md border text-sm eink:divide-y-2 eink:border-2" aria-label={t("meta.changesOf", { title })}>
          {g.changes.map((c) => (
            <ChangeRow key={c.id} change={c} title={title} canRevert={!!g.book} />
          ))}
        </ul>
      </div>
    </li>
  )
}

function Value({ change: c, which }: { change: MetadataChange; which: "old" | "new" }) {
  const v = c[which]
  if (c.field === "cover" && typeof v === "string" && v) {
    return <img src={v} alt={t("meta.field.cover")} loading="lazy" referrerPolicy="no-referrer" className="h-16 w-12 rounded-sm bg-muted object-cover eink:border-2 eink:border-black" />
  }
  return <span className="break-words">{formatValue(c.field, v)}</span>
}

function ChangeRow({ change: c, title, canRevert }: { change: MetadataChange; title: string; canRevert: boolean }) {
  const revert = useRevertMetadataChange()
  const label = fieldLabel(c.field)
  const reverted = !!c.revertedAt
  return (
    <li className={cn("flex flex-wrap items-start gap-x-3 gap-y-1 px-3 py-2", reverted && "text-muted-foreground eink:text-black")} aria-label={label}>
      <div className="w-full sm:w-40 sm:shrink-0">
        <p className="font-medium">{label}</p>
        <p className="text-xs text-muted-foreground eink:text-black">
          {source(c.source)} · {formatDate(c.at)}
        </p>
      </div>
      <div className={cn("flex min-w-0 flex-1 basis-48 flex-wrap items-center gap-x-2 gap-y-1", reverted && "opacity-60 eink:opacity-100")}>
        <span className="sr-only">{t("meta.before")}: </span>
        <span className="text-muted-foreground eink:text-black">
          <Value change={c} which="old" />
        </span>
        <ArrowRight className="size-4 shrink-0" aria-hidden />
        <span className="sr-only">{t("meta.after")}: </span>
        <span className={cn(!reverted && "font-medium")}>
          <Value change={c} which="new" />
        </span>
      </div>
      {reverted ? (
        <span className="self-center text-xs italic eink:text-sm">{t("meta.reverted")}</span>
      ) : (
        canRevert && (
          <Button size="sm" variant="outline" disabled={revert.isPending} onClick={() => revert.mutate(c.id)} aria-label={`${t("meta.revert")}: ${label}, ${title}`}>
            <RotateCcw /> {t("meta.revert")}
          </Button>
        )
      )}
      {revert.error && (
        <p role="alert" className="w-full text-sm text-destructive">
          {revert.error instanceof RevertConflictError ? t("meta.conflict") : `${t("meta.revertError")}: ${errorText(revert.error)}`}
        </p>
      )}
    </li>
  )
}

// "Bestand nachziehen": converts the books without EPUB (the original stays)
function ConvertRun() {
  const [jobId, setJobId] = useState<string | null>(null)
  const [error, setError] = useState<unknown>(null)
  const [starting, setStarting] = useState(false)
  const { data: job } = useQuery({
    queryKey: ["job", jobId],
    queryFn: () => write.job(jobId!),
    enabled: !!jobId,
    refetchInterval: (q) => (q.state.data?.status === "running" || !q.state.data ? 1000 : false),
    retry: false,
  })
  const running = starting || job?.status === "running"
  const start = () => {
    setStarting(true)
    setError(null)
    write
      .convert("EPUB")
      .then((r) => setJobId(r.jobId), setError)
      .finally(() => setStarting(false))
  }

  return (
    <div className="space-y-2">
      <Button variant="outline" disabled={running} onClick={start}>
        {running ? <Loader2 className="animate-spin eink:animate-none" /> : <FileOutput />} {t("meta.convert")}
      </Button>
      {job && (
        <p role="status" className="text-sm tabular-nums">
          {job.status === "running"
            ? t("meta.converting", { done: formatNumber(job.done), total: formatNumber(job.total) })
            : job.status === "failed" && job.error
              ? t("meta.runFailed", { error: job.error })
              : t("meta.runDone", { done: formatNumber(job.done), errors: formatNumber(job.errors.length) })}
        </p>
      )}
      {error != null && (
        <p role="alert" className="text-sm text-destructive">
          {t("meta.convertError")}: {errorText(error)}
        </p>
      )}
    </div>
  )
}

const RUNS: { target: MetadataTarget & string; label: "meta.runIncomplete" | "meta.runAll" | "meta.runAuthors"; icon: typeof WandSparkles }[] = [
  { target: "incomplete", label: "meta.runIncomplete", icon: WandSparkles },
  { target: "all", label: "meta.runAll", icon: WandSparkles },
  { target: "authors", label: "meta.runAuthors", icon: UsersRound },
]

// The three run buttons and the progress of the current run
function MetadataRun() {
  const qc = useQueryClient()
  const start = useStartMetadataRun()
  const [jobId, setJobId] = useState<string | null>(null)
  const [target, setTarget] = useState<MetadataTarget | null>(null)
  const { data: status } = useQuery(metadataStatusQuery)
  const { data: job } = useQuery({
    queryKey: ["job", jobId],
    queryFn: () => write.job(jobId!),
    enabled: !!jobId,
    refetchInterval: (q) => (q.state.data?.status === "running" || !q.state.data ? 1000 : false),
    retry: false,
  })
  const finished = job && job.status !== "running"
  // a run started elsewhere (nightly) shows up through the status
  const shown = job ?? (status?.running ? status.lastRun : null)
  const running = start.isPending || shown?.status === "running"
  useEffect(() => {
    if (finished) invalidateMetadata(qc)
  }, [finished, qc])
  // the status poll seeing a run end that was started elsewhere
  const wasRunning = useRef(false)
  useEffect(() => {
    if (wasRunning.current && !status?.running) invalidateMetadata(qc)
    wasRunning.current = !!status?.running
  }, [status?.running, qc])

  return (
    <div className="space-y-2">
      <div className="flex flex-wrap items-center gap-2">
        {RUNS.map((run) => (
          <Button
            key={run.target}
            variant="outline"
            disabled={running}
            onClick={() => {
              setTarget(run.target)
              start.mutate(run.target, { onSuccess: (r) => setJobId(r.jobId) })
            }}
          >
            {running && target === run.target ? <Loader2 className="animate-spin eink:animate-none" /> : <run.icon />} {t(run.label)}
          </Button>
        ))}
      </div>
      {shown && (
        <p role="status" className="text-sm tabular-nums">
          {shown.status === "running"
            ? t("meta.running", { done: formatNumber(shown.done), total: formatNumber(shown.total) })
            : shown.status === "failed" && shown.error
              ? t("meta.runFailed", { error: shown.error })
              : t("meta.runDone", { done: formatNumber(shown.done), errors: formatNumber(shown.errors.length) })}
        </p>
      )}
      {start.error && (
        <p role="alert" className="text-sm text-destructive">
          {t("meta.runError")}: {errorText(start.error)}
        </p>
      )}
    </div>
  )
}
