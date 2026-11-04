import { useMemo, useState } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { importRepairQuery } from "@/lib/queries"
import { write, type ConfidenceBand, type ImportRepairEntry, type ImportRepairReview, type RepairNote } from "@/lib/api"
import { fieldLabel, formatValue, sourceLabel } from "@/lib/metadata"
import type { MetadataField } from "@/lib/api"
import { formatNumber, t } from "@/i18n"
import { Button } from "@/components/ui/button"
import { cn } from "@/lib/utils"

const muted = "text-muted-foreground eink:text-black"
const n = (v: number | undefined | null) => formatNumber(v ?? 0)
const select = "min-h-9 rounded-md border bg-background px-2 text-sm eink:min-h-12 eink:border-2 touch:min-h-11"
// entries on the page at a time: a whole library has thousands
const PAGE = 100

export const BANDS: ConfidenceBand[] = ["bulk", "review", "unsure"]
const LEVELS = [1, 2, 3] as const
type Sort = "sure" | "unsure" | "book"

export const bandLabel = (band: ConfidenceBand) =>
  t(band === "bulk" ? "repair.band.bulk" : band === "review" ? "repair.band.review" : "repair.band.unsure")
export const levelLabel = (level: 1 | 2 | 3) => t(level === 1 ? "repair.level.1" : level === 2 ? "repair.level.2" : "repair.level.3")

// who decided an unclear file name: the name, the folder, the file, a
// metadata source, the model, or nobody (the unsure tag)
export function decidedLabel(by: string | null, unsureTag: string): string {
  if (!by || by === "name") return t("repair.decided.name")
  if (by === "folder") return t("repair.decided.folder")
  if (by === "calibre") return t("repair.decided.calibre")
  if (by === "unsure") return t("repair.decided.unsure", { tag: unsureTag })
  const key = sourceLabel(by)
  return key ? t(key) : by
}

const sourceName = (source: string) => {
  const key = sourceLabel(source)
  return key ? t(key) : source
}

// the entries of a filter, in the order chosen; without a value last
function visible(entries: ImportRepairEntry[], band: ConfidenceBand | "all", level: string, sort: Sort) {
  const list = entries.filter((e) => (band === "all" || e.band === band) && (level === "all" || String(e.level) === level))
  const value = (e: ImportRepairEntry) => e.confidence ?? -1
  if (sort === "sure") list.sort((a, b) => value(b) - value(a) || a.bookId - b.bookId)
  if (sort === "unsure") list.sort((a, b) => value(a) - value(b) || a.bookId - b.bookId)
  return list
}

