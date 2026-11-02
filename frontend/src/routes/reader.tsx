import { useCallback, useEffect, useRef, useState, type ReactNode } from "react"
import { getRouteApi, useCanGoBack, useNavigate, useRouter } from "@tanstack/react-router"
import { useQuery, useQueryClient } from "@tanstack/react-query"
import { ArrowLeft, ChevronLeft, ChevronRight, List, Minus, Plus, Type } from "lucide-react"
import type { FoliateView, RelocateDetail, TocItem } from "foliate-js/view.js"
import { ApiError, type Book, type ProgressEntry, type ProgressSave } from "@/lib/api"
import { bookQuery, progressQuery } from "@/lib/queries"
import { loadBookFile, offlineSupported, refreshOffline, useOfflineBook } from "@/lib/offline"
import { isNetworkError, useOnline } from "@/lib/online"
import { queuedProgress, saveProgress, withQueued } from "@/lib/progress-sync"
import { OfflineBadge, OfflineButton } from "@/components/offline"
import {
  fileName,
  getDeviceId,
  getDeviceName,
  percent,
  positionOf,
  readerFormat,
  readerKey,
  readerPrefs,
  startPoint,
  stepFontSize,
  tapZone,
  targetOf,
  type Flow,
  type StartPoint,
} from "@/lib/reader"
import { keyboard } from "@/lib/keyboard"
import { useTheme } from "@/lib/theme"
import { cn } from "@/lib/utils"
import { t } from "@/i18n"
import { Button } from "@/components/ui/button"
import { Sheet, SheetContent, SheetTitle } from "@/components/ui/sheet"
import { ErrorMessage } from "@/components/error-view"

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
  if (!data || !devices) {
    if (!online && !stored) return <Centered><p role="alert">{t("reader.notOffline")}</p><BackButton onClick={back} /></Centered>
    return <Centered><p className="text-muted-foreground eink:text-black">{t("reader.loading")}</p></Centered>
  }
  // the stored format unless another one is asked for, so the reader
  // doesn't reopen when the hub answers again
  const format = stored && (!wanted || wanted.toUpperCase() === stored.format) ? stored.format : readerFormat(data, wanted)
  if (!format) return <Centered><p role="alert">{t("reader.noFormat")}</p><BackButton onClick={back} /></Centered>
  const start = startPoint(withQueued(devices, queuedProgress(id)), getDeviceId())
  return <Reader key={`${id}-${format}`} book={data} format={format} start={start} onBack={back} />
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

// Styles put into the book's documents (reflowable formats only)
function bookCSS(fontSize: number, dark: boolean, eink: boolean) {
  return `
    html { color-scheme: ${dark ? "dark" : "light"}; }
    body { font-size: ${fontSize}% !important; }
    ${eink ? "body, p, li, h1, h2, h3, h4, h5, h6, blockquote, a { color: #000 !important; } a { text-decoration: underline !important; }" : ""}
    ${dark ? "body { color: #e4e4e7; } a:link { color: #93c5fd; }" : ""}
    p, li, blockquote, dd { line-height: 1.5; hyphens: auto; -webkit-hyphens: auto; widows: 2; orphans: 2; }
    pre { white-space: pre-wrap !important; }
  `
}

interface Location {
  fraction: number
  chapter: string | null
}

const SAVE_DELAY = 1500

