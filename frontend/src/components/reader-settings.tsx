import { useCallback, useEffect, useRef, type CSSProperties, type ReactNode, type RefObject } from "react"
import { useQuery, useQueryClient } from "@tanstack/react-query"
import { Minus, Plus } from "lucide-react"
import type { FoliateView } from "foliate-js/view.js"
import { write } from "@/lib/api"
import { readerSettingsQuery } from "@/lib/queries"
import {
  COLUMN_MODES,
  DEFAULT_READER_SETTINGS,
  FONT_FAMILIES,
  FONT_STACKS,
  LINE_HEIGHTS,
  MARGINS,
  MAX_WIDTHS,
  READER_FLOWS,
  READER_THEMES,
  THEME_COLORS,
  bookCSS,
  fontFaces,
  normalize,
  rendererAttributes,
  scaleFontSizes,
  scaleFontSizesInMarkup,
  stepFontSize,
  type ReaderSettings,
} from "@/lib/reader-settings"
import { toast } from "@/lib/toast"
import { useMedia } from "@/lib/use-media"
import { cn } from "@/lib/utils"
import { t } from "@/i18n"
import type { MessageKey } from "@/i18n/de"
import { Button } from "@/components/ui/button"
import { Sheet, SheetContent, SheetTitle } from "@/components/ui/sheet"

const SAVE_DELAY = 600

// --- the settings ---------------------------------------------------------------

// The reader waits for the settings, but only for the first try: offline
// or with the hub away it opens with the defaults (or what it had).
export function useReaderSettingsReady(): boolean {
  const q = useQuery(readerSettingsQuery)
  return !(q.isPending && q.fetchStatus === "fetching" && q.failureCount === 0)
}

// The account's settings, changed at once here and saved shortly after
export function useReaderSettings() {
  const queryClient = useQueryClient()
  const { data } = useQuery(readerSettingsQuery)
  const pending = useRef<Partial<ReaderSettings>>({})
  const timer = useRef<ReturnType<typeof setTimeout>>(undefined)

  const flush = useCallback(
    (closing = false) => {
      clearTimeout(timer.current)
      const patch = pending.current
      if (Object.keys(patch).length === 0) return
      pending.current = {}
      write
        .saveReaderSettings(patch, closing)
        .then((saved) => {
          // newer changes are already shown; the hub's answer would undo them
          if (Object.keys(pending.current).length === 0) queryClient.setQueryData(readerSettingsQuery.queryKey, normalize(saved))
        })
        .catch(() => {
          if (!closing) toast.show(t("reader.s.saveFailed"))
        })
    },
    [queryClient],
  )

  const update = useCallback(
    (patch: Partial<ReaderSettings>) => {
      queryClient.setQueryData(readerSettingsQuery.queryKey, (old) => ({ ...(old ?? DEFAULT_READER_SETTINGS), ...patch }))
      pending.current = { ...pending.current, ...patch }
      clearTimeout(timer.current)
      timer.current = setTimeout(() => flush(), SAVE_DELAY)
    },
    [queryClient, flush],
  )

  useEffect(() => {
    const onHide = () => flush(true)
    window.addEventListener("pagehide", onHide)
    return () => {
      window.removeEventListener("pagehide", onHide)
      flush(true)
    }
  }, [flush])

  return { settings: data ?? DEFAULT_READER_SETTINGS, update }
}

// --- foliate-js -------------------------------------------------------------------

// Before the first section loads (after view.open): absolute font sizes in
// the book's CSS follow the reader's font size (lib/reader-settings.ts)
export function prepareBook(view: FoliateView) {
  const target = (view.book as { transformTarget?: EventTarget }).transformTarget
  target?.addEventListener("data", (e) => {
    const detail = (e as CustomEvent<{ data: unknown; type: string }>).detail
    const scale = detail.type === "text/css" ? scaleFontSizes : detail.type === "application/xhtml+xml" || detail.type === "text/html" ? scaleFontSizesInMarkup : null
    if (!scale) return
    detail.data = Promise.resolve(detail.data).then((d) => (typeof d === "string" ? scale(d) : d))
  })
}

const loadedFonts = new Map<string, string>()
const current = new WeakMap<FoliateView, ReaderSettings>()

// Puts the settings into the view: attributes at once, the stylesheet with
// the font's @font-face rules once they are loaded. Fixed layouts (PDF,
// comics) have neither.
export function applyReaderSettings(view: FoliateView, s: ReaderSettings, width: number) {
  if (view.isFixedLayout) return
  const r = view.renderer
  for (const [name, value] of Object.entries(rendererAttributes(s, width))) {
    // every setAttribute lays the book out again
    if (value === null) r.removeAttribute(name)
    else if (r.getAttribute(name) !== value) r.setAttribute(name, value)
  }
  const fonts = loadedFonts.get(s.fontFamily)
  r.setStyles?.(bookCSS(s, fonts ?? ""))
  if (fonts === undefined)
    void fontFaces(s.fontFamily).then((css) => {
      loadedFonts.set(s.fontFamily, css)
      if (css && current.get(view) === s) r.setStyles?.(bookCSS(s, css))
    }, () => {})
  current.set(view, s)
}

