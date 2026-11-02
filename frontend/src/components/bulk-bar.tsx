import { useEffect, useState } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { CheckCircle2, CircleAlert, Loader2, Trash2, X } from "lucide-react"
import { ApiError, DEFAULT_CONFIG, write, type BulkChanges, type BulkTarget } from "@/lib/api"
import { categorySuggestions, parseCategory } from "@/lib/kategorie"
import { categoriesQuery, configQuery } from "@/lib/queries"
import { toBookQuery, type LibrarySearch } from "@/lib/search"
import { selection, useSelection } from "@/lib/selection"
import { formatNumber, t } from "@/i18n"
import { Button } from "./ui/button"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "./ui/dialog"
import { ChipsInput, Combobox } from "./ui/suggest"

type Action = "addTags" | "removeTags" | "kategorie" | "series" | "delete"
interface StartedJob {
  id: string
  total: number
  target: BulkTarget
  changes: BulkChanges
}
const CONFIRM_ABOVE = 50

export function BulkBar({ search, pageIds, total }: { search: LibrarySearch; pageIds: number[]; total: number }) {
  const sel = useSelection()
  const { data: config = DEFAULT_CONFIG } = useQuery(configQuery)
  const [action, setAction] = useState<Action | null>(null)
  const [job, setJob] = useState<StartedJob | null>(null)
  const count = sel.all ? total : sel.ids.size
  // "all matches" belongs to one search
  const key = JSON.stringify({ ...search, page: undefined, book: undefined, edit: undefined })
  useEffect(() => {
    if (sel.all) selection.clear()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key])

  const { page: _p, book: _b, edit: _e, ...filters } = search
  // the bulk query takes filters only, no paging or sorting; ids keep the
  // order they were selected in (numbering a series)
  const { offset: _o, limit: _l, sort: _s, order: _r, ...query } = toBookQuery(filters, config.categoryColumn)
  const target: BulkTarget = sel.all ? { query } : { ids: [...sel.ids] }

  // Two groups: what is selected, and what to do with it. Side by side on wide
  // screens; on smaller ones each is a row that scrolls sideways instead of
  // wrapping into a block that covers the books.
  const row = "flex shrink-0 items-center gap-2 overflow-x-auto [scrollbar-width:none]"
  return (
    <div className="sticky bottom-0 z-20 -mx-4 flex flex-col gap-2 border-t bg-background px-4 pt-3 pb-[max(0.75rem,env(safe-area-inset-bottom))] shadow-[0_-4px_12px_rgba(0,0,0,0.06)] lg:-mx-6 lg:px-6 xl:flex-row xl:items-center xl:justify-between eink:border-t-2 eink:shadow-none">
      <div className={row}>
        <Button variant="ghost" size="icon" className="-ml-2" onClick={selection.stop} aria-label={t("bulk.stop")} title={t("bulk.stop")}>
          <X />
        </Button>
        <span className="shrink-0 text-sm font-medium whitespace-nowrap tabular-nums eink:text-base">{t("bulk.selected", { count: formatNumber(count) })}</span>
        <Button variant="ghost" size="sm" onClick={() => selection.addPage(pageIds)}>
          {t("bulk.page")}
        </Button>
        {total > pageIds.length && (
          <Button variant={sel.all ? "secondary" : "ghost"} size="sm" onClick={selection.selectAll} aria-pressed={sel.all}>
            {t("bulk.all", { count: formatNumber(total) })}
          </Button>
        )}
        {count > 0 && (
          <Button variant="ghost" size="sm" onClick={selection.clear}>
            {t("bulk.none")}
          </Button>
        )}
      </div>
      {job ? (
        // no overflow here: the error list opens above the bar
        <div className="flex flex-wrap items-center gap-2">
          <JobProgress job={job} onClose={() => setJob(null)} onRestart={setJob} />
        </div>
      ) : (
        <div className={row}>
          {(["addTags", "removeTags", "kategorie", "series"] as Action[]).map((a) => (
            <Button key={a} variant="outline" size="sm" disabled={!count} onClick={() => setAction(a)}>
              {t(`bulk.${a}`)}
            </Button>
          ))}
          <Button variant="outline" size="sm" disabled={!count} onClick={() => setAction("delete")}>
            <Trash2 /> {t("bulk.delete")}
          </Button>
        </div>
      )}
      {action && <BulkDialog action={action} count={count} target={target} onClose={() => setAction(null)} onStarted={setJob} />}
    </div>
  )
}

