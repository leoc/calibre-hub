import { useEffect, useMemo, useRef, useState, type KeyboardEvent as ReactKeyEvent, type MouseEvent, type ReactNode } from "react"
import { useInfiniteQuery, useMutation, useQuery, useQueryClient, type InfiniteData } from "@tanstack/react-query"
import { Link } from "@tanstack/react-router"
import { BookIcon, Check, Trash2 } from "lucide-react"
import { ApiError, write, type ConfidenceBand, type IntakeCandidate, type IntakeDecision, type IntakeEntry, type IntakeKind, type IntakeList, type IntakeProgress } from "@/lib/api"
import {
  analysedShare,
  authorsText,
  badgeText,
  candidateSource,
  entryTitle,
  intakeEntryQuery,
  intakeFilter,
  intakeListQuery,
  intakeStatusQuery,
  noteTexts,
  reasonText,
  ringLabel,
  takeable,
  uniqueEntries,
  type IntakeBand,
} from "@/lib/intake"
import { errorText } from "@/lib/run-action"
import { toast } from "@/lib/toast"
import { formatNumber, t } from "@/i18n"
import { cn } from "@/lib/utils"
import { isTyping } from "@/components/keyboard"
import { ErrorMessage } from "@/components/error-view"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { Input } from "@/components/ui/input"
import { Sheet, SheetContent, SheetTitle } from "@/components/ui/sheet"
import { ChipsInput } from "@/components/ui/suggest"

const muted = "text-muted-foreground eink:text-black"
const select = "min-h-9 rounded-md border bg-background px-2 text-sm eink:min-h-12 eink:border-2 touch:min-h-11"
const BAND_COLOR: Record<ConfidenceBand, string> = { bulk: "text-band-bulk", review: "text-band-review", unsure: "text-band-unsure" }

// a link's height where a pen or a finger has to hit it
const linkSize = "inline-flex items-center eink:min-h-12 touch:min-h-11"

// what a decision says beyond itself: one entry's edited title and authors
type Edited = { title?: string; authors?: string[] }

