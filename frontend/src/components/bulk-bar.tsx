import { useEffect, useState } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { CheckCircle2, Loader2, X } from "lucide-react"
import { ApiError, write, type BulkChanges, type BulkTarget } from "@/lib/api"
import { categoriesQuery } from "@/lib/queries"
import { flattenTree } from "@/lib/palette"
import { toBookQuery, type LibrarySearch } from "@/lib/search"
import { selection, useSelection } from "@/lib/selection"
import { formatNumber, t } from "@/i18n"
import { Button } from "./ui/button"
import { Dialog, DialogContent, DialogTitle } from "./ui/dialog"
import { ChipsInput, Combobox } from "./ui/suggest"

type Action = "addTags" | "removeTags" | "kategorie" | "series"
const CONFIRM_ABOVE = 50

export function BulkBar({ search, pageIds, total }: { search: LibrarySearch; pageIds: number[]; total: number }) {
  const sel = useSelection()
  const [action, setAction] = useState<Action | null>(null)
  const [job, setJob] = useState<{ id: string; total: number } | null>(null)
  const count = sel.all ? total : sel.ids.size
  // "all matches" belongs to one search
  const key = JSON.stringify({ ...search, page: undefined, book: undefined, edit: undefined })
  useEffect(() => {
    if (sel.all) selection.clear()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key])

  const { page: _p, book: _b, edit: _e, ...filters } = search
  const { offset: _o, limit: _l, ...query } = toBookQuery(filters)
  const target: BulkTarget = sel.all ? { query } : { ids: [...sel.ids] }

  return (
    <div className="sticky bottom-0 z-20 -mx-4 flex flex-wrap items-center gap-2 border-t bg-background px-4 py-3 shadow-[0_-4px_12px_rgba(0,0,0,0.06)] lg:-mx-6 lg:px-6 eink:border-t-2 eink:shadow-none">
      <span className="text-sm font-medium tabular-nums">{t("bulk.selected", { count: formatNumber(count) })}</span>
      <Button variant="ghost" size="sm" onClick={() => selection.addPage(pageIds)}>
        {t("bulk.page")}
      </Button>
      {total > pageIds.length && (
        <Button variant="ghost" size="sm" onClick={selection.selectAll} aria-pressed={sel.all}>
          {t("bulk.all", { count: formatNumber(total) })}
        </Button>
      )}
      {count > 0 && (
        <Button variant="ghost" size="sm" onClick={selection.clear}>
          {t("bulk.none")}
        </Button>
      )}
      <span className="flex-1" />
      {job ? (
        <JobProgress job={job} onClose={() => setJob(null)} />
      ) : (
        <>
          {(["addTags", "removeTags", "kategorie", "series"] as Action[]).map((a) => (
            <Button key={a} variant="outline" size="sm" disabled={!count} onClick={() => setAction(a)}>
              {t(`bulk.${a}`)}
            </Button>
          ))}
        </>
      )}
      <Button variant="ghost" size="icon" onClick={selection.stop} aria-label={t("bulk.stop")} title={t("bulk.stop")}>
        <X />
      </Button>
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
  onStarted: (job: { id: string; total: number }) => void
}) {
  const { data: cats } = useQuery(categoriesQuery)
  const [tags, setTags] = useState<string[]>([])
  const [text, setText] = useState("")
  const [confirming, setConfirming] = useState(false)
  const start = useMutation({
    mutationFn: (changes: BulkChanges) => write.bulk(target, changes),
    onSuccess: (r) => {
      onStarted({ id: r.jobId, total: r.total })
      onClose()
    },
  })
  const changes: BulkChanges =
    action === "addTags"
      ? { addTags: tags }
      : action === "removeTags"
        ? { removeTags: tags }
        : action === "kategorie"
          ? { kategorie: text.trim() ? text.trim().replace(/\s*[›.]\s*/g, ".") : null }
          : { series: text.trim() || null }
  const empty = (action === "addTags" || action === "removeTags") && !tags.length
  const submit = () => {
    if (count > CONFIRM_ABOVE && !confirming) return setConfirming(true)
    start.mutate(changes)
  }
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent aria-describedby={undefined}>
        <DialogTitle className="text-lg font-semibold">
          {t(`bulk.${action}`)} · {t("bulk.selected", { count: formatNumber(count) })}
        </DialogTitle>
        {action === "addTags" || action === "removeTags" ? (
          <ChipsInput aria-label={t("book.tags")} value={tags} onChange={setTags} suggestions={cats?.tags ?? []} allowNew={action === "addTags"} />
        ) : (
          <>
            <Combobox
              aria-label={t(action === "kategorie" ? "book.kategorie" : "book.series")}
              value={text}
              onChange={setText}
              suggestions={action === "kategorie" ? flattenTree(cats?.kategorie ?? []).map((k) => ({ ...k, name: k.name.replaceAll(".", " › ") })) : (cats?.series ?? [])}
            />
            <p className="text-xs text-muted-foreground eink:text-black">{t(action === "kategorie" ? "bulk.kategorieHint" : "bulk.seriesHint")}</p>
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
          <Button onClick={submit} disabled={empty || start.isPending} variant={confirming ? "default" : "default"}>
            {confirming ? t("bulk.confirm", { count: formatNumber(count) }) : t("bulk.apply")}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  )
}

function JobProgress({ job, onClose }: { job: { id: string; total: number }; onClose: () => void }) {
  const qc = useQueryClient()
  const { data, error } = useQuery({
    queryKey: ["job", job.id],
    queryFn: () => write.job(job.id),
    refetchInterval: (q) => (q.state.data?.status === "running" || !q.state.data ? 700 : false),
    retry: false,
  })
  const finished = data && data.status !== "running"
  useEffect(() => {
    if (finished) {
      qc.invalidateQueries({ queryKey: ["books"] })
      qc.invalidateQueries({ queryKey: ["book"] })
      qc.invalidateQueries({ queryKey: ["categories"] })
    }
  }, [finished, qc])
  // 404: the hub restarted and forgot the job
  const lost = error instanceof ApiError && error.status === 404
  return (
    <span className="flex items-center gap-2 text-sm" role="status">
      {finished || lost ? <CheckCircle2 className="size-4" /> : <Loader2 className="size-4 animate-spin" />}
      {lost
        ? t("bulk.lost")
        : finished
          ? t("bulk.done", { done: formatNumber(data.done), errors: data.errors.length })
          : t("bulk.progress", { done: formatNumber(data?.done ?? 0), total: formatNumber(data?.total ?? job.total) })}
      {(finished || lost) && (
        <Button variant="ghost" size="sm" onClick={onClose}>
          OK
        </Button>
      )}
    </span>
  )
}
