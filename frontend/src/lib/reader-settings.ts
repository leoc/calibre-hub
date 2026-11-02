// Reader settings (GET/PUT /api/reader/settings): one set per account, the
// same on every device. This module turns them into what foliate-js takes:
// a stylesheet for the book's documents (renderer.setStyles) and the
// paginator's attributes. The reader UI is components/reader-settings.tsx.

export const FONT_FAMILIES = ["original", "serif", "sans", "literata", "atkinson", "source-serif", "inter"] as const
export type FontFamily = (typeof FONT_FAMILIES)[number]
export const COLUMN_MODES = ["auto", "1", "2"] as const
export type Columns = (typeof COLUMN_MODES)[number]
export const READER_FLOWS = ["paginated", "scrolled"] as const
export type ReaderFlow = (typeof READER_FLOWS)[number]
export const READER_THEMES = ["light", "sepia", "dark", "eink"] as const
export type ReaderTheme = (typeof READER_THEMES)[number]

export interface ReaderSettings {
  fontFamily: FontFamily
  // percent of the browser's size
  fontSize: number
  lineHeight: number
  justify: boolean
  hyphenate: boolean
  // percent of the page width on each side (foliate-js' gap)
  margin: number
  // px per column
  maxWidth: number
  columns: Columns
  flow: ReaderFlow
  animated: boolean
  theme: ReaderTheme
  // force the settings against the book's own CSS
  override: boolean
}

// as in src/calibre_hub/reader_settings.cr
export const DEFAULT_READER_SETTINGS: ReaderSettings = {
  fontFamily: "original",
  fontSize: 100,
  lineHeight: 1.5,
  justify: true,
  hyphenate: true,
  margin: 6,
  maxWidth: 720,
  columns: "auto",
  flow: "paginated",
  animated: true,
  theme: "light",
  override: false,
}

export const LIMITS = {
  fontSize: [50, 300],
  lineHeight: [1, 2.5],
  margin: [0, 20],
  maxWidth: [400, 2000],
} as const satisfies Record<string, readonly [number, number]>

export const FONT_SIZE_STEPS = [70, 80, 90, 100, 110, 120, 135, 150, 175, 200, 250, 300] as const
export const LINE_HEIGHTS = [1.2, 1.35, 1.5, 1.65, 1.8, 2] as const
export const MARGINS = [2, 4, 6, 8, 10, 14] as const
export const MAX_WIDTHS = [560, 640, 720, 800, 960, 1200] as const

// the next step up or down from any size
export function stepFontSize(size: number, dir: 1 | -1): number {
  const steps = FONT_SIZE_STEPS as readonly number[]
  const next = dir > 0 ? steps.find((s) => s > size) : [...steps].reverse().find((s) => s < size)
  return next ?? size
}

// Whatever the hub sends (an older hub: nothing) as complete, valid settings
export function normalize(raw: unknown): ReaderSettings {
  const r = (raw && typeof raw === "object" ? raw : {}) as Record<string, unknown>
  const d = DEFAULT_READER_SETTINGS
  const oneOf = <T extends string>(v: unknown, allowed: readonly T[], fallback: T): T => (allowed.includes(v as T) ? (v as T) : fallback)
  const num = (v: unknown, [lo, hi]: readonly [number, number], fallback: number) => (typeof v === "number" && v >= lo && v <= hi ? v : fallback)
  const bool = (v: unknown, fallback: boolean) => (typeof v === "boolean" ? v : fallback)
  return {
    fontFamily: oneOf(r.fontFamily, FONT_FAMILIES, d.fontFamily),
    fontSize: Math.round(num(r.fontSize, LIMITS.fontSize, d.fontSize)),
    lineHeight: num(r.lineHeight, LIMITS.lineHeight, d.lineHeight),
    justify: bool(r.justify, d.justify),
    hyphenate: bool(r.hyphenate, d.hyphenate),
    margin: Math.round(num(r.margin, LIMITS.margin, d.margin)),
    maxWidth: Math.round(num(r.maxWidth, LIMITS.maxWidth, d.maxWidth)),
    columns: oneOf(r.columns, COLUMN_MODES, d.columns),
    flow: oneOf(r.flow, READER_FLOWS, d.flow),
    animated: bool(r.animated, d.animated),
    theme: oneOf(r.theme, READER_THEMES, d.theme),
    override: bool(r.override, d.override),
  }
}