// Applies changed settings to an open view, and again when the width
// changes (two columns depend on it)
export function useApplyReaderSettings(view: RefObject<FoliateView | null>, host: RefObject<HTMLElement | null>, ready: boolean, s: ReaderSettings) {
  useEffect(() => {
    const v = view.current
    if (!ready || !v) return
    const apply = () => applyReaderSettings(v, s, host.current?.clientWidth ?? window.innerWidth)
    apply()
    if (s.columns !== "2") return
    window.addEventListener("resize", apply)
    return () => window.removeEventListener("resize", apply)
  }, [view, host, ready, s])
}

// --- the sheet ------------------------------------------------------------------

export function ReaderSettingsSheet({
  open,
  onOpenChange,
  settings: s,
  update,
  eink,
  extra,
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
  settings: ReaderSettings
  update: (patch: Partial<ReaderSettings>) => void
  eink: boolean
  // more sections below the settings (offline availability)
  extra?: ReactNode
}) {
  const narrow = useMedia("(max-width: 639px)")
  const step = <T extends number>(steps: readonly T[], value: number, dir: 1 | -1) => {
    const next = dir > 0 ? steps.find((x) => x > value) : [...steps].reverse().find((x) => x < value)
    return next ?? value
  }
  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent
        side={narrow ? "bottom" : "right"}
        aria-describedby={undefined}
        // the book stays visible behind it: changes show at once
        overlayClassName="bg-transparent"
        className="sm:max-w-sm"
        header={<SheetTitle>{t("reader.settings")}</SheetTitle>}
        data-reader-settings
      >
        <div className="min-h-0 flex-1 space-y-6 overflow-y-auto px-4 pb-4">
          <Section title={t("reader.s.font")}>
            <Stepper
              label={t("reader.fontSize")}
              value={`${s.fontSize} %`}
              less={t("reader.smaller")}
              more={t("reader.larger")}
              onLess={() => update({ fontSize: stepFontSize(s.fontSize, -1) })}
              onMore={() => update({ fontSize: stepFontSize(s.fontSize, 1) })}
              data="font-size"
            />
            <Choice
              label={t("reader.s.fontFamily")}
              options={FONT_FAMILIES}
              value={s.fontFamily}
              onChange={(fontFamily) => update({ fontFamily })}
              text={(f) => t(`reader.s.font.${f}` as MessageKey)}
              // only the system fonts in their own face: the bundled ones load when chosen
              style={(f) => (f === "serif" || f === "sans" ? { fontFamily: FONT_STACKS[f] } : undefined)}
              wide
            />
            <Stepper
              label={t("reader.s.lineHeight")}
              value={s.lineHeight.toLocaleString("de-DE")}
              less={t("reader.s.lineHeightLess")}
              more={t("reader.s.lineHeightMore")}
              onLess={() => update({ lineHeight: step(LINE_HEIGHTS, s.lineHeight, -1) })}
              onMore={() => update({ lineHeight: step(LINE_HEIGHTS, s.lineHeight, 1) })}
              data="line-height"
            />
          </Section>

          <Section title={t("reader.s.text")}>
            <Toggle label={t("reader.s.justify")} checked={s.justify} onChange={(justify) => update({ justify })} />
            <Toggle label={t("reader.s.hyphenate")} checked={s.hyphenate} onChange={(hyphenate) => update({ hyphenate })} />
            <Stepper
              label={t("reader.s.margin")}
              value={`${s.margin} %`}
              less={t("reader.s.marginLess")}
              more={t("reader.s.marginMore")}
              onLess={() => update({ margin: step(MARGINS, s.margin, -1) })}
              onMore={() => update({ margin: step(MARGINS, s.margin, 1) })}
              data="margin"
            />
            <Stepper
              label={t("reader.s.maxWidth")}
              value={`${s.maxWidth} px`}
              less={t("reader.s.maxWidthLess")}
              more={t("reader.s.maxWidthMore")}
              onLess={() => update({ maxWidth: step(MAX_WIDTHS, s.maxWidth, -1) })}
              onMore={() => update({ maxWidth: step(MAX_WIDTHS, s.maxWidth, 1) })}
              data="max-width"
            />
          </Section>

          <Section title={t("reader.s.pages")}>
            <Choice label={t("reader.s.columns")} options={COLUMN_MODES} value={s.columns} onChange={(columns) => update({ columns })} text={(c) => t(`reader.s.columns.${c}` as MessageKey)} />
            {!eink && (
              <>
                <Choice
                  label={t("reader.layout")}
                  options={READER_FLOWS}
                  value={s.flow}
                  onChange={(flow) => update({ flow })}
                  text={(f) => t(f === "paginated" ? "reader.paginated" : "reader.scrolled")}
                />
                <Toggle label={t("reader.s.animated")} checked={s.animated} onChange={(animated) => update({ animated })} />
              </>
            )}
          </Section>

          {eink ? (
            <p className="text-sm text-black">{t("reader.s.einkFixed")}</p>
          ) : (
            <Section title={t("reader.s.colors")}>
              <Choice
                label={t("reader.s.colors")}
                options={READER_THEMES}
                value={s.theme}
                onChange={(theme) => update({ theme })}
                text={(c) => t(`reader.s.theme.${c}` as MessageKey)}
                style={(c) => ({ background: THEME_COLORS[c].background, color: THEME_COLORS[c].text })}
                wide
              />
            </Section>
          )}

          <Section title={t("reader.s.override")}>
            <Toggle label={t("reader.s.override")} hint={t("reader.s.overrideHint")} checked={s.override} onChange={(override) => update({ override })} />
          </Section>

          {extra}

          <Button variant="outline" className="eink:min-h-12" onClick={() => update(DEFAULT_READER_SETTINGS)}>
            {t("reader.s.reset")}
          </Button>
        </div>
      </SheetContent>
    </Sheet>
  )
}

