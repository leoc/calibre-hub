import { useEffect, useMemo, useRef, useState, type KeyboardEvent as ReactKeyEvent, type MouseEvent, type ReactNode } from "react"
import { keepPreviousData, useInfiniteQuery, useMutation, useQuery, useQueryClient, type InfiniteData } from "@tanstack/react-query"
import { Link } from "@tanstack/react-router"
import { BookIcon, Check, Trash2, X } from "lucide-react"
import { ApiError, EXCERPT_HEADER, intakeFileUrl, write, type ConfidenceBand, type IntakeCandidate, type IntakeDecision, type IntakeDetail, type IntakeEntry, type IntakeKind, type IntakeList, type IntakeOrigin } from "@/lib/api"
import {
  acceptable,
  analysedShare,
  asChosen,
  authorsText,
  autoText,
  badgeText,
  bandCount,
  bulkOf,
  candidateDiff,
  candidateSource,
  entryName,
  entryTitle,
  errorText as entryError,
  headlineText,
  hubTook,
  inKind,
  intakeEntryQuery,
  intakeFilter,
  intakeListQuery,
  intakeStatusQuery,
  isDjvu, isLibrary,
  kindCount,
  leaving,
  noteTexts,
  openCount,
  originName,
  originsInList,
  ORIGINS,
  readableFormat,
  reasonText,
  ringLabel,
  takeable,
  trashable,
  trashAllText,
  uniqueEntries,
  unreadable,
  type IntakeBand,
  type IntakeSource,
  type Leaving,
  type SharePart,
} from "@/lib/intake"
import { loadBookFile, readBody } from "@/lib/offline"
import { fileName } from "@/lib/reader"
import { errorText } from "@/lib/run-action"
import { toast } from "@/lib/toast"
import { formatNumber, t } from "@/i18n"
import { cn } from "@/lib/utils"
import { isTyping } from "@/components/keyboard"
import { ErrorMessage } from "@/components/error-view"
import { ShareBars } from "@/components/intake-shares"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogScreen, DialogTitle } from "@/components/ui/dialog"
import { Input } from "@/components/ui/input"
import { Sheet, SheetContent, SheetTitle } from "@/components/ui/sheet"
import { ChipsInput } from "@/components/ui/suggest"
import { LibraryProposalView } from "@/components/library-proposal"
import { FilePeek, type LoadFile } from "@/routes/reader"

const muted = "text-muted-foreground eink:text-black"
const select = "min-h-9 rounded-md border bg-background px-2 text-sm eink:min-h-12 eink:border-2 touch:min-h-11"
// Art and Sicherheit: each a line of its own on a phone
const pickLabel = "inline-flex items-center gap-2 max-sm:flex-[1_1_100%]"
const pickSelect = "max-sm:min-h-11 max-sm:min-w-0 max-sm:flex-auto"
const BAND_COLOR: Record<ConfidenceBand, string> = { bulk: "text-band-bulk", review: "text-band-review", unsure: "text-band-unsure" }

// the buttons that throw files away
const trashButton = "border-destructive text-destructive hover:bg-destructive/10 hover:text-destructive eink:hover:bg-transparent"

// a link's height where a pen or a finger has to hit it
const linkSize = "inline-flex items-center eink:min-h-12 touch:min-h-11"

// what a decision says beyond itself: one entry's edited title and authors
type Edited = { title?: string; authors?: string[] }

// a candidate chosen for an entry, not decided yet
type Chosen = { index: number; candidate: IntakeCandidate }