// What a device actually uses: E-Ink never animates, never scrolls and
// shows black on white
export const effectiveSettings = (s: ReaderSettings, eink: boolean): ReaderSettings =>
  eink ? { ...s, animated: false, flow: "paginated", theme: "eink" } : s

// --- colors ------------------------------------------------------------------

export interface ThemeColors {
  background: string
  text: string
  link: string
  dark: boolean
}

export const THEME_COLORS: Record<ReaderTheme, ThemeColors> = {
  light: { background: "#ffffff", text: "#1c1917", link: "#1d4ed8", dark: false },
  sepia: { background: "#f4ecd8", text: "#4b3a2a", link: "#8a4b14", dark: false },
  dark: { background: "#18181b", text: "#e4e4e7", link: "#93c5fd", dark: true },
  eink: { background: "#ffffff", text: "#000000", link: "#000000", dark: false },
}

// The reader's bars in the book's colors (the app's tokens, see index.css)
export function chromeVars(theme: ReaderTheme): Record<string, string> {
  const c = THEME_COLORS[theme]
  const muted = c.dark ? "#27272a" : theme === "sepia" ? "#e9dfc6" : "#f4f4f5"
  const mutedText = theme === "eink" ? "#000000" : c.dark ? "#a1a1aa" : theme === "sepia" ? "#7a6450" : "#71717a"
  const border = theme === "eink" ? "#000000" : c.dark ? "#3f3f46" : theme === "sepia" ? "#d8c9a7" : "#e4e4e7"
  return {
    "--background": c.background,
    "--foreground": c.text,
    "--muted": muted,
    "--muted-foreground": mutedText,
    "--accent": muted,
    "--accent-foreground": c.text,
    "--border": border,
    "--primary": c.text,
    "--primary-foreground": c.background,
    colorScheme: c.dark ? "dark" : "light",
  }
}

// --- fonts -------------------------------------------------------------------

export const FONT_STACKS: Record<Exclude<FontFamily, "original">, string> = {
  serif: `Georgia, "Times New Roman", serif`,
  sans: `system-ui, -apple-system, "Segoe UI", Roboto, sans-serif`,
  literata: `"Literata Variable", Georgia, serif`,
  atkinson: `"Atkinson Hyperlegible", system-ui, sans-serif`,
  "source-serif": `"Source Serif 4 Variable", Georgia, serif`,
  inter: `"Inter Variable", system-ui, sans-serif`,
}

export type BundledFont = "literata" | "atkinson" | "source-serif" | "inter"
export const isBundled = (f: FontFamily): f is BundledFont => f === "literata" || f === "atkinson" || f === "source-serif" || f === "inter"

// The @font-face rules of the fonts that come with the hub (@fontsource,
// SIL OFL), loaded only once chosen. Vite turns their url()s into the
// hub's own asset paths; the book's documents are blob: URLs, so the paths
// need the origin.
const fontLoaders: Record<BundledFont, () => Promise<string[]>> = {
  literata: () => Promise.all([import("@fontsource-variable/literata/wght.css?inline"), import("@fontsource-variable/literata/wght-italic.css?inline")]).then((m) => m.map((x) => x.default)),
  "source-serif": () =>
    Promise.all([import("@fontsource-variable/source-serif-4/wght.css?inline"), import("@fontsource-variable/source-serif-4/wght-italic.css?inline")]).then((m) => m.map((x) => x.default)),
  inter: () => Promise.all([import("@fontsource-variable/inter/wght.css?inline"), import("@fontsource-variable/inter/wght-italic.css?inline")]).then((m) => m.map((x) => x.default)),
  atkinson: () =>
    Promise.all([
      import("@fontsource/atkinson-hyperlegible/400.css?inline"),
      import("@fontsource/atkinson-hyperlegible/400-italic.css?inline"),
      import("@fontsource/atkinson-hyperlegible/700.css?inline"),
      import("@fontsource/atkinson-hyperlegible/700-italic.css?inline"),
    ]).then((m) => m.map((x) => x.default)),
}

