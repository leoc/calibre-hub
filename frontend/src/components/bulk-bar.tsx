import { useEffect, useState } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { CheckCircle2, CircleAlert, ListMinus, Loader2, X } from "lucide-react"
import { ApiError, DEFAULT_CONFIG, write, type BulkTarget, type ReadingList } from "@/lib/api"
import { refreshPrivateTags } from "@/lib/run-action"
import { useIsAdmin } from "@/lib/session"
import { BOOK_ACTIONS, bookAction, commandLabel, needsConfirm, type ActionTarget, type BookActionDef } from "@/lib/book-actions"
import { isBulkJob, trackedJobs, useTrackedJobs, type TrackedJob } from "@/lib/jobs"
import { startChange } from "@/lib/run-action"
import { jobQuery } from "./job-watcher"
import { findNode, listLabel, listsQuery, offerUndoRemove, savableLists, useBulkList, useListTree } from "@/lib/lists"
import { NewListInline } from "./lists"
import { categorySuggestions, parseCategory } from "@/lib/kategorie"
import { categoriesQuery, configQuery } from "@/lib/queries"
import { bulkTarget, type LibrarySearch } from "@/lib/search"
import { onBulkRequest, selection, useSelection, type BulkAction } from "@/lib/selection"
import { formatNumber, t } from "@/i18n"
import { Button } from "./ui/button"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "./ui/dialog"
import { ChipsInput, Combobox } from "./ui/suggest"

type Action = BulkAction
// the bar's buttons, from the one list of commands on books
const BAR = BOOK_ACTIONS.filter((a) => a.bar)

export function BulkBar({ search, pageIds, total }: { search: LibrarySearch; pageIds: number[]; total: number }) {
  const sel = useSelection()
  const { data: config = DEFAULT_CONFIG } = useQuery(configQuery)
  const [action, setAction] = useState<Action | null>(null)
  // the newest edit or delete, also one started from the palette
  const job = useTrackedJobs().filter((j) => isBulkJob(j) && !j.dismissed).at(-1) ?? null
  // what finished while the bar was away is no news
  useEffect(() => trackedJobs.dropFinished, [])
  const [listAction, setListAction] = useState<"add" | "remove" | null>(null)
  // the outcome of a list change, shown until the search changes
  const [listResult, setListResult] = useState<{ text: string; key: string } | null>(null)
  const bulkList = useBulkList()
  const qc = useQueryClient()
  // a reader changes only their own lists and private tags
  const admin = useIsAdmin()
  const [privateAction, setPrivateAction] = useState<"add" | "remove" | null>(null)
  const count = sel.all ? total : sel.ids.size
  const { tree, user } = useListTree(search.list != null)
  const node = tree && findNode(tree, search, user)
  const hasSublists = !!node?.children.length
  // a magic shelf has no books of its own to remove
  const inShelf = !!node?.list?.rule
  // "all matches" belongs to one search
  const key = JSON.stringify({ ...search, page: undefined, book: undefined, edit: undefined })
  const listDone = listResult?.key === key ? listResult.text : null
  const setListDone = (text: string | null) => setListResult(text ? { text, key } : null)
  useEffect(() => {
    if (sel.all) selection.clear()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key])
  // the Delete key with books selected
  useEffect(() => (admin ? onBulkRequest(setAction) : undefined), [admin])

  // ids keep the order they were selected in (numbering a series)
  const target: BulkTarget = sel.all ? bulkTarget(search, config.categoryColumn, total) : { ids: [...sel.ids] }

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
      {listDone ? (
        <span className="flex items-center gap-2 text-sm" role="status">
          <CheckCircle2 className="size-4 shrink-0" /> {listDone}
          <Button variant="ghost" size="sm" onClick={() => setListDone(null)}>
            OK
          </Button>
        </span>
      ) : job ? (
        // no overflow here: the error list opens above the bar
        <div className="flex flex-wrap items-center gap-2">
          <JobProgress job={job} onClose={() => trackedJobs.dismiss(job.id)} />
        </div>
      ) : (
        <div className={row}>
          {admin &&
            BAR.filter((a) => a.group === "edit").map((a) => (
              <Button key={a.id} variant="outline" size="sm" disabled={!count} onClick={() => setAction(a.id as Action)}>
                {t(a.bar!)}
              </Button>
            ))}
          <BarButton def={bookAction("addPrivateTags")} disabled={!count} onClick={() => setPrivateAction("add")} />
          <BarButton def={bookAction("removePrivateTags")} disabled={!count} onClick={() => setPrivateAction("remove")} />
          <BarButton def={bookAction("addToList")} disabled={!count} onClick={() => setListAction("add")} />
          {/* on a list with its sublists' books the removal would miss those: then the dialog */}
          {search.list != null && !inShelf && (search.direct || !hasSublists) ? (
            <Button
              variant="outline"
              size="sm"
              disabled={!count || bulkList.isPending}
              // no confirmation: the toast offers to undo it
              onClick={() =>
                bulkList.mutate(
                  { listId: search.list!, target, remove: true },
                  { onSuccess: (r) => (offerUndoRemove(qc, r.list, r.removed ?? []), selection.clear()) },
                )
              }
            >
              <ListMinus /> {t("bulk.removeFromThis")}
            </Button>
          ) : (
            <BarButton def={bookAction("removeFromList")} disabled={!count} onClick={() => setListAction("remove")} />
          )}
          {admin && <BarButton def={bookAction("delete")} disabled={!count} onClick={() => setAction("delete")} />}
        </div>
      )}
      {action && <BulkDialog action={action} count={count} target={target} onClose={() => setAction(null)} />}
      {privateAction && (
        <BulkPrivateTagsDialog remove={privateAction === "remove"} count={count} target={target} onClose={() => setPrivateAction(null)} onDone={(text) => (setListDone(text), void refreshPrivateTags(qc))} />
      )}
      {listAction && <BulkListDialog remove={listAction === "remove"} count={count} target={target} onClose={() => setListAction(null)} onDone={setListDone} />}
    </div>
  )
}

