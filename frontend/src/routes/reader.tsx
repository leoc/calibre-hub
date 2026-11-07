import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react"
import { getRouteApi, useCanGoBack, useNavigate, useRouter } from "@tanstack/react-router"
import { useQuery, useQueryClient } from "@tanstack/react-query"
import { ArrowLeft, ChevronLeft, ChevronRight, List, RotateCcw, Type } from "lucide-react"
import type { FoliateView, RelocateDetail, TocItem } from "foliate-js/view.js"
import { ApiError, type Book, type ProgressEntry, type ProgressSave } from "@/lib/api"
import { bookQuery, progressQuery } from "@/lib/queries"
import { loadBookFile, offlineSupported, refreshOffline, useOfflineBook, type LoadProgress } from "@/lib/offline"
import { isNetworkError, useOnline } from "@/lib/online"
import { queuedProgress, saveProgress, withQueued } from "@/lib/progress-sync"
import { OfflineBadge, OfflineButton } from "@/components/offline"
import {
  fileName,
  getDeviceId,
  getDeviceName,
  loadingText,
  OPEN_LIMIT,
  peekKey,
  percent,
  positionOf,
  readerFormat,
  readerKey,
  STALL_LIMIT,
  startPoint,
  tapZone,
  targetOf,
  UNCAUGHT_LIMIT,
  watchdog,
  type StartPoint,
} from "@/lib/reader"
import { chromeVars, effectiveSettings } from "@/lib/reader-settings"
import { keyboard } from "@/lib/keyboard"
import { useTheme } from "@/lib/theme"
import { cn } from "@/lib/utils"
import { t } from "@/i18n"
import { Button } from "@/components/ui/button"
import { Sheet, SheetContent, SheetTitle } from "@/components/ui/sheet"
import { ErrorMessage } from "@/components/error-view"
import { ReaderSettingsSheet, applyReaderSettings, prepareBook, useApplyReaderSettings, useReaderSettings, useReaderSettingsReady } from "@/components/reader-settings"

const route = getRouteApi("/read/$id")

// Full screen reader (foliate-js): /read/:id[?format=]
export function ReaderPage() {
  const { id } = route.useParams()
  const { format: wanted } = route.useSearch()
  const online = useOnline()
  const stored = useOfflineBook(id)
  const book = useQuery(bookQuery(id))
  // fresh every time: another device may have read on since
  const progress = useQuery({ ...progressQuery(id), gcTime: 0 })
  const back = useBack(id)
  const settingsReady = useReaderSettingsReady()
  // a book stored offline keeps what the hub last said
  useEffect(() => {
    if (book.data) refreshOffline(id, { book: book.data })
  }, [id, book.data])
  useEffect(() => {
    if (progress.data) refreshOffline(id, { progress: progress.data.devices })
  }, [id, progress.data])
  const error = book.error ?? progress.error
  // without the hub a book stored offline opens from what was stored
  const local = stored && (!online || unreachable(book.error) || unreachable(progress.error)) ? stored : null
  const data = book.data ?? local?.book
  const devices = progress.data?.devices ?? local?.progress
  if (error && !local) return <Centered><ErrorMessage error={error} onRetry={() => (book.refetch(), progress.refetch())} /><BackButton onClick={back} /></Centered>
  if (!data || !devices || !settingsReady) {
    if (!online && !stored && (!data || !devices)) return <Centered><p role="alert">{t("reader.notOffline")}</p><BackButton onClick={back} /></Centered>
    return <Centered><p className="text-muted-foreground eink:text-black">{t("reader.loading")}</p></Centered>
  }
  // the stored format unless another one is asked for, so the reader
  // doesn't reopen when the hub answers again
  const format = stored && (!wanted || wanted.toUpperCase() === stored.format) ? stored.format : readerFormat(data, wanted)
  if (!format) return <Centered><p role="alert">{t("reader.noFormat")}</p><BackButton onClick={back} /></Centered>
  const start = startPoint(withQueued(devices, queuedProgress(id)), getDeviceId())
  const name = fileName(id, format)
  const load: LoadFile = (signal, onProgress) => loadBookFile(id, format, signal, onProgress)
  return <Reader key={`${id}-${format}`} book={data} title={data.title} name={name} load={load} format={format} start={start} onBack={back} />
}

const NO_POSITION: StartPoint = { mine: null, elsewhere: null }

// The file, saying how far it got: that is how the reader knows it still comes
export type LoadFile = (signal: AbortSignal, onProgress: LoadProgress) => Promise<Blob>