function Section({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="space-y-3">
      <h2 className="text-sm font-semibold text-muted-foreground eink:text-base eink:text-black">{title}</h2>
      {children}
    </section>
  )
}

function Stepper({ label, value, less, more, onLess, onMore, data }: { label: string; value: string; less: string; more: string; onLess: () => void; onMore: () => void; data: string }) {
  return (
    <div className="flex items-center gap-3">
      <span className="min-w-0 flex-1 text-sm eink:text-base">{label}</span>
      <Button variant="outline" size="icon" className="eink:size-12 touch:size-11" onClick={onLess} aria-label={less}>
        <Minus />
      </Button>
      <span className="w-16 text-center tabular-nums" data-setting={data}>
        {value}
      </span>
      <Button variant="outline" size="icon" className="eink:size-12 touch:size-11" onClick={onMore} aria-label={more}>
        <Plus />
      </Button>
    </div>
  )
}

function Choice<T extends string>({
  label,
  options,
  value,
  onChange,
  text,
  style,
  wide,
}: {
  label: string
  options: readonly T[]
  value: T
  onChange: (v: T) => void
  text: (v: T) => string
  style?: (v: T) => CSSProperties | undefined
  wide?: boolean
}) {
  return (
    <div className="space-y-2">
      <span className="text-sm eink:text-base">{label}</span>
      <div role="radiogroup" aria-label={label} className={cn("grid gap-2", wide ? "grid-cols-2" : "grid-cols-3")}>
        {options.map((o) => (
          <button
            key={o}
            type="button"
            role="radio"
            aria-checked={value === o}
            onClick={() => onChange(o)}
            style={style?.(o)}
            className="min-h-10 rounded-md border px-2 py-1.5 text-sm outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50 aria-checked:border-2 aria-checked:border-primary aria-checked:font-semibold eink:min-h-12 eink:border-black eink:text-base touch:min-h-11 eink:aria-checked:border-4"
          >
            {text(o)}
          </button>
        ))}
      </div>
    </div>
  )
}

function Toggle({ label, hint, checked, onChange }: { label: string; hint?: string; checked: boolean; onChange: (v: boolean) => void }) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      onClick={() => onChange(!checked)}
      className="flex min-h-10 w-full items-center gap-3 rounded-md text-left outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50 eink:min-h-12 touch:min-h-11"
    >
      <span className="min-w-0 flex-1">
        <span className="block text-sm eink:text-base">{label}</span>
        {hint && <span className="block text-xs text-muted-foreground eink:text-sm eink:text-black">{hint}</span>}
      </span>
      <span
        aria-hidden
        className={cn(
          "relative h-6 w-11 shrink-0 rounded-full border transition-colors eink:h-8 eink:w-14 eink:border-2 eink:border-black",
          checked ? "bg-primary" : "bg-muted",
        )}
      >
        <span className={cn("absolute top-0.5 size-[1.125rem] rounded-full bg-background shadow transition-transform eink:size-6 eink:border-2 eink:border-black eink:shadow-none", checked ? "translate-x-5 eink:translate-x-6" : "translate-x-0.5")} />
      </span>
    </button>
  )
}
