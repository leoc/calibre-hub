import { useEffect, useMemo, useState } from "react"
import { useQuery, useQueryClient } from "@tanstack/react-query"
import { Link } from "@tanstack/react-router"
import { ArrowLeft, Check, Loader2, Pencil, Sparkles, X } from "lucide-react"
import { ApiError, write, type Book, type Suggestion } from "@/lib/api"
import { categoriesQuery, classifyStatusQuery, suggestionsQuery } from "@/lib/queries"
import { useAcceptSuggestion, useAcceptSuggestions, useRejectSuggestion, useStartClassify } from "@/lib/mutations"
import { categoryLabel, categorySuggestions, parseCategory, percent } from "@/lib/kategorie"
import { formatNumber, t } from "@/i18n"
import { Button, buttonVariants } from "@/components/ui/button"
import { Combobox } from "@/components/ui/suggest"
import { BookCover } from "@/components/book-cover"
import { ErrorMessage } from "@/components/error-view"
import { LibraryLink } from "@/components/library-link"

const errorText = (e: unknown) => (e instanceof ApiError ? e.message : String(e))

// Review of the model's category suggestions: accept, change, reject, one by
// one or several at once; starts a run over the books without a category.
export function SuggestionsPage() {
  const { data, error, refetch } = useQuery(suggestionsQuery("pending"))
  const { data: status } = useQuery(classifyStatusQuery)
  const accept = useAcceptSuggestions()
  const [selected, setSelected] = useState<Set<number>>(new Set())
  const ids = useMemo(() => data?.map((s) => s.bookId) ?? [], [data])
  // gone from the list: no longer selectable
  const chosen = ids.filter((id) => selected.has(id))
  const toggle = (id: number, on: boolean) =>
    setSelected((s) => {
      const next = new Set(s)
      if (on) next.add(id)
      else next.delete(id)
      return next
    })
  const tooFew = status?.categories != null && status.minCategories != null && status.categories < status.minCategories

  return (
    // phones: room at the bottom for the fixed action bar
    <div className="mx-auto max-w-4xl space-y-5 p-4 max-sm:pb-28 lg:p-6">
      <LibraryLink search={{}} className={buttonVariants({ variant: "ghost", className: "-ml-2" })}>
        <ArrowLeft /> {t("book.back")}
      </LibraryLink>
      <div className="space-y-1">
        <h1 className="text-2xl font-semibold">{t("suggest.title")}</h1>
        <p className="text-sm text-muted-foreground eink:text-black">{t("suggest.hint")}</p>
        {status?.model && status.threshold != null && (
          <p className="text-xs text-muted-foreground eink:text-black">
            {t("suggest.model", { model: status.model, threshold: Math.round(status.threshold * 100) })}
          </p>
        )}
      </div>
      {tooFew && (
        <p role="note" className="rounded-md border p-3 text-sm eink:border-2">
          {t("suggest.tooFew", { min: status.minCategories!, count: status.categories! })}
        </p>
      )}
      <ClassifyRun disabled={tooFew} />
      {accept.data && (
        <p role="status" className="text-sm">
          {t("suggest.accepted", { count: formatNumber(accept.data.accepted.length) })}
          {accept.data.errors.length > 0 && ` · ${accept.data.errors.map((e) => `#${e.bookId}: ${e.error}`).join(", ")}`}
        </p>
      )}
      {accept.error && (
        <p role="alert" className="text-sm text-destructive">
          {t("suggest.error")}: {errorText(accept.error)}
        </p>
      )}

      {error && !data ? (
        <ErrorMessage error={error} onRetry={() => refetch()} />
      ) : !data ? (
        <p className="py-12 text-center text-muted-foreground">{t("loading")}</p>
      ) : data.length === 0 ? (
        <p className="py-12 text-center text-lg">{t("suggest.empty")}</p>
      ) : (
        <>
          {/* phones: fixed at the bottom, in thumb reach however long the list is */}
          <div className="flex flex-wrap items-center gap-3 max-sm:fixed max-sm:inset-x-0 max-sm:bottom-0 max-sm:z-20 max-sm:mb-0 max-sm:flex-nowrap max-sm:border-t max-sm:bg-background max-sm:pr-[max(1rem,env(safe-area-inset-right))] max-sm:pl-[max(1rem,env(safe-area-inset-left))] max-sm:pt-3 max-sm:pb-[max(0.75rem,env(safe-area-inset-bottom))] max-sm:shadow-[0_-4px_12px_rgba(0,0,0,0.06)] eink:max-sm:border-t-2 eink:max-sm:shadow-none">
            <label className="flex shrink-0 items-center gap-2 text-sm eink:min-h-11 touch:min-h-11">
              <input
                type="checkbox"
                className="size-4 eink:size-6"
                checked={chosen.length === ids.length}
                onChange={(e) => setSelected(new Set(e.target.checked ? ids : []))}
              />
              {t("suggest.selectAll")}
            </label>
            <span className="flex-1" />
            <Button
              size="sm"
              disabled={!chosen.length || accept.isPending}
              aria-label={t("suggest.acceptSelected", { count: formatNumber(chosen.length) })}
              onClick={() => accept.mutate(chosen, { onSuccess: () => setSelected(new Set()) })}
            >
              <Check /> <span className="sm:hidden">{t("suggest.acceptSelectedShort", { count: formatNumber(chosen.length) })}</span>
              <span className="max-sm:hidden">{t("suggest.acceptSelected", { count: formatNumber(chosen.length) })}</span>
            </Button>
          </div>
          <ul className="divide-y border-y eink:divide-y-2 eink:border-y-2" aria-label={t("suggest.title")}>
            {data.map((s) => (
              <SuggestionRow key={s.bookId} suggestion={s} book={s.book} selected={selected.has(s.bookId)} onSelect={(on) => toggle(s.bookId, on)} />
            ))}
          </ul>
        </>
      )}
    </div>
  )
}

function SuggestionRow({ suggestion: s, book, selected, onSelect }: { suggestion: Suggestion; book: Book; selected: boolean; onSelect: (on: boolean) => void }) {
  const [changing, setChanging] = useState(false)
  const accept = useAcceptSuggestion()
  const reject = useRejectSuggestion()
  const busy = accept.isPending || reject.isPending
  const failed = accept.error ?? reject.error
  return (
    <li className="flex flex-wrap items-start gap-3 py-3" aria-label={book.title}>
      {/* the label is the tap target: 44 px on touch screens and E-Ink */}
      <label className="flex size-6 shrink-0 cursor-pointer items-center justify-center eink:-m-2.5 eink:size-11 touch:-m-2.5 touch:size-11">
        <input
          type="checkbox"
          className="size-4 eink:size-6"
          checked={selected}
          onChange={(e) => onSelect(e.target.checked)}
          aria-label={`${t("suggest.select")}: ${book.title}`}
        />
      </label>
      <Link to="/books/$id" params={{ id: book.id }} search={{}} className="shrink-0">
        <BookCover book={book} compact className="w-12" />
      </Link>
      <div className="min-w-0 flex-1 basis-56 space-y-1">
        <Link
          to="/books/$id"
          params={{ id: book.id }}
          search={{}}
          className="font-medium underline-offset-2 hover:underline eink:inline-flex eink:min-h-11 eink:items-center touch:inline-flex touch:min-h-11 touch:items-center"
        >
          {book.title}
        </Link>
        <p className="text-sm text-muted-foreground eink:text-black">{book.authors.join(", ")}</p>
        <p className="text-sm">
          <span className="sr-only">{t("suggest.category")}: </span>
          <span className="font-medium">{s.category ? categoryLabel(s.category) : "–"}</span>
          <span className="text-muted-foreground tabular-nums eink:text-black" title={t("suggest.confidence")}>
            {" "}
            · {percent(s.confidence)}
          </span>
        </p>
        {s.reason && (
          <p className="text-sm text-muted-foreground italic eink:text-black">
            <span className="sr-only">{t("suggest.reason")}: </span>
            {s.reason}
          </p>
        )}
        {changing && <ChangeCategory initial={s.category} busy={busy} onCancel={() => setChanging(false)} onSave={(category) => accept.mutate({ bookId: s.bookId, category })} />}
        {failed && (
          <p role="alert" className="text-sm text-destructive">
            {t("suggest.error")}: {errorText(failed)}
          </p>
        )}
      </div>
      {!changing && (
        <div className="flex flex-wrap gap-2">
          <Button size="sm" disabled={busy || !s.category} onClick={() => accept.mutate({ bookId: s.bookId })} aria-label={`${t("suggest.accept")}: ${book.title}`}>
            <Check /> {t("suggest.accept")}
          </Button>
          <Button size="sm" variant="outline" disabled={busy} onClick={() => setChanging(true)} aria-label={`${t("suggest.change")}: ${book.title}`}>
            <Pencil /> {t("suggest.change")}
          </Button>
          <Button size="sm" variant="outline" disabled={busy} onClick={() => reject.mutate(s.bookId)} aria-label={`${t("suggest.reject")}: ${book.title}`}>
            <X /> {t("suggest.reject")}
          </Button>
        </div>
      )}
    </li>
  )
}

function ChangeCategory({ initial, busy, onSave, onCancel }: { initial: string | null; busy: boolean; onSave: (category: string) => void; onCancel: () => void }) {
  const { data: cats } = useQuery(categoriesQuery)
  const [text, setText] = useState(initial ? categoryLabel(initial) : "")
  const parsed = parseCategory(text)
  const invalid = "error" in parsed ? t("kategorie.dot", { name: parsed.error }) : null
  const value = "value" in parsed ? parsed.value : null
  return (
    <form
      className="flex flex-wrap items-start gap-2 pt-1"
      onSubmit={(e) => {
        e.preventDefault()
        if (value) onSave(value)
      }}
    >
      <Combobox aria-label={t("book.kategorie")} value={text} onChange={setText} suggestions={categorySuggestions(cats?.kategorie ?? [])} className="min-w-48 flex-1" />
      <Button size="sm" type="submit" disabled={busy || !value}>
        {t("suggest.save")}
      </Button>
      <Button size="sm" type="button" variant="ghost" onClick={onCancel}>
        {t("suggest.cancel")}
      </Button>
      {invalid && (
        <p role="alert" className="w-full text-xs text-destructive">
          {invalid}
        </p>
      )}
    </form>
  )
}

// "Unsortierte klassifizieren" and the progress of the run
function ClassifyRun({ disabled }: { disabled: boolean }) {
  const qc = useQueryClient()
  const start = useStartClassify()
  const [jobId, setJobId] = useState<string | null>(null)
  const { data: status } = useQuery(classifyStatusQuery)
  const { data: job } = useQuery({
    queryKey: ["job", jobId],
    queryFn: () => write.job(jobId!),
    enabled: !!jobId,
    refetchInterval: (q) => (q.state.data?.status === "running" || !q.state.data ? 1000 : false),
    retry: false,
  })
  const finished = job && job.status !== "running"
  useEffect(() => {
    if (!finished) return
    qc.invalidateQueries({ queryKey: ["suggestions"] })
    qc.invalidateQueries({ queryKey: ["suggestion"] })
    qc.invalidateQueries({ queryKey: ["classify-status"] })
    qc.invalidateQueries({ queryKey: ["books"] })
    qc.invalidateQueries({ queryKey: ["book"] })
    qc.invalidateQueries({ queryKey: ["categories"] })
  }, [finished, qc])
  // a run started elsewhere (nightly, new books) shows up through the status
  const shown = job ?? (status?.running ? status.lastRun : null)
  const running = start.isPending || shown?.status === "running"

  return (
    <div className="flex flex-wrap items-center gap-3">
      <Button
        variant="outline"
        disabled={disabled || running}
        onClick={() => start.mutate("unsorted", { onSuccess: (r) => setJobId(r.jobId) })}
      >
        {running ? <Loader2 className="animate-spin eink:animate-none" /> : <Sparkles />} {t("suggest.run")}
      </Button>
      {shown && (
        <span role="status" className="text-sm tabular-nums">
          {shown.status === "running"
            ? t("suggest.running", { done: formatNumber(shown.done), total: formatNumber(shown.total) })
            : shown.status === "failed" && shown.error
              ? t("suggest.runFailed", { error: shown.error })
              : t("suggest.runDone", { done: formatNumber(shown.done), errors: formatNumber(shown.errors.length) })}
        </span>
      )}
      {start.error && (
        <p role="alert" className="text-sm text-destructive">
          {t("suggest.runError")}: {errorText(start.error)}
        </p>
      )}
    </div>
  )
}
