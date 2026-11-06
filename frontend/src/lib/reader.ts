import type { Book, ProgressEntry } from "./api"
import { looksLikeEink } from "./theme"

// Formats foliate-js opens, in the order the reader prefers them
export const READER_FORMATS = ["EPUB", "KEPUB", "AZW3", "MOBI", "AZW", "FB2", "CBZ", "PDF"] as const

export const readableFormats = (book: Pick<Book, "formats">) =>
  READER_FORMATS.filter((f) => book.formats.some((x) => x.toUpperCase() === f))

// The format to read: the wanted one if the reader can, else the preferred
export function readerFormat(book: Pick<Book, "formats">, wanted?: string | null): string | null {
  const ok = readableFormats(book)
  const w = wanted?.toUpperCase()
  return (w && (ok as string[]).includes(w) ? w : ok[0]) ?? null
}

// foliate-js tells the formats apart by content, except CBZ and FB2 (file name)
export const fileName = (id: number, format: string) => {
  const f = format.toLowerCase()
  return `book-${id}.${f === "kepub" ? "epub" : f}`
}

// 0.634 -> 63; never 100 before the last page
export const percent = (fraction: number) => Math.min(Math.floor(fraction * 100 + 1e-9), fraction >= 1 ? 100 : 99)

// --- this device -------------------------------------------------------------

const DEVICE_KEY = "hub.device"
const DEVICE_NAME_KEY = "hub.deviceName"

const randomId = () => (crypto.randomUUID ? crypto.randomUUID() : `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`)

// One id per browser, kept in localStorage; without storage a new one each time
let deviceId: string | null = null
export function getDeviceId(): string {
  if (deviceId) return deviceId
  try {
    deviceId = localStorage.getItem(DEVICE_KEY)
    if (!deviceId) {
      deviceId = randomId()
      localStorage.setItem(DEVICE_KEY, deviceId)
    }
  } catch {
    deviceId = randomId()
  }
  return deviceId
}

// "Firefox auf Linux", "Chrome auf Android", "Boox"
export function deviceLabel(ua: string): string {
  const eink = looksLikeEink(ua) && /\b(boox|onyx|kobo|kindle|pocketbook|remarkable)\b/i.exec(ua)?.[1]
  if (eink) return { boox: "Boox", onyx: "Boox", kobo: "Kobo", kindle: "Kindle", pocketbook: "PocketBook", remarkable: "reMarkable" }[eink.toLowerCase()] ?? eink
  const browser = /Edg\//.test(ua)
    ? "Edge"
    : /Firefox\//.test(ua)
      ? "Firefox"
      : /(Chrome|Chromium|CriOS)\//.test(ua)
        ? "Chrome"
        : /Safari\//.test(ua)
          ? "Safari"
          : "Browser"
  const os = /Android/.test(ua)
    ? "Android"
    : /iPad/.test(ua)
      ? "iPad"
      : /iPhone|iPod/.test(ua)
        ? "iPhone"
        : /Mac OS X|Macintosh/.test(ua)
          ? "macOS"
          : /Windows/.test(ua)
            ? "Windows"
            : /Linux|X11/.test(ua)
              ? "Linux"
              : null
  return os ? `${browser} auf ${os}` : browser
}

export function getDeviceName(): string {
  try {
    const own = localStorage.getItem(DEVICE_NAME_KEY)?.trim()
    if (own) return own.slice(0, 80)
  } catch {
    // ignore
  }
  return deviceLabel(navigator.userAgent)
}

// --- where to continue -------------------------------------------------------

export interface StartPoint {
  // what the reader opens at: this device's position, else the newest
  mine: ProgressEntry | null
  // newer than this device's and from another one: asked about
  elsewhere: ProgressEntry | null
}

// The newest position wins, but a book opens where this device stopped
// and asks before jumping to another device's newer one. Positions within
// a percent of each other are not worth asking about.
export function startPoint(devices: ProgressEntry[], device: string): StartPoint {
  const mine = devices.find((d) => d.device === device) ?? null
  const newest = [...devices].sort((a, b) => Date.parse(b.updatedAt) - Date.parse(a.updatedAt))[0] ?? null
  if (!newest || newest.device === device) return { mine, elsewhere: null }
  if (!mine) return { mine: newest, elsewhere: null }
  if (Math.abs(newest.fraction - mine.fraction) < 0.01) return { mine, elsewhere: null }
  return { mine, elsewhere: newest }
}

// Where foliate-js should go for a saved position: the position itself in
// the same format (PDF: page number, else a CFI), else the fraction
export type Target = string | number | { fraction: number }
export function targetOf(entry: Pick<ProgressEntry, "format" | "position" | "fraction">, format: string): Target {
  if (entry.format.toLowerCase() === format.toLowerCase() && entry.position) {
    if (format.toUpperCase() === "PDF") {
      const page = Number(entry.position)
      if (Number.isInteger(page) && page >= 1) return page - 1
    } else if (entry.position.startsWith("epubcfi(")) return entry.position
  }
  return { fraction: entry.fraction }
}

// What is saved for a location: PDFs by page (1-based, like KOReader),
// everything else by CFI
export const positionOf = (format: string, cfi: string, section: number) => (format.toUpperCase() === "PDF" ? String(section + 1) : cfi)

// The reader's settings (font, layout, colors) are per account:
// lib/reader-settings.ts

// --- keys --------------------------------------------------------------------

export type ReaderAction = "next" | "prev" | "back"

// The reader's own keys, apart from the library's keymap: arrows,
// PageUp/PageDown, Space (Shift+Space back), Escape; Vim mode adds j/k
// (and l/h).
export function readerKey(e: Pick<KeyboardEvent, "key" | "shiftKey" | "ctrlKey" | "metaKey" | "altKey">, vim: boolean): ReaderAction | null {
  if (e.ctrlKey || e.metaKey || e.altKey) return null
  switch (e.key) {
    case "ArrowRight":
    case "ArrowDown":
    case "PageDown":
      return "next"
    case "ArrowLeft":
    case "ArrowUp":
    case "PageUp":
      return "prev"
    case " ":
      return e.shiftKey ? "prev" : "next"
    case "Escape":
      return "back"
  }
  if (vim) {
    if (e.key === "j" || e.key === "l") return "next"
    if (e.key === "k" || e.key === "h") return "prev"
  }
  return null
}

// A look into a file from the Eingang: its keys, h and l whatever the mode.
// j and k stay out, they mean the list there.
export function peekKey(e: Pick<KeyboardEvent, "key" | "shiftKey" | "ctrlKey" | "metaKey" | "altKey">): ReaderAction | null {
  if (e.ctrlKey || e.metaKey || e.altKey) return null
  if (e.key === "h") return "prev"
  if (e.key === "l") return "next"
  return readerKey(e, false)
}

// E-Ink tap zones: left third back, right third on, the middle the toolbar
export const tapZone = (x: number, width: number): "prev" | "next" | "menu" => (x < width / 3 ? "prev" : x > (width * 2) / 3 ? "next" : "menu")

// Order in which formats are offered; the first is the primary button
// (detail) and what "Herunterladen" takes.
const FORMAT_ORDER = ["EPUB", "KEPUB", "AZW3", "MOBI", "PDF", "CBZ", "CBR", "DJVU", "TXT"]
export const sortFormats = (f: string[]) =>
  [...f].sort((a, b) => (FORMAT_ORDER.indexOf(a) + 1 || 99) - (FORMAT_ORDER.indexOf(b) + 1 || 99))