// A file's first pages without a book behind it (the Eingang): the reader
// with its paging and settings, nothing about the reading is kept
export function FilePeek({ title, name, format, load, note, onClose }: { title: string; name: string; format: string; load: LoadFile; note?: string; onClose: () => void }) {
  const settingsReady = useReaderSettingsReady()
  if (!settingsReady) return <Centered><p className="text-muted-foreground eink:text-black">{t("reader.loading")}</p></Centered>
  return <Reader title={title} name={name} load={load} format={format} start={NO_POSITION} note={note} onBack={onClose} />
}

// no answer, or a hub that can't answer now
const unreachable = (e: unknown) => isNetworkError(e) || (e instanceof ApiError && e.status >= 500)

// Escape and the back button: where the reader was opened from (the
// detail), or the book's page when it was opened directly
function useBack(id: number) {
  const router = useRouter()
  const canGoBack = useCanGoBack()
  const navigate = useNavigate()
  return useCallback(() => (canGoBack ? router.history.back() : navigate({ to: "/books/$id", params: { id } })), [canGoBack, router, navigate, id])
}

function Centered({ children }: { children: ReactNode }) {
  return <div className="flex min-h-dvh flex-col items-center justify-center gap-4 p-4 text-center">{children}</div>
}

function BackButton({ onClick }: { onClick: () => void }) {
  return (
    <Button variant="outline" onClick={onClick}>
      <ArrowLeft /> {t("reader.back")}
    </Button>
  )
}

interface Location {
  fraction: number
  chapter: string | null
}

const SAVE_DELAY = 1500