// The Eingang: what the analysis found in the backlog, the inbox and uploads,
// before anything is in the library. Every entry leaves by a decision: at once
// in the list, in a queue on the hub. The list stays where it is while the
// analysis works; only the bars and the line under the title move.
export function IntakePage() {
  const qc = useQueryClient()
  const [band, setBand] = useState<IntakeBand>("all")
  const [kind, setKind] = useState<IntakeKind>("all")
  const [source, setSource] = useState<IntakeSource>("all")
  const [open, setOpen] = useState<number | null>(null)
  const [trashing, setTrashing] = useState(false)
  // per entry, until it is decided: the list shows it too
  const [picks, setPicks] = useState<Map<number, Chosen>>(new Map())
  // decided, gone from the list until a list asked for after the hub took it
  const [decided, setDecided] = useState<Map<number, Leaving>>(new Map())
  // a new filter's answer is on its way: the bars don't follow the filter, they stay
  const { data: status, error, refetch: retry, dataUpdatedAt } = useQuery({ ...intakeStatusQuery(band, kind, source), placeholderData: keepPreviousData })
  const list = useInfiniteQuery({ ...intakeListQuery(band, kind, source), enabled: status?.enabled === true })
  const { hasNextPage, isFetchingNextPage, fetchNextPage, refetch } = list
  const loaded = useMemo(() => uniqueEntries(list.data?.pages ?? []), [list.data])
  const listedAt = list.dataUpdatedAt
  const entries = useMemo(() => loaded.filter((e) => inKind(e, kind) && !leaving(decided.get(e.id), listedAt)), [loaded, decided, kind, listedAt])
  const done = status?.progress?.done
  const pending = status?.pending
  const checked = status?.recheck?.done
  // everything loaded: new files join in; else the next page brings them
  useEffect(() => {
    if (done !== undefined && !hasNextPage) void refetch()
    // eslint-disable-next-line react-hooks/exhaustive-deps -- only when the analysis or the recheck moved on
  }, [done, checked])
  // the queue is through: what failed or turned out a duplicate is back,
  // in every filter's list
  const waited = useRef(false)
  useEffect(() => {
    if (pending === 0 && waited.current) {
      waited.current = false
      void qc.invalidateQueries({ queryKey: ["intake-list"] })
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
  // Art first, the band then starts over; the library's books have no source
  const chooseKind = (next: IntakeKind, nextBand: IntakeBand = "all") =>
    filter(() => {
      setKind(next)
      setBand(nextBand)
      if (next === "library") setSource("all")
    })
  const pickPart = (p: SharePart) => chooseKind(p.kind ?? "all", p.band)
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
      gone.forEach((e) => next.set(e.id, "sent"))
      return next
    })
  // the hub took them: what a list has from now on came back, a list on its
  // way may be older than that
  const taken = (ids: number[]) => {
    void qc.cancelQueries({ queryKey: ["intake-list"] })
    setDecided((d) => hubTook(d, ids, Date.now()))
  }
  const failed = (err: unknown) => toast.show(t("intake.failed", { error: errorText(err) }))
  const decide = useMutation({
    mutationFn: (v: { entry: IntakeEntry; decision: IntakeDecision; candidate?: number } & Edited) =>
      write.intakeDecide({ decision: v.decision, target: { ids: [v.entry.id] }, candidate: v.candidate, title: v.title, authors: v.authors }),
    onSuccess: (_r, v) => {
      if (v.decision !== "skip" && v.decision !== "unskip") taken([v.entry.id])
    },
    onError: (err, v) => {
      undecide([v.entry.id])
      failed(err)
    },
    onSettled: (_r, _e, v) => {
      // it changed its kind: the other filters' lists are out of date
      if (v.decision === "skip" || v.decision === "unskip") void qc.invalidateQueries({ queryKey: ["intake-list"], refetchType: "none" })
      return queued()
    },
  })
  const bulk = useMutation({
    mutationFn: (v: { decision: "accept" | "trash"; expect: number; last: number; gone: IntakeEntry[] }) =>
      write.intakeDecide({ decision: v.decision, target: { query: intakeFilter(band, kind, source), last: v.last, expect: v.expect }, picks: v.decision === "accept" ? chosen() : undefined }),
    onSuccess: (r, v) => {
      taken(v.gone.map((e) => e.id))
      if (v.decision === "trash") toast.show(r.total === 1 ? t("intake.trashAll.doneOne") : t("intake.trashAll.doneMany", { count: formatNumber(r.total) }))
    },
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
  // what a filter's accept has to know: no choice gets lost in it
  const chosen = () => {
    if (picks.size === 0) return undefined
    return Object.fromEntries([...picks].map(([id, p]) => [id, p.index]))
  }
  // the digit again takes the choice back
  const pick = (e: IntakeEntry, index: number, candidate: IntakeCandidate) =>
    setPicks((m) => {
      const next = new Map(m)
      if (next.get(e.id)?.index === index) next.delete(e.id)
      else next.set(e.id, { index, candidate })
      return next
    })
  // a skipped entry stays under Alle, the row says so; a filter on a kind lets it go
  const mark = (id: number, skipped: boolean) =>
    qc.setQueriesData<InfiniteData<IntakeList>>({ queryKey: ["intake-list"] }, (old) =>
      old && { ...old, pages: old.pages.map((p) => ({ ...p, entries: p.entries?.map((e) => (e.id === id ? { ...e, skipped } : e)) })) },
    )
  // the next one to ask: nothing skipped is asked again
  const after = (e: IntakeEntry) => entries.slice(entries.indexOf(e) + 1).find((x) => !x.skipped)?.id ?? null
  const decideOne = (e: IntakeEntry, decision: IntakeDecision, edited: Edited = {}) => {
    if (open === e.id) setOpen(after(e))
    leave([e])
    decide.mutate({ entry: e, decision, candidate: decision === "accept" ? picks.get(e.id)?.index : undefined, ...edited })
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
  const takeAll = (decision: "accept" | "trash", expect: number) => {
    setOpen(null)
    const gone = entries.filter(decision === "accept" ? takeable : trashable)
    leave(gone)
    bulk.mutate({ decision, expect, last: status?.last ?? 0, gone })
  }
  const current = index >= 0 ? entries[index] : undefined
  const shares = status?.shares
  const shown = list.data?.pages.at(-1)?.total ?? entries.length
  const action = shares ? bulkOf(shares, kind, band) : null
  // a number for an option, of the filter's numbers
  const kindOption = (k: IntakeKind) => ({ count: formatNumber(shares ? kindCount(shares, k) : 0) })
  const bandOption = (b: IntakeBand) => ({ count: formatNumber(shares ? bandCount(shares, kind, b) : 0) })
  const sources = originsInList(status)
  // the rows say where from when there is more than one place to come from
  const several = sources.length > 1
  return (
    <div className="mx-auto max-w-5xl space-y-4 p-4 lg:p-6">
      <div className="space-y-1">
        <h1 className="text-2xl font-semibold">{t("intake.title")}</h1>
        {status?.progress && shares && <IntakeNumbers list={status} waiting={shares.waiting} state={status.progress.state} />}
      </div>
      {error && !status ? (
        <ErrorMessage error={error} onRetry={() => retry()} />
      ) : !status ? (
        <p className="py-12 text-center text-muted-foreground">{t("loading")}</p>
      ) : !status.enabled ? (
        <p className="py-12 text-center text-lg">{t("intake.disabled")}</p>
      ) : (
        <>
          {shares && status.progress && (
            <ShareBars
              shares={shares}
              open={openCount(status)}
              analysed={analysedShare(status.progress)}
              moving={status.progress.state === "analysing"}
              kind={kind}
              band={band}
              source={source}
              onPick={pickPart}
            />
          )}
          <div className="flex flex-wrap items-center gap-3 text-sm">
            <label className={pickLabel}>
              {t("intake.kind")}
              <select className={cn(select, pickSelect)} value={kind} onChange={(e) => chooseKind(e.target.value as IntakeKind)}>
                <option value="all">{t("intake.kind.all", kindOption("all"))}</option>
                <option value="new">{t("intake.kind.new", kindOption("new"))}</option>
                <option value="sure">{t("intake.kind.sure", kindOption("sure"))}</option>
                <option value="duplicates">{t("intake.kind.duplicates", kindOption("duplicates"))}</option>
                <option value="skipped">{t("intake.kind.skipped", kindOption("skipped"))}</option>
                <option value="library">{t("intake.kind.library", kindOption("library"))}</option>
              </select>
            </label>
            <label className={pickLabel}>
              {t("intake.confidence")}
              <select className={cn(select, pickSelect)} value={band} onChange={(e) => filter(() => setBand(e.target.value as IntakeBand))}>
                <option value="all">{t("intake.band.all", bandOption("all"))}</option>
                <option value="bulk">{t("intake.band.bulk", bandOption("bulk"))}</option>
                <option value="review">{t("intake.band.review", bandOption("review"))}</option>
                <option value="unsure">{t("intake.band.unsure", bandOption("unsure"))}</option>
                {(band === "none" || (shares && bandCount(shares, kind, "none") > 0)) && <option value="none">{t("intake.band.none", bandOption("none"))}</option>}
              </select>
            </label>
            {kind !== "library" && (several || source !== "all") && (
              <label className="inline-flex items-center gap-2">
                {t("intake.origin")}
                <select className={select} value={source} onChange={(e) => filter(() => setSource(e.target.value as IntakeSource))}>
                  <option value="all">{t("intake.origin.all")}</option>
                  {ORIGINS.filter((o) => sources.includes(o) || o === source).map((o) => (
                    <option key={o} value={o}>
                      {t("intake.origin.option", { name: originName(o), count: formatNumber(status.origins?.[o] ?? 0) })}
                    </option>
                  ))}
                </select>
              </label>
            )}
            <div className="ml-auto flex flex-wrap items-center justify-end gap-3">
              {action?.decision === "trash" && (
                <Button variant="outline" className={trashButton} disabled={bulk.isPending} onClick={() => setTrashing(true)}>
                  {t("intake.trashAll", { count: formatNumber(action.count) })}
                </Button>
              )}
              {action?.decision === "accept" && (
                <Button disabled={bulk.isPending} onClick={() => takeAll("accept", action.count)}>
                  {t("intake.acceptAll", { count: formatNumber(action.count) })}
                </Button>
              )}
            </div>
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
                  origin={several ? e.origin : undefined}
                  pick={picks.get(e.id)}
                  onOpen={setOpen}
                  onAccept={() => decideOne(e, "accept")}
                  onDrop={() => decideOne(e, isLibrary(e) ? "reject" : "trash")}
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
          <div className="flex flex-wrap gap-2">
            {kind === "library" && <Recheck state={status.recheck ?? null} onChanged={refresh} />}
            <AutoAccept thresholds={status.thresholds ?? {}} onChanged={refresh} />
          </div>
          <IntakeSheet
            entry={current}
            pick={current && picks.get(current.id)}
            onPick={pick}
            onClose={() => setOpen(null)}
            onBack={() => setOpen(entries[index - 1]?.id ?? open)}
            onDecide={decideOne}
            onSkip={skip}
            onUnskip={unskip}
          />
          <Dialog open={trashing} onOpenChange={setTrashing}>
            <DialogContent>
              <DialogTitle className="text-lg font-semibold">{t("intake.trashAll.title")}</DialogTitle>
              <DialogDescription>{trashAllText(action?.count ?? 0)}</DialogDescription>
              <div className="flex justify-end gap-2">
                <Button variant="outline" onClick={() => setTrashing(false)}>
                  {t("edit.cancel")}
                </Button>
                <Button
                  variant="destructive"
                  onClick={() => {
                    setTrashing(false)
                    takeAll("trash", action?.count ?? 0)
                  }}
                >
                  {t("intake.trashAll.yes")}
                </Button>
              </div>
            </DialogContent>
          </Dialog>
        </>
      )}
    </div>
  )
}

// Plans the books no plan got to; it goes on by itself behind the analysis
function Recheck({ state, onChanged }: { state: IntakeList["recheck"] | null; onChanged: () => void }) {
  const start = useMutation({
    mutationFn: write.recheckLibrary,
    onSuccess: (r) => {
      if (r.books === 0) toast.show(t("intake.recheck.none"))
    },
    onError: (err) => toast.show(t("intake.failed", { error: errorText(err) })),
    onSettled: onChanged,
  })
  const label = !state
    ? t("intake.recheck")
    : t(state.waiting ? "intake.recheck.waiting" : "intake.recheck.running", { done: formatNumber(state.done), total: formatNumber(state.total) })
  return (
    <Button variant="ghost" size="sm" className={muted} disabled={!!state || start.isPending} onClick={() => start.mutate()}>
      {label}
    </Button>
  )
}

// a source's line in the dialog, as it is being edited
type AutoRow = { on: boolean; text: string }

const validAuto = (r: AutoRow) => {
  const n = Number(r.text)
  return !r.on || (r.text !== "" && Number.isInteger(n) && n >= 60 && n <= 100)
}

// The thresholds of the sources there are, one button until they are wanted
function AutoAccept({ thresholds, onChanged }: { thresholds: NonNullable<IntakeList["thresholds"]>; onChanged: () => void }) {
  const [rows, setRows] = useState<Partial<Record<IntakeOrigin, AutoRow>> | null>(null)
  const origins = ORIGINS.filter((o) => thresholds[o] !== undefined)
  const save = useMutation({
    mutationFn: async (edited: Partial<Record<IntakeOrigin, AutoRow>>) => {
      for (const o of origins) {
        const row = edited[o]
        const value = row?.on ? Number(row.text) : null
        if (row && value !== thresholds[o]) await write.intakeThreshold(o, value)
      }
    },
    onSuccess: () => setRows(null),
    onError: (err) => toast.show(t("intake.failed", { error: errorText(err) })),
    onSettled: onChanged,
  })
  const row = (o: IntakeOrigin) => rows?.[o] ?? { on: false, text: "90" }
  const change = (o: IntakeOrigin, next: Partial<AutoRow>) => setRows({ ...rows, [o]: { ...row(o), ...next } })
  const edit = () => setRows(Object.fromEntries(origins.map((o) => [o, { on: thresholds[o] != null, text: String(thresholds[o] ?? 90) }])))
  return (
    <>
      <Button variant="ghost" size="sm" className={cn("h-auto min-h-8 shrink text-left whitespace-normal", muted)} onClick={edit}>
        {autoText(thresholds)}
      </Button>
      <Dialog open={rows !== null} onOpenChange={(o) => !o && setRows(null)}>
        <DialogContent>
          <DialogTitle className="text-lg font-semibold">{t("intake.auto.title")}</DialogTitle>
          <DialogDescription>{t("intake.auto.text")}</DialogDescription>
          <div className="grid gap-3 text-sm">
            {origins.map((o) => (
              <div key={o} className="flex items-center gap-3">
                <label className="flex min-h-9 w-28 items-center gap-2 eink:min-h-12 touch:min-h-11">
                  <input type="checkbox" className="size-4 eink:size-6" checked={row(o).on} onChange={(e) => change(o, { on: e.target.checked })} />
                  {originName(o)}
                </label>
                <Input
                  type="number"
                  inputMode="numeric"
                  className="w-24"
                  min={60}
                  max={100}
                  disabled={!row(o).on}
                  value={row(o).text}
                  aria-label={t("intake.auto.value", { name: originName(o) })}
                  aria-invalid={!validAuto(row(o))}
                  onChange={(e) => change(o, { text: e.target.value })}
                />
              </div>
            ))}
          </div>
          <div className="flex justify-end gap-2">
            <Button disabled={!origins.every((o) => validAuto(row(o))) || save.isPending} onClick={() => rows && save.mutate(rows)}>
              {t("intake.auto.save")}
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </>
  )
}

// The whole list, whatever the filters and the source
function IntakeNumbers({ list, waiting, state }: { list: IntakeList; waiting: number; state: string }) {
  return (
    <div className={cn("space-y-1 text-sm tabular-nums", muted)}>
      <p>{headlineText(waiting, openCount(list))}</p>
      {(state === "paused" || state === "off") && <p>{t(state === "off" ? "intake.hint.off" : "intake.hint.paused")}</p>}
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
  if (e.action === "add" || isLibrary(e)) return null
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

function IntakeRow(props: { entry: IntakeEntry; same?: number; current: boolean; origin?: IntakeOrigin; pick?: Chosen; onOpen: (id: number) => void; onAccept: () => void; onDrop: () => void }) {
  const { current, pick, onOpen: openEntry } = props
  // how sure it is, as the choice has it; the rest is the entry's
  const e = asChosen(props.entry, pick?.candidate)
  const library = isLibrary(e)
  const title = pick?.candidate.fields.title ?? e.proposal?.title
  const authors = pick?.candidate.fields.authors?.length ? pick.candidate.fields.authors : e.proposal?.authors
  const drop = library ? t("intake.reject") : t("intake.trash")
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
            {entryName(e)}
          </button>
          <ConfidenceRing entry={e} />
          <Badge variant="secondary" className={e.band ? "hidden sm:inline-flex eink:inline-flex" : undefined}>
            {e.band && <span aria-hidden className={cn("size-2 rounded-full bg-current eink:hidden", BAND_COLOR[e.band])} />}
            {badgeText(e)}
          </Badge>
          {props.origin && <Badge variant="outline">{originName(props.origin)}</Badge>}
          {e.skipped && <Badge variant="outline">{t("intake.tag.skipped")}</Badge>}
        </div>
        {e.proposal && <div className="break-words">{title}</div>}
        {e.proposal && <div className={cn("break-words", muted)}>{authorsText(authors)}</div>}
        <DuplicateLine entry={e} same={props.same} onOpen={openEntry} />
        {e.error && <div className="break-words text-destructive">{t("intake.failed", { error: entryError(e) ?? e.error })}</div>}
      </div>
      <div className="flex shrink-0 gap-1 self-start">
        <Button variant="ghost" size="icon" className={cn("text-foreground", icon)} aria-label={t("intake.accept")} title={t("intake.accept")} disabled={library ? !acceptable(e) : !e.proposal} onClick={props.onAccept}>
          <Check className="size-5" strokeWidth={2.5} />
        </Button>
        {/* a book of the library is never thrown away from here */}
        <Button variant="ghost" size="icon" className={cn(!library && "text-destructive hover:text-destructive", icon)} aria-label={drop} title={drop} onClick={props.onDrop}>
          {library ? <X className="size-5" /> : <Trash2 className="size-5" />}
        </Button>
      </div>
    </li>
  )
}

// a key that does something here; touch and E-Ink have none
function KeyChip({ children, className }: { children: ReactNode; className?: string }) {
  return <kbd className={cn("rounded-sm border border-current px-1 font-sans text-xs font-medium opacity-70", className)}>{children}</kbd>
}

// One thing found about the file, to choose by click or digit; only choosing,
// the exits below decide
function CandidateItem(props: { candidate: IntakeCandidate; digit: number; proposal: IntakeEntry["proposal"]; chosen: boolean; onPick: () => void }) {
  const { candidate: c, digit, chosen } = props
  const diff = candidateDiff(c, props.proposal)
  return (
    <li>
      <button
        type="button"
        aria-pressed={chosen}
        onClick={props.onPick}
        className={cn(
          "flex min-h-11 w-full items-center gap-3 rounded-md px-3 py-2 text-left hover:bg-accent eink:min-h-14 eink:hover:bg-transparent",
          chosen ? "border-2 border-foreground eink:border-4 eink:border-black" : "border eink:border-2",
        )}
      >
        {digit <= 9 && <KeyChip className="hidden shrink-0 md:inline touch:hidden eink:hidden">{digit}</KeyChip>}
        {c.fields.coverUrl && <EntryCover key={c.fields.coverUrl} src={c.fields.coverUrl} compact className="w-10 shrink-0" />}
        <span className="block min-w-0">
          <span className="block font-medium break-words">{c.fields.title}</span>
          <span className="block break-words">{authorsText(c.fields.authors)}</span>
          <span className={cn("block break-words", muted)}>{diff.length ? t("intake.diff.text", { list: diff.join(" · ") }) : t("intake.diff.same")}</span>
        </span>
        <span className={cn("ml-auto shrink-0 text-right", muted)}>
          {t("intake.percent", { value: c.confidence })}
          <br />
          {candidateSource(c.source)}
        </span>
      </button>
    </li>
  )
}

// a key on a button of the drawer
const ButtonKey = ({ children }: { children: ReactNode }) => <KeyChip className="touch:hidden eink:hidden">{children}</KeyChip>

// The file's first pages over the drawer: Esc, the reader's back button and
// the phone's come back to the entry. A book of the library opens its own file.
// A large file comes as its first pages (Intake#peek), a DjVu as a PDF of them.
function Peek({ entry: e, format, onClose }: { entry: IntakeEntry; format: string; onClose: () => void }) {
  const title = entryTitle(e)
  const [excerpt, setExcerpt] = useState(0)
  const shown = isDjvu(format) ? "PDF" : format
  const load: LoadFile = async (signal, progress) => {
    if (isLibrary(e) && e.bookId !== null) return loadBookFile(e.bookId, format, signal, progress)
    const res = await fetch(intakeFileUrl(e.id, format), { credentials: "same-origin", signal })
    if (!res.ok) throw new Error(`${res.status} ${res.statusText}`)
    setExcerpt(Number(res.headers.get(EXCERPT_HEADER)) || 0)
    return readBody(res, progress)
  }
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogScreen aria-describedby={undefined}>
        <DialogTitle className="sr-only">{title}</DialogTitle>
        <FilePeek title={title} name={fileName(e.id, shown)} format={shown} load={load} note={excerpt ? t("reader.excerpt", { pages: excerpt }) : undefined} onClose={onClose} />
      </DialogScreen>
    </Dialog>
  )
}

// The file above everything found about it, the list visible beside it, its
// four exits below; a book of the library old → new and three exits, nothing
// that touches its files. Keys as in the review's drawer.
function IntakeSheet(props: {
  entry?: IntakeEntry
  pick?: Chosen
  onPick: (e: IntakeEntry, index: number, candidate: IntakeCandidate) => void
  onClose: () => void
  onBack: () => void
  onDecide: (e: IntakeEntry, decision: IntakeDecision, edited?: Edited) => void
  onSkip: (e: IntakeEntry) => void
  onUnskip: (e: IntakeEntry) => void
}) {
  const { entry: e, pick, onBack, onDecide, onSkip } = props
  const id = e?.id
  const library = e !== undefined && isLibrary(e)
  const format = e ? readableFormat(e) : null
  const [peeking, setPeeking] = useState<number | null>(null)
  const { data: detail } = useQuery({ ...intakeEntryQuery(id ?? 0), enabled: id !== undefined })
  const shown = detail?.id === id ? detail : undefined
  // title and authors as edited for this entry
  const [edit, setEdit] = useState<{ id: number; title: string; authors: string[] } | null>(null)
  const edited = edit && edit.id === id ? edit : null
  const accept = () => {
    if (!e?.proposal || (library && !acceptable(e))) return
    const title = edited?.title.trim()
    if (edited && (!title || edited.authors.length === 0)) return
    onDecide(e, "accept", edited ? { title, authors: edited.authors } : {})
  }
  const startEdit = () => {
    if (e?.proposal && !edited && !library) setEdit({ id: e.id, ...chosenValues(e.proposal, pick) })
  }
  const choose = (index: number) => {
    const c = shown?.candidates[index]
    if (!e || !c) return
    props.onPick(e, index, c)
    // the form follows the choice; taking it back goes to the proposal
    if (edited && e.proposal) setEdit({ id: e.id, ...chosenValues(e.proposal, pick?.index === index ? undefined : { index, candidate: c }) })
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
      else if (ev.key === "o") {
        if (format) setPeeking(e.id)
      }
      else if (/^[1-9]$/.test(ev.key) && !ev.repeat) choose(Number(ev.key) - 1)
      else if (ev.key === "a" && !ev.repeat) accept()
      else if (ev.key === "f" && !ev.repeat && !library) onDecide(e, "file")
      else if (ev.key === "d" && !ev.repeat && !library) onDecide(e, "trash")
      else if (ev.key === "x" && !ev.repeat && library) onDecide(e, "reject")
      else return
      ev.preventDefault()
    }
    window.addEventListener("keydown", onKey)
    return () => window.removeEventListener("keydown", onKey)
  })
  const reason = e && (pick ? t("intake.why.candidate", { source: candidateSource(pick.candidate.source) }) : reasonText(e))
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
        header={<SheetTitle className="truncate text-base font-semibold">{e ? entryName(e) : t("intake.title")}</SheetTitle>}
      >
        {e && (
          <div className="min-h-0 flex-1 space-y-4 overflow-y-auto px-4 pb-4 text-sm">
            <div className="flex gap-4">
              {format ? (
                <button type="button" aria-label={t("intake.read")} className="w-32 shrink-0 self-start" onClick={() => setPeeking(e.id)}>
                  <EntryCover key={e.cover} src={e.cover} />
                </button>
              ) : (
                <EntryCover key={e.cover} src={e.cover} className="w-32 shrink-0" />
              )}
              <div className="min-w-0 space-y-1">
                <div className="text-xl font-semibold break-words">{pick?.candidate.fields.title ?? entryTitle(e)}</div>
                {e.proposal && <div>{authorsText(pick?.candidate.fields.authors?.length ? pick.candidate.fields.authors : e.proposal.authors)}</div>}
                {e.folder && <div className={cn("break-words", muted)}>{e.folder}</div>}
                <div className="flex flex-wrap gap-1">
                  <Badge variant="secondary">{badgeText(asChosen(e, pick?.candidate), false)}</Badge>
                  {e.skipped && <Badge variant="outline">{t("intake.tag.skipped")}</Badge>}
                </div>
                {reason && <div className={cn("break-words", muted)}>{reason}</div>}
                {format ? (
                  <Button variant="outline" size="sm" onClick={() => setPeeking(e.id)}>
                    {t("intake.read")} <ButtonKey>o</ButtonKey>
                  </Button>
                ) : (
                  unreadable(e) && <div className={muted}>{t("intake.read.no")}</div>
                )}
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
                {t("intake.failed", { error: entryError(e) ?? e.error })}
              </p>
            )}
            {library && shown && <LibraryProposal entry={e} detail={shown} />}
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
            {!library && (
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
                      <CandidateItem key={i} candidate={c} digit={i + 1} proposal={e.proposal} chosen={pick?.index === i} onPick={() => choose(i)} />
                    ))}
                  </ol>
                )}
              </section>
            )}
            <div className="flex flex-wrap gap-2" data-exits>
              <Button disabled={library ? !acceptable(e) : !e.proposal} onClick={accept}>
                {t("intake.accept")} <ButtonKey>a</ButtonKey>
              </Button>
              {!library && (
                <Button variant="outline" onClick={() => onDecide(e, "file")}>
                  {t("intake.asFile")} <ButtonKey>f</ButtonKey>
                </Button>
              )}
              {e.skipped ? (
                <Button variant="outline" onClick={() => props.onUnskip(e)}>
                  {t("intake.unskip")}
                </Button>
              ) : (
                <Button variant="outline" onClick={() => onSkip(e)}>
                  {t("intake.skip")} <ButtonKey>j</ButtonKey>
                </Button>
              )}
              {library ? (
                <Button variant="outline" onClick={() => onDecide(e, "reject")}>
                  {t("intake.reject")} <ButtonKey>x</ButtonKey>
                </Button>
              ) : (
                <Button variant="outline" className={trashButton} onClick={() => onDecide(e, "trash")}>
                  {t("intake.trash")} <ButtonKey>d</ButtonKey>
                </Button>
              )}
            </div>
            <p className={cn("hidden md:block touch:hidden eink:hidden", muted)}>
              <KeyChip>k</KeyChip> {t("intake.key.back")} · {!library && <><KeyChip>e</KeyChip> {t("intake.key.edit")} · </>}<KeyChip>Esc</KeyChip> {t("intake.key.close")}
            </p>
            {peeking === e.id && format && <Peek entry={e} format={format} onClose={() => setPeeking(null)} />}
          </div>
        )}
      </SheetContent>
    </Sheet>
  )
}

// what the edit form starts from
function chosenValues(p: NonNullable<IntakeEntry["proposal"]>, pick?: Chosen) {
  const f = pick?.candidate.fields
  return { title: f?.title ?? p.title, authors: f?.authors?.length ? f.authors : p.authors }
}

// old → new, field by field
function LibraryProposal({ entry: e, detail }: { entry: IntakeEntry; detail: IntakeDetail }) {
  return <LibraryProposalView entry={{ ...e, file: e.path, changes: detail.changes }} title={e.bookTitle ?? entryName(e)} unsureTag={detail.unsureTag ?? ""} />
}
