import { useState } from "react"
import { useQuery } from "@tanstack/react-query"
import { getRouteApi, Link } from "@tanstack/react-router"
import { ArrowLeft, CheckCircle2, CopyCheck, Merge as MergeIcon, RotateCcw, X } from "lucide-react"
import { ApiError, DEFAULT_CONFIG } from "@/lib/api"
import { configQuery } from "@/lib/queries"
import {
  compareRows,
  duplicatesQuery,
  groupReasons,
  mergesQuery,
  planLines,
  planQuery,
  reasonLabel,
  useIgnore,
  useMerge,
  useUndoMerge,
  type DuplicateGroup,
  type Merge,
} from "@/lib/duplicates"
import { toast } from "@/lib/toast"
import { formatNumber, locale, t } from "@/i18n"
import { cn } from "@/lib/utils"
import { Badge } from "@/components/ui/badge"
import { Button, buttonVariants } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { BookCover } from "@/components/book-cover"
import { ErrorMessage } from "@/components/error-view"
import { LibraryLink } from "@/components/library-link"

const errorText = (e: unknown) => (e instanceof ApiError ? (e.status === 409 ? t("dup.conflict") : e.message) : String(e))
const dateTime = (iso: string) => new Date(iso).toLocaleString(locale, { dateStyle: "medium", timeStyle: "short" })
const THRESHOLDS = [0.7, 0.8, 0.85, 0.9, 0.95, 1]
const tapLink = "underline-offset-2 hover:underline eink:inline-flex eink:min-h-11 eink:items-center touch:inline-flex touch:min-h-11 touch:items-center"

// Books that look like the same book, side by side; one stays, the others
// are merged into it and go to the trash. Every merge can be undone.
const route = getRouteApi("/_app/duplicates")

export function DuplicatesPage() {
  const [threshold, setThreshold] = useState<number | undefined>(undefined)
  const { data: all, error, refetch, isFetching } = useQuery(duplicatesQuery(threshold))
  // "Auf Duplikate prüfen" from the palette: the groups of these books
  const { ids } = route.useSearch()
  const only = ids ? new Set(ids.split(",").map(Number)) : null
  const data = all && only ? { ...all, groups: all.groups.filter((g) => g.bookIds.some((id) => only.has(id))) } : all
  const [done, setDone] = useState<{ merge: Merge; title: string } | null>(null)
  const shown = threshold ?? data?.threshold

  return (
    <div className="mx-auto max-w-5xl space-y-5 p-4 lg:p-6">
      <LibraryLink search={{}} className={buttonVariants({ variant: "ghost", className: "-ml-2" })}>
        <ArrowLeft /> {t("book.back")}
      </LibraryLink>
      <div className="space-y-1">
        <h1 className="text-2xl font-semibold">{t("dup.title")}</h1>
        <p className="text-sm text-muted-foreground eink:text-black">{t("dup.hint")}</p>
      </div>
      <div className="flex flex-wrap items-center gap-x-4 gap-y-2">
        <label className="flex items-center gap-2 text-sm eink:min-h-11 touch:min-h-11">
          {t("dup.threshold")}
          <select
            className="h-8 rounded-md border bg-background px-2 text-sm eink:h-11 eink:border-2 eink:border-black touch:h-11"
            value={shown ?? ""}
            onChange={(e) => setThreshold(Number(e.target.value))}
          >
            {shown != null && !THRESHOLDS.includes(shown) && <option value={shown}>{Math.round(shown * 100)} %</option>}
            {THRESHOLDS.map((x) => (
              <option key={x} value={x}>
                {Math.round(x * 100)} %
              </option>
            ))}
          </select>
        </label>
        {data && <span className="text-sm text-muted-foreground eink:text-black">{t("dup.groups", { count: formatNumber(data.groups.length) })}</span>}
      </div>
      {only && (
        <p className="flex flex-wrap items-center gap-2 text-sm" role="status">
          {t("actions.duplicatesFiltered", { count: formatNumber(only.size) })}
          <Link to="/duplicates" search={{}} className={cn("underline", tapLink)}>
            {t("actions.duplicatesAll")}
          </Link>
        </p>
      )}
      {done && <MergedNote done={done} onUndone={() => setDone(null)} />}
      {error && !data ? (
        <ErrorMessage error={error} onRetry={() => refetch()} />
      ) : !data ? (
        <p className="py-12 text-center text-muted-foreground">{t("loading")}</p>
      ) : data.groups.length === 0 ? (
        <p className="py-12 text-center text-lg">{t("dup.empty")}</p>
      ) : (
        <ul className={cn("space-y-6", isFetching && "opacity-70 eink:opacity-100")} aria-label={t("dup.title")}>
          {data.groups.map((g) => (
            <GroupView key={g.id} group={g} onMerged={(merge, title) => setDone({ merge, title })} />
          ))}
        </ul>
      )}
      <RecentMerges />
    </div>
  )
}