function Reader({ book, format, start, onBack }: { book: Book; format: string; start: StartPoint; onBack: () => void }) {
  const { eink } = useTheme()
  const queryClient = useQueryClient()
  const host = useRef<HTMLDivElement>(null)
  const viewRef = useRef<FoliateView | null>(null)
  const [status, setStatus] = useState<"loading" | "ready" | "failed">("loading")
  const [failure, setFailure] = useState<unknown>(null)
  const [loc, setLoc] = useState<Location>({ fraction: start.mine?.fraction ?? 0, chapter: null })
  const [toc, setToc] = useState<TocItem[]>([])
  const [fixed, setFixed] = useState(false)
  const [elsewhere, setElsewhere] = useState<ProgressEntry | null>(start.elsewhere)
  const [tocOpen, setTocOpen] = useState(false)
  const [settingsOpen, setSettingsOpen] = useState(false)
  // E-Ink: the bars only after a tap in the middle
  const [bars, setBars] = useState(!eink)
  const [fontSize, setFontSize] = useState(readerPrefs.fontSize)
  const [flow, setFlowState] = useState<Flow>(() => (eink ? "paginated" : readerPrefs.flow()))
  const overlayOpen = tocOpen || settingsOpen

  // --- saving: debounced, and right away when leaving -----------------------
  const pending = useRef<ProgressSave | null>(null)
  const saved = useRef<string | null>(start.mine && start.mine.format === format.toLowerCase() ? start.mine.position : null)
  const timer = useRef<ReturnType<typeof setTimeout>>(undefined)
  const flush = useCallback(
    (closing = false) => {
      clearTimeout(timer.current)
      const p = pending.current
      if (!p) return
      pending.current = null
      saved.current = p.position
      // queued first; offline it waits there for the next contact
      void saveProgress(book.id, p, closing).then((entry) => {
        if (entry) void queryClient.invalidateQueries({ queryKey: ["progress"] })
      })
    },
    [book.id, queryClient],
  )

  const onRelocate = useRef<(d: RelocateDetail, ready: boolean) => void>(() => {})
  useEffect(() => {
    onRelocate.current = (d, ready) => {
      const view = viewRef.current
      const section = d.section?.current ?? 0
      // fixed layout (PDF, comics): page n of N, so the last page is 100 %
      const fraction = view?.isFixedLayout && d.section ? Math.min(1, (section + 1) / d.section.total) : d.fraction
      setLoc({ fraction, chapter: d.tocItem?.label?.trim() || null })
      if (!ready) return
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
      const a = readerKey(e, keyboard.get().mode === "vim")
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
    ;(async () => {
      try {
        await import("foliate-js/view.js")
        const file = new File([await loadBookFile(book.id, format, abort.signal)], fileName(book.id, format))
        if (gone) return
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
        if (!isFixed) {
          view.renderer.setAttribute("flow", flow)
          view.renderer.setStyles?.(bookCSS(fontSize, document.documentElement.classList.contains("dark"), eink))
        }
        if (!eink) view.renderer.setAttribute("animated", "")
        await view.init({ lastLocation: start.mine ? targetOf(start.mine, format) : null })
        ready = true
        if (!gone) setStatus("ready")
      } catch (e) {
        if (gone) return
        console.error(e)
        setFailure(e)
        setStatus("failed")
      }
    })()
    return () => {
      gone = true
      abort.abort()
      view?.close()
      view?.remove()
      viewRef.current = null
    }
    // settings change through their own effects below; the view opens once
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [book.id, format])

  useEffect(() => {
    const view = viewRef.current
    if (status !== "ready" || !view || fixed) return
    view.renderer.setStyles?.(bookCSS(fontSize, document.documentElement.classList.contains("dark"), eink))
    view.renderer.setAttribute("flow", flow)
  }, [status, fixed, fontSize, flow, eink])

  const changeFont = (dir: 1 | -1) => {
    const n = stepFontSize(fontSize, dir)
    readerPrefs.setFontSize(n)
    setFontSize(n)
  }
  const setFlow = (f: Flow) => {
    readerPrefs.setFlow(f)
    setFlowState(f)
  }

  const pct = percent(loc.fraction)
  const goElsewhere = () => {
    const e = elsewhere
    setElsewhere(null)
    if (e) void viewRef.current?.goTo(targetOf(e, format))
  }

  // E-Ink: the bars lie over the page, so the page keeps its size (one redraw)
  const overlay = eink ? "absolute inset-x-0 z-10 bg-white" : ""
  return (
    <div className="fixed inset-0 flex flex-col bg-background pt-[env(safe-area-inset-top)] pr-[env(safe-area-inset-right)] pb-[env(safe-area-inset-bottom)] pl-[env(safe-area-inset-left)]" data-reader={status}>
      {bars && (
        <header className={cn("flex h-12 shrink-0 items-center gap-1 border-b px-1 eink:h-16 eink:border-b-2 eink:border-black", overlay, "top-0")}>
          <Button variant="ghost" size="icon" onClick={onBack} aria-label={t("reader.back")}>
            <ArrowLeft className="size-5" />
          </Button>
          <div className="min-w-0 flex-1 px-1">
            <h1 className="truncate text-sm font-semibold eink:text-base">{book.title}</h1>
            {loc.chapter && <p className="truncate text-xs text-muted-foreground eink:text-sm eink:text-black">{loc.chapter}</p>}
          </div>
          <OfflineBadge className="mx-1" />
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
        {status === "loading" && <p className="absolute inset-0 flex items-center justify-center text-muted-foreground eink:text-black">{t("reader.loading")}</p>}
        {status === "failed" && (
          <div className="absolute inset-0 flex flex-col items-center justify-center gap-4 bg-background p-4 text-center">
            <p role="alert" className="font-medium">{t("reader.failed")}</p>
            {failure instanceof Error && <p className="text-sm text-muted-foreground eink:text-black">{failure.message}</p>}
            <BackButton onClick={onBack} />
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

      <Sheet open={settingsOpen} onOpenChange={setSettingsOpen}>
        <SheetContent side="right" aria-describedby={undefined} className="sm:max-w-sm" header={<SheetTitle>{t("reader.settings")}</SheetTitle>}>
          <div className="space-y-6 px-4 pb-4">
            {!fixed && (
              <section className="space-y-2">
                <h2 className="text-sm font-medium">{t("reader.fontSize")}</h2>
                <div className="flex items-center gap-3">
                  <Button variant="outline" size="icon" onClick={() => changeFont(-1)} aria-label={t("reader.smaller")}>
                    <Minus />
                  </Button>
                  <span className="w-14 text-center tabular-nums" data-font-size>{fontSize} %</span>
                  <Button variant="outline" size="icon" onClick={() => changeFont(1)} aria-label={t("reader.larger")}>
                    <Plus />
                  </Button>
                </div>
              </section>
            )}
            {!eink && !fixed && (
              <section className="space-y-2">
                <h2 className="text-sm font-medium">{t("reader.layout")}</h2>
                <div role="radiogroup" aria-label={t("reader.layout")} className="flex gap-2">
                  {(["paginated", "scrolled"] as const).map((f) => (
                    <Button key={f} role="radio" aria-checked={flow === f} variant={flow === f ? "default" : "outline"} onClick={() => setFlow(f)}>
                      {t(f === "paginated" ? "reader.paginated" : "reader.scrolled")}
                    </Button>
                  ))}
                </div>
              </section>
            )}
            {offlineSupported() && (
              <section className="space-y-2">
                <h2 className="text-sm font-medium">{t("offline.section")}</h2>
                <OfflineButton book={book} format={format} />
              </section>
            )}
          </div>
        </SheetContent>
      </Sheet>
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
