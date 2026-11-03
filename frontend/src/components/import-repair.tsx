import { useState } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { importRepairQuery } from "@/lib/queries"
import { write, type ImportRepairEntry, type ImportRepairReview } from "@/lib/api"
import { fieldLabel, formatValue, sourceLabel } from "@/lib/metadata"
import type { MetadataField } from "@/lib/api"
import { formatNumber, t } from "@/i18n"
import { Button } from "@/components/ui/button"
import { cn } from "@/lib/utils"

const muted = "text-muted-foreground eink:text-black"
const n = (v: number | undefined | null) => formatNumber(v ?? 0)

// who decided an unclear file name: the name, the folder, the file, a
// metadata source, the model, or nobody (the unsure tag)
export function decidedLabel(by: string | null, unsureTag: string): string {
  if (!by || by === "name") return t("repair.decided.name")
  if (by === "folder") return t("repair.decided.folder")
  if (by === "unsure") return t("repair.decided.unsure", { tag: unsureTag })
  const key = sourceLabel(by)
  return key ? t(key) : by
}

// The repair of plain-file imports on the import page: plan proposals (a
// job), then review them per book (old → new, who decided) and accept or
// reject single books, the selected ones or all
export function ImportRepair() {
  const qc = useQueryClient()
  const { data } = useQuery(importRepairQuery)
  const [selected, setSelected] = useState<Set<number>>(new Set())
  const refresh = () => qc.invalidateQueries({ queryKey: importRepairQuery.queryKey })
  const plan = useMutation({ mutationFn: write.planImportRepair, onSettled: refresh })
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
  if (!data) return null
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
        <Button variant="outline" disabled={busy} onClick={() => plan.mutate()}>
          {t("repair.plan")}
        </Button>
        {data.entries.length > 0 && (
          <>
            <Button disabled={busy} onClick={() => accept.mutate(undefined)}>
              {t("repair.acceptAll")}
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
      {data.entries.length === 0 ? (
        !running && <p className="text-sm">{t("repair.none")}</p>
      ) : (
        <ul className="divide-y border-y eink:divide-y-2 eink:border-y-2" aria-label={t("repair.title")}>
          {data.entries.map((e) => (
            <RepairItem
              key={e.bookId}
              entry={e}
              title={data.books.find((b) => b.id === e.bookId)?.title}
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
    </section>
  )
}

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
  const title = props.title ?? `#${e.bookId}`
  return (
    <li className="space-y-1 py-2 text-sm" data-book={e.bookId}>
      <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
        <label className="inline-flex min-h-9 items-center gap-2 font-medium eink:min-h-12 touch:min-h-11">
          <input type="checkbox" className="size-4 eink:size-6" checked={props.checked} onChange={props.onToggle} aria-label={t("repair.select", { title })} />
          {title}
        </label>
        <span className={muted}>{t("repair.decided", { by: decidedLabel(e.decided, props.unsureTag) })}</span>
      </div>
      <p className={cn("break-all", muted)}>{name}</p>
      <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-0.5">
        {e.changes.map((c) => (
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