function BulkDialog({
  action,
  count,
  target,
  onClose,
  onStarted,
}: {
  action: Action
  count: number
  target: BulkTarget
  onClose: () => void
  onStarted: (job: StartedJob) => void
}) {
  const { data: cats } = useQuery(categoriesQuery)
  const [tags, setTags] = useState<string[]>([])
  const [text, setText] = useState("")
  const [confirming, setConfirming] = useState(false)
  // numbering needs an order, which only explicitly selected books have
  const canNumber = "ids" in target
  const [numberSeries, setNumberSeries] = useState(false)
  const start = useMutation({
    mutationFn: (changes: BulkChanges) => write.bulk(target, changes),
    onSuccess: (r, changes) => {
      onStarted({ id: r.jobId, total: r.total, target, changes })
      onClose()
    },
  })
  const kategorie = parseCategory(text)
  const kategorieError = action === "kategorie" && "error" in kategorie ? t("kategorie.dot", { name: kategorie.error }) : null
  const series = text.trim() || null
  const changes: BulkChanges =
    action === "delete"
      ? { delete: true }
      : action === "addTags"
      ? { addTags: tags }
      : action === "removeTags"
        ? { removeTags: tags }
        : action === "kategorie"
          ? { kategorie: "value" in kategorie ? kategorie.value : null }
          : { series, ...(numberSeries && canNumber && series ? { numberSeries: true } : {}) }
  const empty = (action === "addTags" || action === "removeTags") && !tags.length
  const submit = () => {
    if (kategorieError) return
    // deleting asks in the dialog itself
    if (action !== "delete" && count > CONFIRM_ABOVE && !confirming) return setConfirming(true)
    start.mutate(changes)
  }
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent {...(action === "delete" ? {} : { "aria-describedby": undefined })}>
        <DialogTitle className="text-lg font-semibold">
          {t(`bulk.${action}`)} · {t("bulk.selected", { count: formatNumber(count) })}
        </DialogTitle>
        {action === "delete" ? (
          <DialogDescription>{t("bulk.deleteText")}</DialogDescription>
        ) : action === "addTags" || action === "removeTags" ? (
          <ChipsInput aria-label={t("book.tags")} value={tags} onChange={setTags} suggestions={cats?.tags ?? []} allowNew={action === "addTags"} />
        ) : (
          <>
            <Combobox
              aria-label={t(action === "kategorie" ? "book.kategorie" : "book.series")}
              value={text}
              onChange={setText}
              suggestions={action === "kategorie" ? categorySuggestions(cats?.kategorie ?? []) : (cats?.series ?? [])}
            />
            {kategorieError ? (
              <p role="alert" className="text-xs text-destructive eink:font-bold eink:text-black">
                {kategorieError}
              </p>
            ) : (
              <p className="text-xs text-muted-foreground eink:text-black">{t(action === "kategorie" ? "bulk.kategorieHint" : "bulk.seriesHint")}</p>
            )}
            {action === "series" && (
              <label className="flex items-center gap-2 text-sm aria-disabled:opacity-60 eink:min-h-11 touch:min-h-11" aria-disabled={!canNumber || !series}>
                <input
                  type="checkbox"
                  checked={numberSeries && canNumber}
                  disabled={!canNumber || !series}
                  onChange={(e) => setNumberSeries(e.target.checked)}
                  className="size-4 eink:size-6"
                />
                {t("bulk.numberSeries")}
                {!canNumber && <span className="text-xs text-muted-foreground eink:text-black">({t("bulk.numberSeriesIds")})</span>}
              </label>
            )}
          </>
        )}
        {start.error && (
          <p role="alert" className="text-sm text-destructive">
            {start.error instanceof ApiError ? start.error.message : String(start.error)}
          </p>
        )}
        <div className="flex justify-end gap-2">
          <Button variant="outline" onClick={onClose}>
            {t("edit.cancel")}
          </Button>
          <Button onClick={submit} disabled={empty || !!kategorieError || start.isPending} variant={action === "delete" ? "destructive" : "default"}>
            {action === "delete"
              ? t("bulk.deleteConfirm", { count: formatNumber(count) })
              : confirming
                ? t("bulk.confirm", { count: formatNumber(count) })
                : t("bulk.apply")}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  )
}