export const absoluteFontUrls = (css: string, origin: string) =>
  css.replace(/url\(\s*(["']?)(\/(?!\/)[^"')]*)\1\s*\)/g, (_, q: string, path: string) => `url(${q}${origin}${path}${q})`)

const fontCache = new Map<BundledFont, Promise<string>>()
export function fontFaces(font: FontFamily): Promise<string> {
  if (!isBundled(font)) return Promise.resolve("")
  let p = fontCache.get(font)
  if (!p) {
    p = fontLoaders[font]().then((parts) => absoluteFontUrls(parts.join("\n"), location.origin))
    p.catch(() => fontCache.delete(font))
    fontCache.set(font, p)
  }
  return p
}

// --- font sizes in the book ----------------------------------------------------

// Books often size their text absolutely (font-size: small, 12pt, 1rem).
// Such sizes don't follow a size set on <body>, so the reader's font size
// did nothing for them. They are rewritten to follow --hub-font-scale,
// which the reader's stylesheet sets; relative sizes (em, %) follow <body>.
const KEYWORDS: Record<string, number> = {
  "xx-small": 9,
  "x-small": 10,
  small: 13,
  medium: 16,
  large: 18,
  "x-large": 24,
  "xx-large": 32,
  "xxx-large": 48,
}
const PX_PER: Record<string, number> = { px: 1, pt: 4 / 3, pc: 16, in: 96, cm: 96 / 2.54, mm: 96 / 25.4, q: 96 / 101.6 }
const round = (n: number) => Math.round(n * 1000) / 1000

// one font-size value scaled, or null when it is relative
export function scaledSize(value: string): string | null {
  const v = value.trim().toLowerCase()
  if (v in KEYWORDS) return `calc(${KEYWORDS[v]}px * var(--hub-font-scale, 1))`
  const m = /^(\d*\.?\d+)(px|pt|pc|in|cm|mm|q|rem)$/.exec(v)
  if (!m) return null
  const n = Number(m[1])
  if (m[2] === "rem") return `calc(${round(n)}rem * var(--hub-font-scale, 1))`
  return `calc(${round(n * PX_PER[m[2]])}px * var(--hub-font-scale, 1))`
}

// the size in a `font` shorthand ("bold 12pt/1.4 Georgia")
const SIZE_TOKEN = /^(xx-small|x-small|small|medium|large|x-large|xx-large|xxx-large|\d*\.?\d+(?:px|pt|pc|in|cm|mm|q|rem))(\/.*)?$/i
function scaleShorthand(value: string): string {
  const tokens = value.split(/(\s+)/)
  const i = tokens.findIndex((t) => SIZE_TOKEN.test(t))
  if (i < 0) return value
  const [, size, rest = ""] = SIZE_TOKEN.exec(tokens[i])!
  tokens[i] = `${scaledSize(size)}${rest}`
  return tokens.join("")
}

const DECLARATION = /(^|[{;\s"'])(font-size|font)(\s*:\s*)([^;{}"!]+)/gi
function scaleDeclarations(css: string): string {
  return css.replace(DECLARATION, (all, pre: string, prop: string, colon: string, value: string) => {
    const trailing = /\s*$/.exec(value)![0]
    const v = value.slice(0, value.length - trailing.length)
    // `font: inherit`, system fonts and the like stay
    const scaled = prop.toLowerCase() === "font-size" ? scaledSize(v) : scaleShorthand(v)
    return scaled && scaled !== v ? `${pre}${prop}${colon}${scaled}${trailing}` : all
  })
}

// A stylesheet with absolute font sizes scaled; rules for the root
// (html, :root) keep theirs, so books sized in rem scale once
export function scaleFontSizes(css: string): string {
  return css.replace(/([^{}]*)\{([^{}]*)\}/g, (all, selector: string, body: string) =>
    /(^|[\s,>+~(])(html|:root)(?![\w-])/i.test(selector.replace(/^[\s\S]*[{;]/, "")) ? all : `${selector}{${scaleDeclarations(body)}}`,
  )
}

// An (X)HTML document: its <style> elements and style attributes
export function scaleFontSizesInMarkup(html: string): string {
  return html
    .replace(/(<style\b[^>]*>)([\s\S]*?)(<\/style>)/gi, (_, open: string, css: string, close: string) => open + scaleFontSizes(css) + close)
    .replace(/(\sstyle\s*=\s*)(["'])([\s\S]*?)\2/gi, (_, attr: string, q: string, css: string) => `${attr}${q}${scaleDeclarations(css)}${q}`)
}

// --- the stylesheet for the book -----------------------------------------------

const TEXT = "p, li, blockquote, dd"

export function bookCSS(s: ReaderSettings, fonts = ""): string {
  const c = THEME_COLORS[s.theme]
  const imp = s.override ? " !important" : ""
  const family = s.fontFamily === "original" ? null : FONT_STACKS[s.fontFamily]
  const align = s.justify ? "justify" : "start"
  const hyphens = s.hyphenate ? "auto" : "manual"
  // the theme's colors: forced everywhere except for the light theme, which
  // keeps the book's own colors unless the book's style is overridden
  const forceColors = s.theme !== "light" || s.override
  return `${fonts}
html {
  color-scheme: ${c.dark ? "dark" : "light"};
  --hub-font-scale: ${s.fontSize / 100};
  background: ${c.background} !important;
}
body {
  font-size: ${s.fontSize}% !important;
  color: ${c.text}${forceColors ? " !important" : ""};
  background: transparent !important;
  ${family ? `font-family: ${family}${imp};` : ""}
}
${
  s.override
    ? `body *:not(${["h1", "h2", "h3", "h4", "h5", "h6"].join(", ")}) { line-height: ${s.lineHeight} !important; }
${family ? `body *:not(code, kbd, pre, samp, tt, code *, pre *, svg *, math *) { font-family: ${family} !important; }` : ""}`
    : `${TEXT} { line-height: ${s.lineHeight}; }`
}
${TEXT} {
  text-align: ${align}${imp};
  hyphens: ${hyphens}${imp};
  -webkit-hyphens: ${hyphens}${imp};
  widows: 2;
  orphans: 2;
}
${
  forceColors
    ? `body *:not(img, svg, svg *, video, math *) { color: inherit !important; background-color: transparent !important; }
a:link, a:visited { color: ${c.link} !important; }`
    : `a:link { color: ${c.link}; }`
}
${s.theme === "eink" ? "a { text-decoration: underline !important; }" : ""}
${c.dark ? "img, svg, video { background: #fff; }" : ""}
pre { white-space: pre-wrap !important; }
`
}

// --- the paginator -------------------------------------------------------------

// foliate-js' paginator attributes; null removes one. "2" columns: a
// column at most half the width, so two fit (foliate-js shows one column
// in portrait anyway).
export function rendererAttributes(s: ReaderSettings, width: number): Record<string, string | null> {
  const half = Math.max(200, Math.floor(width / 2))
  const inline = s.columns === "2" ? Math.min(s.maxWidth, half) : s.maxWidth
  return {
    flow: s.flow,
    gap: `${s.margin}%`,
    "max-inline-size": `${inline}px`,
    "max-column-count": s.columns === "1" ? "1" : "2",
    animated: s.animated ? "" : null,
  }
}
