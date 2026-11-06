import { useEffect, useMemo, useState, type MouseEvent, type ReactNode } from "react"
import { useInfiniteQuery, useQuery } from "@tanstack/react-query"
import { BookIcon } from "lucide-react"
import type { IntakeCandidate, IntakeEntry, IntakeKind, IntakeProgress } from "@/lib/api"
import {
  analysedShare,
  authorsText,
  badgeText,
  candidateSource,
  entryTitle,
  intakeEntryQuery,
  intakeListQuery,
  intakeStatusQuery,
  noteTexts,
  reasonText,
  uniqueEntries,
  type IntakeBand,
} from "@/lib/intake"
import { formatNumber, t } from "@/i18n"
import { cn } from "@/lib/utils"
import { isTyping } from "@/components/keyboard"
import { ErrorMessage } from "@/components/error-view"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Sheet, SheetContent, SheetTitle } from "@/components/ui/sheet"

const muted = "text-muted-foreground eink:text-black"
const select = "min-h-9 rounded-md border bg-background px-2 text-sm eink:min-h-12 eink:border-2 touch:min-h-11"

// The Eingang: what the analysis found in the backlog, before anything is in
// the library. Read only for now: the list by confidence and kind, a drawer
// per file with everything found, moving on by key. The list stays where it
// is while the analysis works; only the line under the title moves.
export function IntakePage() {
  const [band, setBand] = useState<IntakeBand>("all")
  const [kind, setKind] = useState<IntakeKind>("all")
  const [open, setOpen] = useState<number | null>(null)
  const { data: status, error, refetch: retry } = useQuery(intakeStatusQuery(kind))
  const list = useInfiniteQuery({ ...intakeListQuery(band, kind), enabled: status?.enabled === true })
  const { hasNextPage, isFetchingNextPage, fetchNextPage, refetch } = list
  const entries = useMemo(() => uniqueEntries(list.data?.pages ?? []), [list.data])
  const done = status?.progress?.done
  // everything loaded: new files join in; else the next page brings them
  useEffect(() => {
    if (done !== undefined && !hasNextPage) void refetch()
    // eslint-disable-next-line react-hooks/exhaustive-deps -- only when the analysis moved on
  }, [done])
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
  const current = index >= 0 ? entries[index] : undefined
  const counts = status?.counts
  const all = counts ? counts.bulk + counts.review + counts.unsure + counts.none : 0
  const shown = list.data?.pages.at(-1)?.total ?? entries.length
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
              </select>
            </label>
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
                <IntakeRow key={e.id} entry={e} current={e.id === open} onOpen={() => setOpen(e.id)} />
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
          <IntakeSheet
            entry={current}
            onClose={() => setOpen(null)}
            onNext={() => setOpen(entries[index + 1]?.id ?? null)}
            onBack={() => setOpen(entries[index - 1]?.id ?? open)}
          />
        </>
      )}
    </div>
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

function IntakeRow({ entry: e, current, onOpen }: { entry: IntakeEntry; current: boolean; onOpen: () => void }) {
  // the whole row opens the drawer, except its controls and selecting text
  const open = (ev: MouseEvent<HTMLLIElement>) => {
    if ((ev.target as Element).closest("a, button, input, label") || !window.getSelection()?.isCollapsed) return
    onOpen()
  }
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
      <div className="min-w-0 flex-1 space-y-0.5">
        <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
          <button type="button" className="min-h-9 min-w-0 text-left font-medium [overflow-wrap:anywhere] hover:underline eink:min-h-12 touch:min-h-11" onClick={onOpen}>
            {e.name}
          </button>
          <Badge variant="secondary">{badgeText(e)}</Badge>
        </div>
        {e.proposal && <div className="break-words">{e.proposal.title}</div>}
        {e.proposal && <div className={cn("break-words", muted)}>{authorsText(e.proposal.authors)}</div>}
      </div>
      {/* the decisions' two icon buttons go here, right of the text */}
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

// The file above everything found about it, the list visible beside it
function IntakeSheet(props: { entry?: IntakeEntry; onClose: () => void; onNext: () => void; onBack: () => void }) {
  const { entry: e, onNext, onBack } = props
  const id = e?.id
  const { data: detail } = useQuery({ ...intakeEntryQuery(id ?? 0), enabled: id !== undefined })
  useEffect(() => {
    if (id === undefined) return
    const onKey = (ev: KeyboardEvent) => {
      if (ev.defaultPrevented || ev.isComposing || ev.ctrlKey || ev.metaKey || ev.altKey || isTyping(ev.target)) return
      if (ev.key === "j") onNext()
      else if (ev.key === "k") onBack()
      else return
      ev.preventDefault()
    }
    window.addEventListener("keydown", onKey)
    return () => window.removeEventListener("keydown", onKey)
  }, [id, onNext, onBack])
  const shown = detail?.id === id ? detail : undefined
  const reason = e && reasonText(e)
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
                <div>
                  <Badge variant="secondary">{badgeText(e, false)}</Badge>
                </div>
                {reason && <div className={cn("break-words", muted)}>{reason}</div>}
              </div>
            </div>
            {shown &&
              noteTexts(shown).map((note) => (
                <p key={note} className="rounded-md border px-3 py-2 eink:border-2">
                  {note}
                </p>
              ))}
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
            <p className={cn("hidden md:block touch:hidden eink:hidden", muted)}>
              <KeyChip>j</KeyChip> {t("intake.key.next")} · <KeyChip>k</KeyChip> {t("intake.key.back")} · <KeyChip>Esc</KeyChip> {t("intake.key.close")}
            </p>
          </div>
        )}
      </SheetContent>
    </Sheet>
  )
}