function JobProgress({ job, onClose, onRestart }: { job: StartedJob; onClose: () => void; onRestart: (job: StartedJob) => void }) {
  const qc = useQueryClient()
  const { data, error } = useQuery({
    queryKey: ["job", job.id],
    queryFn: () => write.job(job.id),
    refetchInterval: (q) => (q.state.data?.status === "running" || !q.state.data ? 700 : false),
    retry: false,
  })
  const finished = data && data.status !== "running"
  const deleting = !!job.changes.delete
  useEffect(() => {
    if (finished) {
      qc.invalidateQueries({ queryKey: ["books"] })
      qc.invalidateQueries({ queryKey: ["book"] })
      qc.invalidateQueries({ queryKey: ["categories"] })
      if (deleting) {
        qc.invalidateQueries({ queryKey: ["trash"] })
        // the selected books are gone
        selection.clear()
      }
    }
  }, [finished, deleting, qc])
  // 404: the hub restarted and forgot the job
  const lost = error instanceof ApiError && error.status === 404
  const failed = finished ? data.errors : []
  // e.g. calibre-server restarted mid-job: run the same change on the failed
  // books; numbering needs the whole selection again to count right
  const retryTarget: BulkTarget = job.changes.numberSeries ? job.target : { ids: failed.map((e) => e.bookId) }
  const retry = useMutation({
    mutationFn: () => write.bulk(retryTarget, job.changes),
    onSuccess: (r) => onRestart({ id: r.jobId, total: r.total, target: retryTarget, changes: job.changes }),
  })
  return (
    <span className="flex items-center gap-2 text-sm" role="status">
      {failed.length > 0 || lost ? <CircleAlert className="size-4 shrink-0" /> : finished ? <CheckCircle2 className="size-4 shrink-0" /> : <Loader2 className="size-4 shrink-0 animate-spin" />}
      {lost
        ? t("bulk.lost")
        : finished
          ? deleting
            ? t("bulk.deleted", { done: formatNumber(data.done - data.errors.length), errors: data.errors.length })
            : t("bulk.done", { done: formatNumber(data.done - data.errors.length), errors: data.errors.length })
          : t("bulk.progress", { done: formatNumber(data?.done ?? 0), total: formatNumber(data?.total ?? job.total) })}
      {failed.length > 0 && (
        <details className="relative">
          <summary className="cursor-pointer text-sm underline">{t("bulk.showErrors")}</summary>
          <ul className="absolute right-0 bottom-full mb-2 max-h-60 w-80 overflow-y-auto rounded-md border bg-popover p-2 text-xs shadow-md eink:border-2">
            {failed.map((e) => (
              <li key={e.bookId}>
                #{e.bookId}: {e.error}
              </li>
            ))}
          </ul>
        </details>
      )}
      {failed.length > 0 && (
        <Button variant="outline" size="sm" onClick={() => retry.mutate()} disabled={retry.isPending}>
          {t("bulk.retry", { count: failed.length })}
        </Button>
      )}
      {(finished || lost) && (
        <Button variant="ghost" size="sm" onClick={onClose}>
          OK
        </Button>
      )}
    </span>
  )
}
