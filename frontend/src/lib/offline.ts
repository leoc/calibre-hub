import { useMemo, useSyncExternalStore } from "react"
import { api, ApiError, downloadUrl, type Book, type ProgressEntry } from "./api"
import { locale } from "@/i18n"

// Books made available offline: the file in Cache Storage ("hub-books",
// under its download URL), the book and every device's last position in
// localStorage ("hub.offline"), so the reader opens without the hub. The
// service worker (src/service-worker.js) never caches /api/ itself; only
// what is stored here on purpose is kept.

export const BOOKS_CACHE = "hub-books"
const KEY = "hub.offline"

export interface OfflineBook {
  book: Book
  // the stored format, upper case like readerFormat()
  format: string
  // bytes
  size: number
  savedAt: string
  // every device's position when last online: where the reader starts offline
  progress: ProgressEntry[]
}

type Index = Record<string, OfflineBook>

let index: Index | null = null
const listeners = new Set<() => void>()

function read(): Index {
  if (index) return index
  try {
    const v = JSON.parse(localStorage.getItem(KEY) ?? "{}")
    index = v && typeof v === "object" ? (v as Index) : {}
  } catch {
    index = {}
  }
  return index
}

function store(next: Index) {
  index = next
  try {
    localStorage.setItem(KEY, JSON.stringify(next))
  } catch {
    // full or blocked: kept for this page only
  }
  listeners.forEach((l) => l())
}

function subscribe(cb: () => void) {
  listeners.add(cb)
  // another tab stored or removed a book
  const onStorage = (e: StorageEvent) => {
    if (e.key !== KEY && e.key !== null) return
    index = null
    cb()
  }
  window.addEventListener("storage", onStorage)
  return () => {
    listeners.delete(cb)
    window.removeEventListener("storage", onStorage)
  }
}

// Cache Storage needs a secure context (https or localhost)
export const offlineSupported = () => typeof caches !== "undefined"

export const getOfflineBook = (id: number): OfflineBook | null => read()[id] ?? null

export const sortOffline = (books: OfflineBook[]) => [...books].sort((a, b) => a.book.title.localeCompare(b.book.title, locale))

export const useOfflineBook = (id: number) => useSyncExternalStore(subscribe, () => read()[id] ?? null, () => null)

const NONE: Index = {}
export function useOfflineBooks(): OfflineBook[] {
  const all = useSyncExternalStore(subscribe, read, () => NONE)
  return useMemo(() => sortOffline(Object.values(all)), [all])
}

export async function makeOffline(book: Book, format: string): Promise<OfflineBook> {
  const url = downloadUrl(book.id, format)
  const res = await fetch(url, { credentials: "same-origin" })
  if (!res.ok) throw new ApiError(res.status, res.statusText)
  const blob = await res.blob()
  const cache = await caches.open(BOOKS_CACHE)
  // only the file: no cookies or other headers of the response
  await cache.put(url, new Response(blob, { headers: { "Content-Type": res.headers.get("Content-Type") || "application/octet-stream" } }))
  const progress = await api
    .progress(book.id)
    .then((p) => p.devices)
    .catch(() => getOfflineBook(book.id)?.progress ?? [])
  // asks the browser not to evict it under storage pressure (best effort)
  void navigator.storage?.persist?.().catch(() => false)
  const entry: OfflineBook = { book, format: format.toUpperCase(), size: blob.size, savedAt: new Date().toISOString(), progress }
  store({ ...read(), [book.id]: entry })
  return entry
}

export async function removeOffline(id: number) {
  const entry = getOfflineBook(id)
  if (!entry) return
  if (offlineSupported()) await caches.open(BOOKS_CACHE).then((c) => c.delete(downloadUrl(id, entry.format)))
  const { [id]: _gone, ...rest } = read()
  store(rest)
}

// Logging out: nothing of the account stays in the browser
export async function clearOffline() {
  store({})
  if (offlineSupported()) await caches.delete(BOOKS_CACHE).catch(() => false)
}

// The book's file: from the offline store when it is there, else the hub
export async function loadBookFile(id: number, format: string, signal?: AbortSignal): Promise<Blob> {
  const url = downloadUrl(id, format)
  if (offlineSupported() && getOfflineBook(id)) {
    const hit = await caches.match(url, { cacheName: BOOKS_CACHE }).catch(() => undefined)
    if (hit) return hit.blob()
  }
  const res = await fetch(url, { credentials: "same-origin", signal })
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`)
  return res.blob()
}

// Keeps an offline book's data as fresh as what the hub last said
export function refreshOffline(id: number, update: { book?: Book; progress?: ProgressEntry[] }) {
  const entry = getOfflineBook(id)
  if (!entry) return
  const next = { ...entry, ...update }
  if (JSON.stringify(next) === JSON.stringify(entry)) return
  store({ ...read(), [id]: next })
}

// A position the hub stored (this device's, after a save)
export function rememberEntry(entry: ProgressEntry) {
  const stored = getOfflineBook(entry.bookId)
  if (!stored) return
  refreshOffline(entry.bookId, { progress: [entry, ...stored.progress.filter((d) => d.device !== entry.device)] })
}

// 1234567 -> "1,2 MB"
export function formatBytes(n: number): string {
  const units = ["B", "KB", "MB", "GB"]
  let i = 0
  while (n >= 1000 && i < units.length - 1) {
    n /= 1000
    i++
  }
  return `${n.toLocaleString(locale, { maximumFractionDigits: i === 0 || n >= 100 ? 0 : 1 })} ${units[i]}`
}