function MergedNote({ done, onUndone }: { done: { merge: Merge; title: string }; onUndone: () => void }) {
  const undo = useUndoMerge()
  return (
    <div role="status" className="flex flex-wrap items-start gap-2 rounded-md border p-3 text-sm eink:border-2 eink:text-base">
      <CheckCircle2 className="mt-0.5 size-4 shrink-0" aria-hidden />
      <span className="min-w-0 flex-1">
        {t("dup.merged", { title: done.title, count: formatNumber(done.merge.trashed.length) })}{" "}
        <Link to="/books/$id" params={{ id: done.merge.keepId }} search={{}} className={cn("underline", tapLink)}>
          {t("dup.open")}
        </Link>
      </span>
      <Button size="sm" variant="outline" disabled={undo.isPending} onClick={() => undo.mutate(done.merge.id, { onSuccess: () => (toast.show(t("dup.undone")), onUndone()) })}>
        <RotateCcw /> {t("dup.undo")}
      </Button>
      {undo.error && (
        <p role="alert" className="basis-full text-destructive">
          {t("dup.undoError")}: {errorText(undo.error)}
        </p>
      )}
    </div>
  )
}

function GroupView({ group: g, onMerged }: { group: DuplicateGroup; onMerged: (m: Merge, title: string) => void }) {
  const { data: config = DEFAULT_CONFIG } = useQuery(configQuery)
  const [keep, setKeep] = useState(g.keepId)
  const [confirm, setConfirm] = useState(false)
  const ignore = useIgnore()
  const keeper = g.books.find((d) => d.book.id === keep) ?? g.books[0]
  const title = keeper.book.title
  const rows = compareRows(g, config.categoryColumn)
  const label = t("dup.group", { title })

  return (
    <li aria-label={label} className="space-y-3 rounded-md border p-3 eink:border-2">
      <div className="flex flex-wrap items-center gap-2">
        {g.sure && <Badge>{t("dup.sure")}</Badge>}
        {groupReasons(g).map((r) => (
          <Badge key={`${r.kind}-${r.detail}`} variant="outline">
            {reasonLabel(r)}
          </Badge>
        ))}
      </div>
      {/* the comparison scrolls sideways on its own, the page doesn't */}
      <div className="overflow-x-auto">
        <table className="w-full border-collapse text-sm">
          <thead>
            <tr>
              <th className="w-28" />
              {g.books.map((d) => (
                <th key={d.book.id} scope="col" className={cn("min-w-44 p-2 text-left align-top font-normal", d.book.id === keep && "bg-accent eink:bg-white eink:outline eink:outline-2")}>
                  <div className="flex items-start gap-2">
                    <Link to="/books/$id" params={{ id: d.book.id }} search={{}} className="shrink-0" tabIndex={-1} aria-hidden>
                      <BookCover book={d.book} compact className="w-12" />
                    </Link>
                    <div className="min-w-0 space-y-1">
                      <Link to="/books/$id" params={{ id: d.book.id }} search={{}} className={cn("font-medium", tapLink)}>
                        #{d.book.id}
                      </Link>
                      <div className="flex flex-wrap gap-1">
                        {d.book.id === g.keepId && <Badge variant="secondary">{t("dup.suggested")}</Badge>}
                        {d.broken && <Badge variant="outline">{t("dup.broken")}</Badge>}
                      </div>
                      <label className="flex items-center gap-2 eink:min-h-11 touch:min-h-11">
                        <input
                          type="radio"
                          name={`keep-${g.id}`}
                          className="size-4 eink:size-6"
                          checked={d.book.id === keep}
                          onChange={() => setKeep(d.book.id)}
                          aria-label={`${t("dup.keep")}: #${d.book.id} ${d.book.title}`}
                        />
                        {t("dup.keep")}
                      </label>
                    </div>
                  </div>
                </th>
              ))}
            </tr>
          </thead>
          <tbody className="divide-y eink:divide-y-2">
            {rows.map((r) => (
              <tr key={r.key}>
                <th scope="row" className="p-2 text-left align-top font-normal text-muted-foreground eink:text-black">
                  {r.label}
                </th>
                {r.values.map((v, i) => (
                  <td key={g.books[i].book.id} className={cn("p-2 align-top break-words", r.differs && "font-medium", g.books[i].book.id === keep && "bg-accent/50 eink:bg-white")}>
                    {v}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {ignore.error && (
        <p role="alert" className="text-sm text-destructive">
          {errorText(ignore.error)}
        </p>
      )}
      <div className="flex flex-wrap justify-end gap-2">
        <Button
          variant="outline"
          disabled={ignore.isPending}
          onClick={() =>
            ignore.mutate(
              { bookIds: g.bookIds },
              { onSuccess: () => toast.show(t("dup.ignored"), { label: t("dup.undo"), run: () => ignore.mutate({ bookIds: g.bookIds, undo: true }) }) },
            )
          }
        >
          <X /> {t("dup.ignore")}
        </Button>
        <Button onClick={() => setConfirm(true)}>
          <MergeIcon /> {t("dup.merge")}
        </Button>
      </div>
      {confirm && (
        <MergeDialog
          group={g}
          keepId={keep}
          onClose={() => setConfirm(false)}
          onMerged={(m) => {
            setConfirm(false)
            onMerged(m, title)
          }}
        />
      )}
    </li>
  )
}

function MergeDialog({ group: g, keepId, onClose, onMerged }: { group: DuplicateGroup; keepId: number; onClose: () => void; onMerged: (m: Merge) => void }) {
  const others = g.bookIds.filter((id) => id !== keepId)
  const keeper = g.books.find((d) => d.book.id === keepId)!
  const { data: plan, error } = useQuery(planQuery(keepId, others))
  const merge = useMerge()
  const titleOf = (id: number) => g.books.find((d) => d.book.id === id)?.book.title ?? ""
  const lines = plan ? planLines(plan, titleOf) : []
  return (
    <Dialog open onOpenChange={(o) => !o && !merge.isPending && onClose()}>
      <DialogContent>
        <DialogTitle className="text-lg font-semibold">{t("dup.mergeTitle", { id: keepId })}</DialogTitle>
        <DialogDescription>{t("dup.mergeText", { title: keeper.book.title })}</DialogDescription>
        {error ? (
          <p role="alert" className="text-sm text-destructive">
            {errorText(error)}
          </p>
        ) : !plan ? (
          <p className="text-sm text-muted-foreground">{t("dup.planLoading")}</p>
        ) : (
          <ul className="list-disc space-y-1 pl-5 text-sm" aria-label={t("dup.merge")}>
            {plan.formats.length + plan.fields.length === 0 && plan.coverFrom == null && <li>{t("dup.mergeNothing")}</li>}
            {lines.map((l) => (
              <li key={l}>{l}</li>
            ))}
          </ul>
        )}
        {merge.error && (
          <p role="alert" className="text-sm text-destructive">
            {t("dup.mergeError")}: {errorText(merge.error)}
          </p>
        )}
        <div className="flex justify-end gap-2">
          <Button variant="outline" onClick={onClose} disabled={merge.isPending}>
            {t("edit.cancel")}
          </Button>
          <Button
            disabled={!plan || merge.isPending}
            onClick={() => merge.mutate({ keepId, bookIds: others, lastModified: keeper.book.lastModified }, { onSuccess: ({ merge: m }) => onMerged(m) })}
          >
            <CopyCheck /> {t("dup.merge")}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  )
}

function RecentMerges() {
  const { data } = useQuery(mergesQuery)
  const undo = useUndoMerge()
  if (!data?.length) return null
  return (
    <section className="space-y-2" aria-label={t("dup.recent")}>
      <h2 className="text-lg font-semibold">{t("dup.recent")}</h2>
      {undo.error && (
        <p role="alert" className="text-sm text-destructive">
          {t("dup.undoError")}: {errorText(undo.error)}
        </p>
      )}
      <ul className="divide-y border-y text-sm eink:divide-y-2 eink:border-y-2">
        {data.map((m) => {
          const restored = Object.values(m.restored)
          return (
            <li key={m.id} className="flex flex-wrap items-center gap-3 py-2">
              <div className="min-w-0 flex-1">
                <p>
                  <Link to="/books/$id" params={{ id: m.keepId }} search={{}} className={tapLink}>
                    {t("dup.recentItem", { keep: m.keepId, others: m.otherIds.map((id) => `#${id}`).join(", ") })}
                  </Link>
                </p>
                <p className="text-muted-foreground eink:text-black">
                  {[dateTime(m.at), t(`dup.status.${m.status}`), restored.length ? t("dup.restoredAs", { ids: restored.map((id) => `#${id}`).join(", ") }) : null]
                    .filter(Boolean)
                    .join(" · ")}
                </p>
                {m.errors.map((e) => (
                  <p key={e} className="text-muted-foreground eink:text-black">
                    {e}
                  </p>
                ))}
              </div>
              {m.status !== "undone" && m.status !== "running" && (
                <Button size="sm" variant="outline" disabled={undo.isPending} aria-label={`${t("dup.undo")}: #${m.keepId}`} onClick={() => undo.mutate(m.id, { onSuccess: () => toast.show(t("dup.undone")) })}>
                  <RotateCcw /> {t("dup.undo")}
                </Button>
              )}
            </li>
          )
        })}
      </ul>
    </section>
  )
}