function BarButton({ def, disabled, onClick }: { def: BookActionDef; disabled: boolean; onClick: () => void }) {
  const Icon = def.icon
  return (
    <Button variant="outline" size="sm" disabled={disabled} onClick={onClick}>
      <Icon /> {t(def.bar!)}
    </Button>
  )
}

// Adds the selection to a list (or a new one), or removes it from one
function BulkListDialog({
  remove,
  count,
  target,
  onClose,
  onDone,
}: {
  remove: boolean
  count: number
  target: BulkTarget
  onClose: () => void
  onDone: (message: string) => void
}) {
  const { data: lists } = useQuery(listsQuery)
  const bulkList = useBulkList()
  const [picked, setPicked] = useState<number | null>(null)
  const editable = savableLists(lists).sort((a, b) => listLabel(a).localeCompare(listLabel(b), "de", { sensitivity: "base", numeric: true }))
  const run = (list: ReadingList) =>
    bulkList.mutate(
      { listId: list.id, target, remove },
      {
        onSuccess: (r) => {
          const n = formatNumber((r.added ?? r.removed ?? []).length)
          onDone(t(remove ? "bulk.listRemoved" : "bulk.listAdded", { count: n, name: listLabel(r.list) }))
          onClose()
        },
      },
    )
  const list = editable.find((l) => l.id === picked)
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent aria-describedby={undefined} className="sm:max-w-sm">
        <DialogTitle className="text-lg font-semibold">
          {t(remove ? "bulk.removeFromList" : "bulk.addToList")} · {t("bulk.selected", { count: formatNumber(count) })}
        </DialogTitle>
        <ul role="radiogroup" aria-label={t("bulk.listPick")} className="-mx-2 max-h-[50vh] overflow-y-auto">
          {editable.map((l) => (
            <li key={l.id}>
              <label className="flex min-h-9 cursor-pointer items-center gap-3 rounded-sm px-2 py-1 hover:bg-accent eink:min-h-12 touch:min-h-11">
                <input type="radio" name="bulk-list" checked={picked === l.id} onChange={() => setPicked(l.id)} className="size-4 eink:size-6" />
                <span className="min-w-0 flex-1 truncate">{listLabel(l)}</span>

                <span className="text-xs text-muted-foreground tabular-nums eink:text-black">{formatNumber(l.count)}</span>
              </label>
            </li>
          ))}
        </ul>
        {!remove && <NewListInline onCreated={run} />}
        {bulkList.error && (
          <p role="alert" className="text-sm text-destructive">
            {bulkList.error instanceof ApiError ? bulkList.error.message : String(bulkList.error)}
          </p>
        )}
        <div className="flex justify-end gap-2">
          <Button variant="outline" onClick={onClose}>
            {t("edit.cancel")}
          </Button>
          <Button onClick={() => list && run(list)} disabled={!list || bulkList.isPending}>
            {t("bulk.apply")}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  )
}