// The repair on the import page: plan proposals (a job, of the suspicious
// books or the whole library), then review them per book (old → new, who
// decided, how sure) by band and level, and accept or reject single books,
// the selected ones or the bulk band
export function ImportRepair() {
  const qc = useQueryClient()
  const { data } = useQuery(importRepairQuery)
  const [selected, setSelected] = useState<Set<number>>(new Set())
  const [band, setBand] = useState<ConfidenceBand | "all">("all")
  const [level, setLevel] = useState("all")
  const [sort, setSort] = useState<Sort>("sure")
  const [limit, setLimit] = useState(PAGE)
  const refresh = () => qc.invalidateQueries({ queryKey: importRepairQuery.queryKey })
  const plan = useMutation({ mutationFn: (library: boolean) => write.planImportRepair(library), onSettled: refresh })
  const accept = useMutation({
    mutationFn: (ids?: number[]) => write.acceptImportRepair(ids),
    onSettled: () => {
      setSelected(new Set())
      refresh()
    },
  })
  const reject = useMutation({
    mutationFn: (ids?: number[]) => write.rejectImportRepair(ids),
    onSettled: () => {
      setSelected(new Set())
      refresh()
    },
  })
  const entries = useMemo(() => visible(data?.entries ?? [], band, level, sort), [data?.entries, band, level, sort])
  const titles = useMemo(() => new Map(data?.books.map((b) => [b.id, b.title])), [data?.books])
  if (!data) return null
  const bulk = data.entries.filter((e) => e.band === "bulk").length
  const running = data.job?.status === "running"
  const busy = running || plan.isPending || accept.isPending || reject.isPending
  const ids = [...selected].filter((id) => data.entries.some((e) => e.bookId === id))
  const toggle = (id: number) =>
    setSelected((s) => {
      const next = new Set(s)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  return (
    <section className="space-y-3" aria-labelledby="import-repair">
      <h2 id="import-repair" className="text-lg font-semibold">
        {t("repair.title")}
      </h2>
      <p className={cn("text-sm", muted)}>{t("repair.hint")}</p>
      <RepairState review={data} />
      <div className="flex flex-wrap gap-2">
        <Button variant="outline" disabled={busy} onClick={() => plan.mutate(false)}>
          {t("repair.plan")}
        </Button>
        <Button variant="outline" disabled={busy} onClick={() => plan.mutate(true)}>
          {t("repair.planLibrary")}
        </Button>
        {data.entries.length > 0 && (
          <>
            <Button disabled={busy || bulk === 0} onClick={() => accept.mutate(undefined)}>
              {t("repair.acceptBulk", { count: n(bulk) })}
            </Button>
            <Button variant="secondary" disabled={busy || ids.length === 0} onClick={() => accept.mutate(ids)}>
              {t("repair.acceptSelected", { count: n(ids.length) })}
            </Button>
            <Button variant="outline" disabled={busy || ids.length === 0} onClick={() => reject.mutate(ids)}>
              {t("repair.rejectSelected", { count: n(ids.length) })}
            </Button>
          </>
        )}
      </div>
      {data.entries.length > 0 && (
        <div className="flex flex-wrap gap-3 text-sm">
          <label className="inline-flex items-center gap-2">
            {t("repair.band")}
            <select className={select} value={band} onChange={(e) => setBand(e.target.value as ConfidenceBand | "all")}>
              <option value="all">{t("repair.band.all")}</option>
              {BANDS.map((b) => (
                <option key={b} value={b}>
                  {bandLabel(b)}
                </option>
              ))}
            </select>
          </label>
          <label className="inline-flex items-center gap-2">
            {t("repair.level")}
            <select className={select} value={level} onChange={(e) => setLevel(e.target.value)}>
              <option value="all">{t("repair.level.all")}</option>
              {LEVELS.map((l) => (
                <option key={l} value={l}>
                  {levelLabel(l)}
                </option>
              ))}
            </select>
          </label>
          <label className="inline-flex items-center gap-2">
            {t("repair.sort")}
            <select className={select} value={sort} onChange={(e) => setSort(e.target.value as Sort)}>
              <option value="sure">{t("repair.sort.sure")}</option>
              <option value="unsure">{t("repair.sort.unsure")}</option>
              <option value="book">{t("repair.sort.book")}</option>
            </select>
          </label>
        </div>
      )}
      {data.entries.length === 0 ? (
        !running && <p className="text-sm">{t("repair.none")}</p>
      ) : (
        <ul className="divide-y border-y eink:divide-y-2 eink:border-y-2" aria-label={t("repair.title")}>
          {entries.slice(0, limit).map((e) => (
            <RepairItem
              key={e.bookId}
              entry={e}
              title={titles.get(e.bookId)}
              unsureTag={data.unsureTag}
              checked={selected.has(e.bookId)}
              busy={busy}
              onToggle={() => toggle(e.bookId)}
              onAccept={() => accept.mutate([e.bookId])}
              onReject={() => reject.mutate([e.bookId])}
            />
          ))}
        </ul>
      )}
      {entries.length > limit && (
        <div className="flex items-center gap-3 text-sm">
          <span className={muted}>{t("repair.shown", { shown: n(limit), total: n(entries.length) })}</span>
          <Button variant="outline" size="sm" onClick={() => setLimit(limit + PAGE)}>
            {t("repair.more")}
          </Button>
        </div>
      )}
    </section>
  )
}

const noteText = (note: RepairNote) =>
  note.kind === "duplicateIsbn"
    ? t("repair.note.duplicateIsbn", { isbn: note.isbn, books: note.books.map((id) => `#${id}`).join(", ") })
    : t("repair.note.isbnConflict", { isbn: note.isbn })

function RepairState({ review }: { review: ImportRepairReview }) {
  const job = review.job
  const c = review.counts
  return (
    <div role="status" className="space-y-1 text-sm tabular-nums">
      {job?.status === "running" && <p>{t("repair.planning", { done: n(job.done), total: n(job.total) })}</p>}
      {job && job.status !== "running" && job.errors.length > 0 && <p>{t("repair.jobErrors", { count: n(job.errors.length) })}</p>}
      <p>{t("repair.counts", { pending: n(c.pending), applied: n(c.applied), rejected: n(c.rejected), failed: n(c.failed) })}</p>
    </div>
  )
}

function RepairItem(props: {
  entry: ImportRepairEntry
  title?: string
  unsureTag: string
  checked: boolean
  busy: boolean
  onToggle: () => void
  onAccept: () => void
  onReject: () => void
}) {
  const { entry: e } = props
  const name = e.file.split("/").pop() ?? e.file
  const changes = e.changes.filter((c) => c.field !== "candidate")
  const candidate = e.changes.find((c) => c.field === "candidate")?.new as { title?: string; authors: string[]; source: string } | undefined
  const title = props.title ?? `#${e.bookId}`
  return (
    <li className="space-y-1 py-2 text-sm" data-book={e.bookId}>
      <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
        <label className="inline-flex min-h-9 items-center gap-2 font-medium eink:min-h-12 touch:min-h-11">
          <input type="checkbox" className="size-4 eink:size-6" checked={props.checked} onChange={props.onToggle} aria-label={t("repair.select", { title })} />
          {title}
        </label>
        <span className={muted}>{t("repair.decided", { by: decidedLabel(e.decided, props.unsureTag) })}</span>
        <span className={cn("tabular-nums", muted)}>
          {e.confidence !== null && e.level !== null ? t("repair.confidence", { value: n(e.confidence), level: levelLabel(e.level) }) : t("repair.confidence.none")}
        </span>
      </div>
      {e.notes.map((note) => (
        <p key={note.kind} className="font-medium">
          {noteText(note)}
        </p>
      ))}
      {name && <p className={cn("break-all", muted)}>{name}</p>}
      <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-0.5">
        {changes.map((c) => (
          <div key={c.field} className="contents">
            <dt className="font-medium">{fieldLabel(c.field)}</dt>
            <dd className="break-words">
              <span className="line-through decoration-1 eink:no-underline">{formatValue(c.field as MetadataField, c.old)}</span>
              {" → "}
              <span>{formatValue(c.field as MetadataField, c.new)}</span>
            </dd>
          </div>
        ))}
      </dl>
      {candidate && (
        <p className={muted}>
          {t("repair.candidate", { title: candidate.title ?? title, authors: candidate.authors.join(", "), source: sourceName(candidate.source) })}
        </p>
      )}
      <div className="flex gap-2">
        <Button size="sm" disabled={props.busy} onClick={props.onAccept}>
          {t("repair.accept")}
        </Button>
        <Button size="sm" variant="outline" disabled={props.busy} onClick={props.onReject}>
          {t("repair.reject")}
        </Button>
      </div>
    </li>
  )
}