// The Eingang: what the analysis found in the backlog, before anything is in
// the library. Every entry leaves by a decision: at once in the list, in a
// queue on the hub. The list stays where it is while the analysis works; only
// the line under the title moves.
export function IntakePage() {
  const qc = useQueryClient()
  const [band, setBand] = useState<IntakeBand>("all")
  const [kind, setKind] = useState<IntakeKind>("all")
  const [open, setOpen] = useState<number | null>(null)
  const [asking, setAsking] = useState(false)
  // decided, gone from the list; with the error it had, a new one brings it back
  const [decided, setDecided] = useState<Map<number, string | null>>(new Map())
  const { data: status, error, refetch: retry, dataUpdatedAt } = useQuery(intakeStatusQuery(band, kind))
  const list = useInfiniteQuery({ ...intakeListQuery(band, kind), enabled: status?.enabled === true })
  const { hasNextPage, isFetchingNextPage, fetchNextPage, refetch } = list
  const loaded = useMemo(() => uniqueEntries(list.data?.pages ?? []), [list.data])
  const entries = useMemo(() => loaded.filter((e) => !decided.has(e.id) || (e.error != null && e.error !== decided.get(e.id))), [loaded, decided])
  const done = status?.progress?.done
  const pending = status?.pending
  // everything loaded: new files join in; else the next page brings them
  useEffect(() => {
    if (done !== undefined && !hasNextPage) void refetch()
    // eslint-disable-next-line react-hooks/exhaustive-deps -- only when the analysis moved on
  }, [done])
  // the queue is through: what failed is back
  const waited = useRef(false)
  useEffect(() => {
    if (pending === 0 && waited.current) {
      waited.current = false
      void refetch()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- only when the hub answered
  }, [dataUpdatedAt])
  const index = entries.findIndex((e) => e.id === open)
  // j reaches the end of what is loaded without waiting there
  useEffect(() => {
    if (index >= 0 && index >= entries.length - 2 && hasNextPage && !isFetchingNextPage) void fetchNextPage()
  }, [index, entries.length, hasNextPage, isFetchingNextPage, fetchNextPage])
  // the row in the drawer stays in sight behind it
  useEffect(() => {
    if (open !== null) document.querySelector(`[data-entry="${open}"]`)?.scrollIntoView({ block: "nearest" })
  }, [open])
  const filter = (next: () => void) => {
    setOpen(null)
    next()
  }
  const refresh = () => qc.invalidateQueries({ queryKey: ["intake-status"] })
  const queued = () => {
    waited.current = true
    return refresh()
  }
  const undecide = (ids: number[]) =>
    setDecided((d) => {
      const next = new Map(d)
      ids.forEach((id) => next.delete(id))
      return next
    })
  const leave = (gone: IntakeEntry[]) =>
    setDecided((d) => {
      const next = new Map(d)
      gone.forEach((e) => next.set(e.id, e.error))
      return next
    })
  const failed = (err: unknown) => toast.show(t("intake.failed", { error: errorText(err) }))
  const decide = useMutation({
    mutationFn: (v: { entry: IntakeEntry; decision: IntakeDecision } & Edited) =>
      write.intakeDecide({ decision: v.decision, target: { ids: [v.entry.id] }, title: v.title, authors: v.authors }),
    onError: (err, v) => {
      undecide([v.entry.id])
      failed(err)
    },
    onSettled: queued,
  })
  const bulk = useMutation({
    mutationFn: (v: { expect: number; last: number; gone: IntakeEntry[] }) =>
      write.intakeDecide({ decision: "accept", target: { query: intakeFilter(band, kind), last: v.last, expect: v.expect } }),
    onError: (err, v) => {
      undecide(v.gone.map((e) => e.id))
      if (err instanceof ApiError && err.status === 409) toast.show(t("intake.changed"))
      else failed(err)
    },
    // the rows behind the loaded ones take their place at once
    onSettled: () => {
      void refetch()
      return queued()
    },
  })
  // a skipped entry stays, the row only says so
  const mark = (id: number, skipped: boolean) =>
    qc.setQueriesData<InfiniteData<IntakeList>>({ queryKey: ["intake-list"] }, (old) =>
      old && { ...old, pages: old.pages.map((p) => ({ ...p, entries: p.entries?.map((e) => (e.id === id ? { ...e, skipped } : e)) })) },
    )
  // the next one to ask: nothing skipped is asked again
  const after = (e: IntakeEntry) => entries.slice(entries.indexOf(e) + 1).find((x) => !x.skipped)?.id ?? null
  const decideOne = (e: IntakeEntry, decision: IntakeDecision, edited: Edited = {}) => {
    if (open === e.id) setOpen(after(e))
    leave([e])
    decide.mutate({ entry: e, decision, ...edited })
  }
  const skip = (e: IntakeEntry) => {
    setOpen(after(e))
    if (e.skipped) return
    mark(e.id, true)
    decide.mutate({ entry: e, decision: "skip" })
  }
  const unskip = (e: IntakeEntry) => {
    mark(e.id, false)
    decide.mutate({ entry: e, decision: "unskip" })
  }
  const acceptAll = () => {
    setAsking(false)
    setOpen(null)
    const gone = entries.filter((e) => takeable(e, kind))
    leave(gone)
    bulk.mutate({ expect: status?.takeable ?? 0, last: status?.last ?? 0, gone })
  }
  const current = index >= 0 ? entries[index] : undefined
  const counts = status?.counts
  const all = counts ? counts.bulk + counts.review + counts.unsure + counts.none : 0
  const shown = list.data?.pages.at(-1)?.total ?? entries.length
  const n = status?.takeable ?? 0
  const unsure = status?.unsure ?? 0
  return (
    <div className="mx-auto max-w-5xl space-y-4 p-4 lg:p-6">
      <div className="space-y-1">
        <h1 className="text-2xl font-semibold">{t("intake.title")}</h1>
        {status?.progress && <IntakeNumbers progress={status.progress} />}
      </div>
      {error && !status ? (
        <ErrorMessage error={error} onRetry={() => retry()} />
      ) : !status ? (
        <p className="py-12 text-center text-muted-foreground">{t("loading")}</p>
      ) : !status.enabled ? (
        <p className="py-12 text-center text-lg">{t("intake.disabled")}</p>
      ) : (
        <>
          <div className="flex flex-wrap items-center gap-3 text-sm">
            <label className="inline-flex items-center gap-2">
              {t("intake.confidence")}
              <select className={select} value={band} onChange={(e) => filter(() => setBand(e.target.value as IntakeBand))}>
                <option value="all">{t("intake.band.all", { count: formatNumber(all) })}</option>
                <option value="bulk">{t("intake.band.bulk", { count: formatNumber(counts?.bulk ?? 0) })}</option>
                <option value="review">{t("intake.band.review", { count: formatNumber(counts?.review ?? 0) })}</option>
                <option value="unsure">{t("intake.band.unsure", { count: formatNumber(counts?.unsure ?? 0) })}</option>
                {!!counts?.none && <option value="none">{t("intake.band.none", { count: formatNumber(counts.none) })}</option>}
              </select>
            </label>
            <label className="inline-flex items-center gap-2">
              {t("intake.kind")}
              <select className={select} value={kind} onChange={(e) => filter(() => setKind(e.target.value as IntakeKind))}>
                <option value="all">{t("intake.kind.all")}</option>
                <option value="new">{t("intake.kind.new")}</option>
                <option value="duplicates">{t("intake.kind.duplicates")}</option>
                {(!!status.skipped || kind === "skipped") && <option value="skipped">{t("intake.kind.skipped", { count: formatNumber(status.skipped ?? 0) })}</option>}
              </select>
            </label>
            <Button className="ml-auto" disabled={n === 0 || bulk.isPending} onClick={() => (unsure > 0 ? setAsking(true) : acceptAll())}>
              {t("intake.acceptAll", { count: formatNumber(n) })}
            </Button>
          </div>
          {list.error ? (
            <ErrorMessage error={list.error} onRetry={() => refetch()} />
          ) : !list.data ? (
            <p className="py-12 text-center text-muted-foreground">{t("loading")}</p>
          ) : entries.length === 0 ? (
            <p className={cn("py-12 text-center text-lg", muted)}>{t("intake.empty")}</p>
          ) : (
            <ul className="divide-y border-y eink:divide-y-2 eink:border-y-2" aria-label={t("intake.title")}>
              {entries.map((e) => (
                <IntakeRow
                  key={e.id}
                  entry={e}
                  same={e.sameAs ? entries.find((x) => x.path === e.sameAs)?.id : undefined}
                  current={e.id === open}
                  onOpen={setOpen}
                  onAccept={() => decideOne(e, "accept")}
                  onTrash={() => decideOne(e, "trash")}
                />
              ))}
            </ul>
          )}
          {hasNextPage && (
            <div className="flex items-center gap-3 text-sm">
              <span className={muted}>{t("intake.shown", { shown: formatNumber(entries.length), total: formatNumber(shown) })}</span>
              <Button variant="outline" size="sm" disabled={isFetchingNextPage} onClick={() => fetchNextPage()}>
                {t("intake.more")}
              </Button>
            </div>
          )}
          <AutoAccept value={status.threshold ?? null} onChanged={refresh} />
          <IntakeSheet
            entry={current}
            onClose={() => setOpen(null)}
            onBack={() => setOpen(entries[index - 1]?.id ?? open)}
            onDecide={decideOne}
            onSkip={skip}
            onUnskip={unskip}
          />
          <Dialog open={asking} onOpenChange={setAsking}>
            <DialogContent>
              <DialogTitle className="text-lg font-semibold">{t("intake.confirm.title")}</DialogTitle>
              <DialogDescription>{t("intake.confirm.text", { count: formatNumber(n), unsure: formatNumber(unsure) })}</DialogDescription>
              <div className="flex justify-end gap-2">
                <Button variant="outline" onClick={() => setAsking(false)}>
                  {t("edit.cancel")}
                </Button>
                <Button onClick={acceptAll}>{t("intake.confirm.yes")}</Button>
              </div>
            </DialogContent>
          </Dialog>
        </>
      )}
    </div>
  )
}

// The threshold, one button until it is wanted
function AutoAccept({ value, onChanged }: { value: number | null; onChanged: () => void }) {
  const [editing, setEditing] = useState(false)
  const [text, setText] = useState("")
  const save = useMutation({
    mutationFn: (v: number | null) => write.intakeThreshold(v),
    onSuccess: () => setEditing(false),
    onError: (err) => toast.show(t("intake.failed", { error: errorText(err) })),
    onSettled: onChanged,
  })
  const number = Number(text)
  const valid = text !== "" && Number.isInteger(number) && number >= 60 && number <= 100
  return (
    <>
      <Button
        variant="ghost"
        size="sm"
        className={muted}
        onClick={() => {
          setText(String(value ?? 90))
          setEditing(true)
        }}
      >
        {value === null ? t("intake.auto.off") : t("intake.auto.on", { value })}
      </Button>
      <Dialog open={editing} onOpenChange={setEditing}>
        <DialogContent>
          <DialogTitle className="text-lg font-semibold">{t("intake.auto.title")}</DialogTitle>
          <DialogDescription>{t("intake.auto.text")}</DialogDescription>
          <label className="grid gap-1 text-sm">
            {t("intake.auto.value")}
            <Input type="number" inputMode="numeric" min={60} max={100} value={text} aria-invalid={!valid} onChange={(e) => setText(e.target.value)} />
          </label>
          <div className="flex justify-end gap-2">
            {value !== null && (
              <Button variant="outline" disabled={save.isPending} onClick={() => save.mutate(null)}>
                {t("intake.auto.disable")}
              </Button>
            )}
            <Button disabled={!valid || save.isPending} onClick={() => save.mutate(number)}>
              {t("intake.auto.save")}
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </>
  )
}

// The whole list, whatever the filters; the bar only while the analysis runs
function IntakeNumbers({ progress: p }: { progress: IntakeProgress }) {
  const share = analysedShare(p)
  return (
    <div className="space-y-2 pb-1 text-sm">
      <p className="flex flex-wrap gap-x-5 gap-y-1 tabular-nums">
        <span>
          <span className="font-semibold">{formatNumber(p.total)}</span> {t("intake.total")}
        </span>
        <span>
          <span className="font-semibold">{formatNumber(p.analysed)}</span> {t("intake.analysed")}
        </span>
      </p>
      {(p.state === "paused" || p.state === "off") && <p className={muted}>{t(p.state === "off" ? "intake.hint.off" : "intake.hint.paused")}</p>}
      {p.state === "analysing" && (
        <div
          role="progressbar"
          aria-label={t("intake.bar")}
          aria-valuemin={0}
          aria-valuemax={100}
          aria-valuenow={share}
          className="h-1.5 max-w-[480px] overflow-hidden rounded-full bg-muted eink:rounded-none eink:border eink:border-black eink:bg-white"
        >
          <div className="h-full bg-primary eink:bg-black" style={{ width: `${share}%` }} />
        </div>
      )}
    </div>
  )
}

// a file's picture as BookCover shows a book's, without a book to go by
function EntryCover({ src, compact = false, className }: { src: string | null; compact?: boolean; className?: string }) {
  const [failed, setFailed] = useState(false)
  return (
    <div className={cn("relative aspect-[3/4] overflow-hidden rounded-md bg-muted eink:border-2 eink:border-black", className)}>
      {src && !failed ? (
        <img src={src} alt="" loading="lazy" decoding="async" width={300} height={400} onError={() => setFailed(true)} className="h-full w-full object-cover" />
      ) : (
        <div className="flex h-full items-center justify-center text-muted-foreground eink:text-black">
          <BookIcon className={compact ? "size-4" : "size-8"} aria-hidden />
        </div>
      )}
    </div>
  )
}

// On a phone the confidence is a ring around a dot in the band's color; E-Ink
// shows no color, so the text stays there
function ConfidenceRing({ entry: e }: { entry: IntakeEntry }) {
  if (e.confidence == null || e.band == null) return null
  return (
    <svg width="24" height="24" viewBox="0 0 24 24" role="img" aria-label={ringLabel(e)} className={cn("shrink-0 sm:hidden eink:hidden", BAND_COLOR[e.band])}>
      <circle cx="12" cy="12" r="10" fill="none" className="stroke-border" strokeWidth="3" />
      <circle cx="12" cy="12" r="10" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" pathLength="100" strokeDasharray={`${e.confidence} 100`} transform="rotate(-90 12 12)" />
      <circle cx="12" cy="12" r="4.5" fill="currentColor" />
    </svg>
  )
}

// the book the file looks like, or the other file in the Eingang
function DuplicateLine({ entry: e, same, onOpen }: { entry: IntakeEntry; same?: number; onOpen: (id: number) => void }) {
  if (e.action === "add") return null
  if (e.sameAs) {
    const text = t("intake.row.same", { name: e.sameAs.split("/").pop() ?? e.sameAs })
    return same === undefined ? (
      <div className="break-words">{text}</div>
    ) : (
      <button type="button" className="min-h-9 text-left break-words underline eink:min-h-12 touch:min-h-11" onClick={() => onOpen(same)}>
        {text}
      </button>
    )
  }
  if (e.bookId === null) return <div className="break-words">{t("intake.tag.duplicate")}</div>
  return (
    <div className="break-words">
      {t(e.action === "duplicate" ? "intake.row.duplicate" : "intake.row.formats")}{" "}
      <Link to="/books/$id" params={{ id: e.bookId }} className={cn("underline", linkSize)}>
        {e.bookTitle ?? `#${e.bookId}`}
      </Link>
    </div>
  )
}

function IntakeRow(props: { entry: IntakeEntry; same?: number; current: boolean; onOpen: (id: number) => void; onAccept: () => void; onTrash: () => void }) {
  const { entry: e, current, onOpen: openEntry } = props
  const onOpen = () => openEntry(e.id)
  // the whole row opens the drawer, except its controls and selecting text
  const open = (ev: MouseEvent<HTMLLIElement>) => {
    if ((ev.target as Element).closest("a, button, input, label") || !window.getSelection()?.isCollapsed) return
    onOpen()
  }
  // the icons on a row that is highlighted itself
  const icon = "hover:bg-foreground/10 eink:hover:bg-transparent"
  return (
    <li
      className={cn(
        "flex cursor-pointer scroll-my-4 gap-3 px-1 py-2 text-sm hover:bg-accent/60 eink:hover:bg-transparent",
        current && "bg-accent hover:bg-accent eink:bg-transparent eink:outline-4 eink:-outline-offset-4 eink:outline-black",
      )}
      data-entry={e.id}
      aria-current={current ? "true" : undefined}
      onClick={open}
    >
      {/* the file name below is the same button for keyboards and screen readers */}
      <button type="button" tabIndex={-1} aria-hidden className="shrink-0 self-start" onClick={onOpen}>
        <EntryCover key={e.cover} src={e.cover} compact className="w-16" />
      </button>
      <div className="min-w-0 flex-1 space-y-0.5" data-row-text>
        <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
          <button type="button" className="min-h-9 min-w-0 text-left font-medium [overflow-wrap:anywhere] hover:underline eink:min-h-12 touch:min-h-11" onClick={onOpen}>
            {e.name}
          </button>
          <ConfidenceRing entry={e} />
          <Badge variant="secondary" className={e.band ? "hidden sm:inline-flex eink:inline-flex" : undefined}>
            {e.band && <span aria-hidden className={cn("size-2 rounded-full bg-current eink:hidden", BAND_COLOR[e.band])} />}
            {badgeText(e)}
          </Badge>
          {e.skipped && <Badge variant="outline">{t("intake.tag.skipped")}</Badge>}
        </div>
        {e.proposal && <div className="break-words">{e.proposal.title}</div>}
        {e.proposal && <div className={cn("break-words", muted)}>{authorsText(e.proposal.authors)}</div>}
        <DuplicateLine entry={e} same={props.same} onOpen={openEntry} />
        {e.error && <div className="break-words text-destructive">{t("intake.failed", { error: e.error })}</div>}
      </div>
      <div className="flex shrink-0 gap-1 self-start">
        <Button variant="ghost" size="icon" className={cn("text-foreground", icon)} aria-label={t("intake.accept")} title={t("intake.accept")} disabled={!e.proposal} onClick={props.onAccept}>
          <Check className="size-5" strokeWidth={2.5} />
        </Button>
        <Button variant="ghost" size="icon" className={cn("text-destructive hover:text-destructive", icon)} aria-label={t("intake.trash")} title={t("intake.trash")} onClick={props.onTrash}>
          <Trash2 className="size-5" />
        </Button>
      </div>
    </li>
  )
}

// a key that does something here; touch and E-Ink have none
function KeyChip({ children, className }: { children: ReactNode; className?: string }) {
  return <kbd className={cn("rounded-sm border border-current px-1 font-sans text-xs font-medium opacity-70", className)}>{children}</kbd>
}

function CandidateItem({ candidate: c, digit }: { candidate: IntakeCandidate; digit: number }) {
  return (
    <li className="flex min-h-11 items-center gap-3 rounded-md border px-3 py-2 eink:min-h-14 eink:border-2">
      {digit <= 9 && <KeyChip className="hidden shrink-0 md:inline touch:hidden eink:hidden">{digit}</KeyChip>}
      <div className="min-w-0">
        <div className="font-medium break-words">{c.fields.title}</div>
        <div className="break-words">{authorsText(c.fields.authors)}</div>
      </div>
      <div className={cn("ml-auto shrink-0 text-right", muted)}>
        {t("intake.percent", { value: c.confidence })}
        <br />
        {candidateSource(c.source)}
      </div>
    </li>
  )
}

// a key on a button of the drawer
const ButtonKey = ({ children }: { children: ReactNode }) => <KeyChip className="touch:hidden eink:hidden">{children}</KeyChip>

// The file above everything found about it, the list visible beside it, its
// four exits below. Keys as in the review's drawer.
function IntakeSheet(props: {
  entry?: IntakeEntry
  onClose: () => void
  onBack: () => void
  onDecide: (e: IntakeEntry, decision: IntakeDecision, edited?: Edited) => void
  onSkip: (e: IntakeEntry) => void
  onUnskip: (e: IntakeEntry) => void
}) {
  const { entry: e, onBack, onDecide, onSkip } = props
  const id = e?.id
  const { data: detail } = useQuery({ ...intakeEntryQuery(id ?? 0), enabled: id !== undefined })
  // title and authors as edited for this entry
  const [edit, setEdit] = useState<{ id: number; title: string; authors: string[] } | null>(null)
  const edited = edit && edit.id === id ? edit : null
  const accept = () => {
    if (!e?.proposal) return
    const title = edited?.title.trim()
    if (edited && (!title || edited.authors.length === 0)) return
    onDecide(e, "accept", edited ? { title, authors: edited.authors } : {})
  }
  const startEdit = () => {
    if (e?.proposal && !edited) setEdit({ id: e.id, title: e.proposal.title, authors: e.proposal.authors })
  }
  // no list of what it uses: the keys always mean what the buttons say now
  useEffect(() => {
    if (!e) return
    const onKey = (ev: KeyboardEvent) => {
      if (ev.defaultPrevented || ev.isComposing || ev.ctrlKey || ev.metaKey || ev.altKey || isTyping(ev.target)) return
      // the sheet is one dialog, a second one on top keeps its keys
      if (document.querySelectorAll('[role="dialog"], [role="alertdialog"]').length > 1) return
      // a held key moves on, but never decides book after book
      if (ev.key === "j") onSkip(e)
      else if (ev.key === "k") onBack()
      else if (ev.key === "e") startEdit()
      else if (ev.key === "a" && !ev.repeat) accept()
      else if (ev.key === "f" && !ev.repeat) onDecide(e, "file")
      else if (ev.key === "d" && !ev.repeat) onDecide(e, "trash")
      else return
      ev.preventDefault()
    }
    window.addEventListener("keydown", onKey)
    return () => window.removeEventListener("keydown", onKey)
  })
  const shown = detail?.id === id ? detail : undefined
  const reason = e && reasonText(e)
  const enter = (ev: ReactKeyEvent) => {
    if (ev.key === "Enter") accept()
  }
  return (
    <Sheet open={e != null} onOpenChange={(o) => !o && props.onClose()}>
      <SheetContent
        side="right"
        className="sm:max-w-2xl"
        overlayClassName="bg-transparent"
        aria-describedby={undefined}
        header={<SheetTitle className="truncate text-base font-semibold">{e?.name ?? t("intake.title")}</SheetTitle>}
      >
        {e && (
          <div className="min-h-0 flex-1 space-y-4 overflow-y-auto px-4 pb-4 text-sm">
            <div className="flex gap-4">
              <EntryCover key={e.cover} src={e.cover} className="w-32 shrink-0" />
              <div className="min-w-0 space-y-1">
                <div className="text-xl font-semibold break-words">{entryTitle(e)}</div>
                {e.proposal && <div>{authorsText(e.proposal.authors)}</div>}
                {e.folder && <div className={cn("break-words", muted)}>{e.folder}</div>}
                <div className="flex flex-wrap gap-1">
                  <Badge variant="secondary">{badgeText(e, false)}</Badge>
                  {e.skipped && <Badge variant="outline">{t("intake.tag.skipped")}</Badge>}
                </div>
                {reason && <div className={cn("break-words", muted)}>{reason}</div>}
              </div>
            </div>
            {edited && (
              <div className="space-y-2">
                <label className="grid gap-1">
                  {t("intake.edit.title")}
                  <Input autoFocus value={edited.title} aria-invalid={!edited.title.trim()} onKeyDown={enter} onChange={(ev) => setEdit({ ...edited, title: ev.target.value })} />
                </label>
                <div className="grid gap-1">
                  {t("intake.edit.authors")}
                  <ChipsInput aria-label={t("intake.edit.authors")} value={edited.authors} onChange={(authors) => setEdit({ ...edited, authors })} suggestions={[]} />
                </div>
              </div>
            )}
            {e.error && (
              <p role="alert" className="rounded-md border border-destructive px-3 py-2 text-destructive eink:border-2">
                {t("intake.failed", { error: e.error })}
              </p>
            )}
            {shown &&
              noteTexts(shown).map((note) => (
                <p key={note} className="rounded-md border px-3 py-2 eink:border-2">
                  {note}
                </p>
              ))}
            {e.bookId !== null && (
              <Link to="/books/$id" params={{ id: e.bookId }} className={cn("underline", linkSize)}>
                {t("intake.open")}
              </Link>
            )}
            <section aria-labelledby="intake-candidates" className="space-y-2">
              <h2 id="intake-candidates" className="text-lg font-semibold">
                {t("intake.candidates")}
              </h2>
              {!shown ? (
                <p className={muted}>{t("loading")}</p>
              ) : shown.candidates.length === 0 ? (
                <p className={muted}>{t("intake.noCandidates")}</p>
              ) : (
                <ol className="space-y-2" aria-label={t("intake.candidates")}>
                  {shown.candidates.map((c, i) => (
                    <CandidateItem key={i} candidate={c} digit={i + 1} />
                  ))}
                </ol>
              )}
            </section>
            <div className="flex flex-wrap gap-2">
              <Button disabled={!e.proposal} onClick={accept}>
                {t("intake.accept")} <ButtonKey>a</ButtonKey>
              </Button>
              <Button variant="outline" onClick={() => onDecide(e, "file")}>
                {t("intake.asFile")} <ButtonKey>f</ButtonKey>
              </Button>
              {e.skipped ? (
                <Button variant="outline" onClick={() => props.onUnskip(e)}>
                  {t("intake.unskip")}
                </Button>
              ) : (
                <Button variant="outline" onClick={() => onSkip(e)}>
                  {t("intake.skip")} <ButtonKey>j</ButtonKey>
                </Button>
              )}
              <Button variant="outline" className="border-destructive text-destructive hover:bg-destructive/10 hover:text-destructive eink:hover:bg-transparent" onClick={() => onDecide(e, "trash")}>
                {t("intake.trash")} <ButtonKey>d</ButtonKey>
              </Button>
            </div>
            <p className={cn("hidden md:block touch:hidden eink:hidden", muted)}>
              <KeyChip>k</KeyChip> {t("intake.key.back")} · <KeyChip>e</KeyChip> {t("intake.key.edit")} · <KeyChip>Esc</KeyChip> {t("intake.key.close")}
            </p>
          </div>
        )}
      </SheetContent>
    </Sheet>
  )
}