// book: what the position is saved for; without one nothing is. note: what is
// to be known about what is shown
function Reader({ book, title, name, load, format, start, note, onBack }: { book?: Book; title: string; name: string; load: LoadFile; format: string; start: StartPoint; note?: string; onBack: () => void }) {
  const { eink } = useTheme()
  const queryClient = useQueryClient()
  const host = useRef<HTMLDivElement>(null)
  const viewRef = useRef<FoliateView | null>(null)
  const [status, setStatus] = useState<"loading" | "ready" | "failed">("loading")
  const [failure, setFailure] = useState<unknown>(null)
  // how far the file is, then that it is being opened
  const [loading, setLoading] = useState<string>()
  const [attempt, setAttempt] = useState(0)
  const [loc, setLoc] = useState<Location>({ fraction: start.mine?.fraction ?? 0, chapter: null })
  const [toc, setToc] = useState<TocItem[]>([])
  const [fixed, setFixed] = useState(false)
  const [elsewhere, setElsewhere] = useState<ProgressEntry | null>(start.elsewhere)
  const [tocOpen, setTocOpen] = useState(false)
  const [settingsOpen, setSettingsOpen] = useState(false)
  // E-Ink: the bars only after a tap in the middle
  const [bars, setBars] = useState(!eink)
  // per account (components/reader-settings.tsx); E-Ink overrides some
  const { settings: accountSettings, update: updateSettings } = useReaderSettings()
  const settings = useMemo(() => effectiveSettings(accountSettings, eink), [accountSettings, eink])
  const overlayOpen = tocOpen || settingsOpen

  // --- saving: debounced, and right away when leaving -----------------------
  const pending = useRef<ProgressSave | null>(null)
  const saved = useRef<string | null>(start.mine && start.mine.format === format.toLowerCase() ? start.mine.position : null)
  const timer = useRef<ReturnType<typeof setTimeout>>(undefined)
  const flush = useCallback(
    (closing = false) => {
      clearTimeout(timer.current)
      const p = pending.current
      if (!p || !book) return
      pending.current = null
      saved.current = p.position
      // queued first; offline it waits there for the next contact
      void saveProgress(book.id, p, closing).then((entry) => {
        if (entry) void queryClient.invalidateQueries({ queryKey: ["progress"] })
      })
    },
    [book, queryClient],
  )

  const onRelocate = useRef<(d: RelocateDetail, ready: boolean) => void>(() => {})
  useEffect(() => {
    onRelocate.current = (d, ready) => {
      const view = viewRef.current
      const section = d.section?.current ?? 0
      // fixed layout (PDF, comics): page n of N, so the last page is 100 %
      const fraction = view?.isFixedLayout && d.section ? Math.min(1, (section + 1) / d.section.total) : d.fraction
      setLoc({ fraction, chapter: d.tocItem?.label?.trim() || null })
      if (!ready || !book) return
      const position = positionOf(format, d.cfi, section)
      if (position === saved.current) return
      pending.current = { format: format.toLowerCase(), position, fraction: Math.max(0, Math.min(1, fraction)), device: getDeviceId(), deviceName: getDeviceName() }
      clearTimeout(timer.current)
      timer.current = setTimeout(() => flush(), SAVE_DELAY)
    }
  })

  useEffect(() => {
    const onHide = () => document.visibilityState === "hidden" && flush(true)
    const onPageHide = () => flush(true)
    document.addEventListener("visibilitychange", onHide)
    window.addEventListener("pagehide", onPageHide)
    return () => {
      document.removeEventListener("visibilitychange", onHide)
      window.removeEventListener("pagehide", onPageHide)
      flush(true)
    }
  }, [flush])

  // --- turning pages ---------------------------------------------------------
  const next = useCallback(() => void viewRef.current?.goRight(), [])
  const prev = useCallback(() => void viewRef.current?.goLeft(), [])
  const act = useRef<(e: KeyboardEvent) => void>(() => {})
  useEffect(() => {
    act.current = (e) => {
      if (overlayOpen || e.defaultPrevented) return
      const target = e.target as HTMLElement | null
      if (target?.closest?.("input, textarea, select, [contenteditable=true]")) return
      const a = book ? readerKey(e, keyboard.get().mode === "vim") : peekKey(e)
      if (!a) return
      // Space on a focused button presses it; the reader's buttons don't need it
      e.preventDefault()
      if (a === "next") next()
      else if (a === "prev") prev()
      else onBack()
    }
  })
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => act.current(e)
    // foliate-js lays out again from a ResizeObserver; the browser reports
    // that as an error although nothing is wrong
    const onError = (e: ErrorEvent) => {
      if (e.message?.includes("ResizeObserver loop")) e.stopImmediatePropagation()
    }
    window.addEventListener("keydown", onKey)
    window.addEventListener("error", onError, true)
    return () => {
      window.removeEventListener("keydown", onKey)
      window.removeEventListener("error", onError, true)
    }
  }, [])

  // E-Ink: taps instead of swipes; left third back, right third on, middle the bars
  const tap = useRef<(x: number) => void>(() => {})
  useEffect(() => {
    tap.current = (x) => {
      if (!eink) return
      const zone = tapZone(x, window.innerWidth)
      if (zone === "menu") setBars((b) => !b)
      else if (zone === "next") next()
      else prev()
    }
  })

  // --- the view --------------------------------------------------------------
  useEffect(() => {
    const el = host.current
    if (!el) return
    let gone = false
    const abort = new AbortController()
    let view: FoliateView | null = null
    // whatever the reason, the loading view ends: nothing else tells the
    // reader that the file stopped coming or that a book frame never opened
    let over = false
    let opening = false
    let uncaught: Error | null = null
    const finish = () => {
      over = true
      clock.stop()
      window.removeEventListener("error", onError)
      window.removeEventListener("unhandledrejection", onRejection)
      document.removeEventListener("visibilitychange", onVisible)
    }
    const fail = (e: unknown) => {
      if (gone || over) return
      finish()
      abort.abort()
      console.error(e)
      setFailure(e)
      setStatus("failed")
    }
    const clock = watchdog(STALL_LIMIT, () => fail(uncaught ?? new Error(t(opening ? "reader.openStalled" : "reader.stalled"))))
    // a phone locked on the way holds the timers and the download alike
    const onVisible = () => {
      if (document.visibilityState === "visible") clock.wait()
    }
    // foliate-js works in event handlers: what goes wrong in one reaches no
    // promise. It may be something else's, so the book gets a moment more.
    const onUncaught = (e: Error) => {
      uncaught ??= e
      clock.wait(UNCAUGHT_LIMIT)
    }
    const onError = (e: ErrorEvent) => onUncaught(e.error instanceof Error ? e.error : new Error(e.message))
    const onRejection = (e: PromiseRejectionEvent) => onUncaught(e.reason instanceof Error ? e.reason : new Error(String(e.reason)))
    document.addEventListener("visibilitychange", onVisible)
    ;(async () => {
      try {
        await import("foliate-js/view.js")
        const blob = await load(abort.signal, (received, total) => {
          clock.wait()
          setLoading(loadingText(received, total))
        })
        const file = new File([blob], name)
        if (gone) return
        opening = true
        setLoading(t("reader.opening"))
        clock.wait(OPEN_LIMIT)
        window.addEventListener("error", onError)
        window.addEventListener("unhandledrejection", onRejection)
        view = document.createElement("foliate-view") as FoliateView
        view.className = "block h-full w-full"
        el.append(view)
        viewRef.current = view
        let ready = false
        view.addEventListener("relocate", (e) => onRelocate.current((e as CustomEvent<RelocateDetail>).detail, ready))
        view.addEventListener("load", (e) => {
          const { doc } = (e as CustomEvent<{ doc: Document }>).detail
          doc.addEventListener("keydown", (k) => act.current(k))
          doc.addEventListener("click", (c) => {
            if ((c.target as Element | null)?.closest?.("a[href]") || doc.getSelection()?.toString()) return
            const frame = doc.defaultView?.frameElement as HTMLElement | null
            const r = frame?.getBoundingClientRect()
            const scale = r && frame!.offsetWidth ? r.width / frame!.offsetWidth : 1
            tap.current((r?.left ?? 0) + c.clientX * scale)
          })
          // E-Ink: no swiping inside the page, only taps
          if (eink) doc.defaultView?.addEventListener("touchmove", (m) => m.stopPropagation(), { capture: true })
        })
        await view.open(file)
        if (gone) return
        const isFixed = view.isFixedLayout
        setFixed(isFixed)
        setToc(view.book.toc ?? [])
        prepareBook(view)
        applyReaderSettings(view, settings, el.clientWidth)
        await view.init({ lastLocation: start.mine ? targetOf(start.mine, format) : null })
        ready = true
        if (gone) return
        finish()
        setStatus("ready")
      } catch (e) {
        fail(e)
      }
    })()
    return () => {
      gone = true
      finish()
      abort.abort()
      view?.close()
      view?.remove()
      viewRef.current = null
    }
    // settings change through their own effects below; the view opens once
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [name, format, attempt])

  const retry = () => {
    setLoading(undefined)
    setFailure(null)
    setStatus("loading")
    setAttempt((a) => a + 1)
  }

  useApplyReaderSettings(viewRef, host, status === "ready" && !fixed, settings)

  const pct = percent(loc.fraction)
  const goElsewhere = () => {
    const e = elsewhere
    setElsewhere(null)
    if (e) void viewRef.current?.goTo(targetOf(e, format))
  }

  // E-Ink: the bars lie over the page, so the page keeps its size (one redraw)
  const overlay = eink ? "absolute inset-x-0 z-10 bg-white" : ""
  return (
    <div style={chromeVars(settings.theme)} className="fixed inset-0 flex flex-col bg-background text-foreground pt-[env(safe-area-inset-top)] pr-[env(safe-area-inset-right)] pb-[env(safe-area-inset-bottom)] pl-[env(safe-area-inset-left)]" data-reader={status}>
      {bars && (
        <header className={cn("flex h-12 shrink-0 items-center gap-1 border-b px-1 eink:h-16 eink:border-b-2 eink:border-black", overlay, "top-0")}>
          <Button variant="ghost" size="icon" onClick={onBack} aria-label={t("reader.back")}>
            <ArrowLeft className="size-5" />
          </Button>
          <div className="min-w-0 flex-1 px-1">
            <h1 className="truncate text-sm font-semibold eink:text-base">{title}</h1>
            {loc.chapter && <p className="truncate text-xs text-muted-foreground eink:text-sm eink:text-black">{loc.chapter}</p>}
          </div>
          {book && <OfflineBadge className="mx-1" />}
          <Button variant="ghost" size="icon" onClick={() => setTocOpen(true)} aria-label={t("reader.toc")} disabled={status !== "ready"}>
            <List className="size-5" />
          </Button>
          <Button variant="ghost" size="icon" onClick={() => setSettingsOpen(true)} aria-label={t("reader.settings")} disabled={status !== "ready"}>
            <Type className="size-5" />
          </Button>
        </header>
      )}

      <main className="relative min-h-0 flex-1">
        {/* clicks in the book's pages come from its iframes (load event); these are the margins */}
        <div ref={host} className="absolute inset-0" onClick={(e) => tap.current(e.clientX)} />
        {status === "loading" && <p className="absolute inset-0 flex items-center justify-center text-muted-foreground eink:text-black">{loading ?? t("reader.loading")}</p>}
        {status === "failed" && (
          <div className="absolute inset-0 flex flex-col items-center justify-center gap-4 bg-background p-4 text-center">
            <p role="alert" className="font-medium">{t("reader.failed")}</p>
            {failure instanceof Error && <p className="text-sm text-muted-foreground eink:text-black">{failure.name === "PDFTimeout" ? t("reader.pdfTimeout") : failure.message}</p>}
            <div className="flex flex-wrap justify-center gap-2">
              <Button variant="outline" onClick={retry}>
                <RotateCcw /> {t("error.retry")}
              </Button>
              <BackButton onClick={onBack} />
            </div>
          </div>
        )}
        {elsewhere && status === "ready" && (
          <div role="alertdialog" aria-label={t("reader.elsewhere", { device: elsewhere.deviceName, percent: percent(elsewhere.fraction) })} className="absolute inset-x-2 top-2 z-20 mx-auto flex max-w-xl flex-wrap items-center gap-2 rounded-lg border bg-background p-3 shadow-lg eink:border-2 eink:border-black eink:shadow-none">
            <p className="min-w-0 flex-1 basis-60 text-sm eink:text-base">{t("reader.elsewhere", { device: elsewhere.deviceName, percent: percent(elsewhere.fraction) })}</p>
            <div className="flex gap-2">
              <Button size="sm" onClick={goElsewhere}>{t("reader.elsewhereYes")}</Button>
              <Button size="sm" variant="outline" onClick={() => setElsewhere(null)}>{t("reader.elsewhereNo")}</Button>
            </div>
          </div>
        )}
      </main>

      <footer className="flex shrink-0 items-center gap-2 border-t px-1 py-1 eink:border-t-2 eink:border-black eink:px-3">
        {!eink && (
          <Button variant="ghost" size="icon" onClick={prev} aria-label={t("reader.prev")} disabled={status !== "ready"}>
            <ChevronLeft className="size-5" />
          </Button>
        )}
        <div className="min-w-0 flex-1 px-1">
          <div role="progressbar" aria-label={t("reader.progress")} aria-valuemin={0} aria-valuemax={100} aria-valuenow={pct} aria-valuetext={t("reader.read.percent", { percent: pct })} className="h-1.5 overflow-hidden rounded-full bg-muted eink:h-2 eink:rounded-none eink:border eink:border-black eink:bg-white">
            <div className="h-full bg-primary eink:bg-black" style={{ width: `${pct}%` }} />
          </div>
          <p className="mt-1 flex gap-2 text-xs text-muted-foreground eink:text-sm eink:text-black">
            <span className="shrink-0 tabular-nums" data-percent>{pct} %</span>
            {note && <span className="shrink-0">· {note}</span>}
            {loc.chapter && <span className="truncate">· {loc.chapter}</span>}
          </p>
        </div>
        {!eink && (
          <Button variant="ghost" size="icon" onClick={next} aria-label={t("reader.next")} disabled={status !== "ready"}>
            <ChevronRight className="size-5" />
          </Button>
        )}
      </footer>

      <Sheet open={tocOpen} onOpenChange={setTocOpen}>
        <SheetContent side="left" aria-describedby={undefined} header={<SheetTitle>{t("reader.toc")}</SheetTitle>}>
          <nav className="min-h-0 flex-1 overflow-y-auto px-2 pb-4">
            {toc.length === 0 ? (
              <p className="p-2 text-muted-foreground eink:text-black">{t("reader.noToc")}</p>
            ) : (
              <TocList
                items={toc}
                current={loc.chapter}
                onPick={(href) => {
                  setTocOpen(false)
                  void viewRef.current?.goTo(href)
                }}
              />
            )}
          </nav>
        </SheetContent>
      </Sheet>

      <ReaderSettingsSheet
        open={settingsOpen}
        onOpenChange={setSettingsOpen}
        settings={accountSettings}
        update={updateSettings}
        eink={eink}
        extra={
          book && offlineSupported() && (
            <section className="space-y-2">
              <h2 className="text-sm font-medium">{t("offline.section")}</h2>
              <OfflineButton book={book} format={format} />
            </section>
          )
        }
      />
    </div>
  )
}

function TocList({ items, current, onPick, depth = 0 }: { items: TocItem[]; current: string | null; onPick: (href: string) => void; depth?: number }) {
  return (
    <ul className={cn(depth > 0 && "ml-4")}>
      {items.map((item, i) => (
        <li key={`${item.href}-${i}`}>
          <button
            type="button"
            onClick={() => onPick(item.href)}
            aria-current={item.label.trim() === current ? "true" : undefined}
            className="w-full rounded-md px-2 py-2 text-left hover:bg-accent aria-[current]:font-semibold eink:min-h-12 touch:min-h-11 eink:aria-[current]:underline"
          >
            {item.label.trim()}
          </button>
          {item.subitems && item.subitems.length > 0 && <TocList items={item.subitems} current={current} onPick={onPick} depth={depth + 1} />}
        </li>
      ))}
    </ul>
  )
}