// Adds the user's private tags to the selection, or removes them; at once,
// no job: they live in the hub
function BulkPrivateTagsDialog({
  remove,
  count,
  target,
  onClose,
  onDone,
}: {
  remove: boolean
  count: number
  target: BulkTarget
  onClose: () => void
  onDone: (message: string) => void
}) {
  const { data: cats } = useQuery(categoriesQuery)
  const [tags, setTags] = useState<string[]>([])
  const def = bookAction(remove ? "removePrivateTags" : "addPrivateTags")
  const run = useMutation({
    mutationFn: () => write.privateTags(target, remove ? { remove: tags } : { add: tags }),
    onSuccess: (r) => {
      onDone(t("actions.privateTagsDone", { label: t(def.bar!), count: formatNumber(r.changed.length) }))
      onClose()
    },
  })
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent aria-describedby={undefined}>
        <DialogTitle className="text-lg font-semibold">
          {t(def.bar!)} · {t("bulk.selected", { count: formatNumber(count) })}
        </DialogTitle>
        <ChipsInput aria-label={t("book.privateTags")} value={tags} onChange={setTags} suggestions={cats?.privateTags ?? []} allowNew={!remove} />
        <p className="text-xs text-muted-foreground eink:text-black">{t("book.privateTagsHint")}</p>
        {run.error && (
          <p role="alert" className="text-sm text-destructive">
            {run.error instanceof ApiError ? run.error.message : String(run.error)}
          </p>
        )}
        <div className="flex justify-end gap-2">
          <Button variant="outline" onClick={onClose}>
            {t("edit.cancel")}
          </Button>
          <Button onClick={() => run.mutate()} disabled={!tags.length || run.isPending}>
            {t("bulk.apply")}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  )
}

function BulkDialog({
  action,
  count,
  target,
  onClose,
}: {
  action: Action
  count: number
  target: BulkTarget
  onClose: () => void
}) {
  const { data: cats } = useQuery(categoriesQuery)
  const [tags, setTags] = useState<string[]>([])
  const [text, setText] = useState("")
  const [confirming, setConfirming] = useState(false)
  // numbering needs an order, which only explicitly selected books have
  const canNumber = "ids" in target
  const [numberSeries, setNumberSeries] = useState(false)
  const on: ActionTarget = { bulk: target, count, ordered: canNumber }
  // the same definitions as the palette's commands
  const def = bookAction(action === "series" && numberSeries && canNumber && text.trim() ? "seriesNumbered" : action)
  const start = useMutation({
    mutationFn: ({ value, label }: { value: string | string[] | null; label: string }) => startChange(def, on, value, label),
    onSuccess: onClose,
  })
  const kategorie = parseCategory(text)
  const kategorieError = action === "kategorie" && "error" in kategorie ? t("kategorie.dot", { name: kategorie.error }) : null
  const series = text.trim() || null
  const value =
    action === "delete" ? null : action === "addTags" || action === "removeTags" ? tags : action === "kategorie" ? ("value" in kategorie ? kategorie.value : null) : series
  // "Tags hinzufügen (3)", "Serie ‚Dune‘ setzen (3)" in the toasts
  const label = commandLabel(def, on, typeof value === "string" ? { value, label: action === "kategorie" ? text.trim() : value } : undefined)
  const empty = (action === "addTags" || action === "removeTags") && !tags.length
  const submit = () => {
    if (kategorieError) return
    // deleting asks in the dialog itself
    if (action !== "delete" && needsConfirm(def, on) && !confirming) return setConfirming(true)
    start.mutate({ value, label })
  }
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent {...(action === "delete" ? {} : { "aria-describedby": undefined })}>
        <DialogTitle className="text-lg font-semibold">
          {t(bookAction(action).bar!)} · {t("bulk.selected", { count: formatNumber(count) })}
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

// Progress of the newest edit or delete; <JobWatcher> refreshes the library
// and shows the toast with "Rückgängig"
function JobProgress({ job, onClose }: { job: TrackedJob; onClose: () => void }) {
  const { data, error } = useQuery(jobQuery(job.id))
  const finished = data && data.status !== "running"
  const deleting = job.kind === "delete"
  // 404: the hub restarted and forgot the job
  const lost = error instanceof ApiError && error.status === 404
  const failed = finished ? data.errors : []
  // e.g. calibre-server restarted mid-job: run the same change on the failed
  // books; numbering needs the whole selection again to count right
  const retryTarget: BulkTarget = job.changes?.numberSeries && job.target ? job.target : { ids: failed.map((e) => e.bookId) }
  const retry = useMutation({
    mutationFn: () => write.bulk(retryTarget, job.changes ?? {}),
    onSuccess: (r) => {
      trackedJobs.dismiss(job.id)
      trackedJobs.add({ ...job, id: r.jobId, total: r.total, target: retryTarget, finished: false, dismissed: false })
    },
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
      {/* an undo has no change to retry: what it left changed since */}
      {failed.length > 0 && job.changes && (
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
