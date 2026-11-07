import { useSyncExternalStore } from "react"
import type { QueryClient } from "@tanstack/react-query"
import { api, ApiError, uploadBook, write, type Book, type UploadOptions, type UploadState } from "./api"

export const MAX_UPLOAD = 200 * 1024 * 1024
const PARALLEL = 2
// between two looks at what the Eingang made of an upload
const CHECK_EVERY = 1_000

export interface UploadItem {
  id: number
  file: File
  opts: UploadOptions
  // checking: sent, the Eingang is at it; waiting: it stays there for a
  // decision; gone: it left the Eingang without reaching the library
  status: "queued" | "uploading" | "checking" | "done" | "waiting" | "duplicate" | "gone" | "error"
  progress: number
  book?: Book
  duplicates?: Book[]
  // what it looks like when the hub could not resolve a book
  duplicateTitles?: string[]
  // added, but the hub's duplicate detection pairs it with these
  similar?: Book[]
  error?: string
  // the upload at the hub, its entry in the Eingang while there is one
  uploadId?: string
  entryId?: number
  confidence?: number | null
  threshold?: number | null
  // byte for byte in the library: nothing is left in the Eingang
  copy?: boolean
}

// Upload queue outside React, so it survives navigation.
let items: UploadItem[] = []
let nextId = 1
const listeners = new Set<() => void>()
let queryClient: QueryClient | null = null

const emit = () => listeners.forEach((l) => l())
const update = (id: number, patch: Partial<UploadItem>) => {
  items = items.map((i) => (i.id === id ? { ...i, ...patch } : i))
  emit()
}

export function connectUploads(qc: QueryClient) {
  queryClient = qc
}

function pump() {
  const running = items.filter((i) => i.status === "uploading").length
  items
    .filter((i) => i.status === "queued")
    .slice(0, Math.max(0, PARALLEL - running))
    .forEach(run)
}

function added(id: number, book: Book, similar?: Book[]) {
  update(id, { status: "done", progress: 1, book, similar, entryId: undefined })
  queryClient?.invalidateQueries({ queryKey: ["books"] })
  queryClient?.invalidateQueries({ queryKey: ["categories"] })
  queryClient?.invalidateQueries({ queryKey: ["book", book.id] })
}

const failed = (id: number, e: unknown) => {
  const msg = e instanceof ApiError && e.status === 413 ? "zu groß" : e instanceof ApiError && e.status === 415 ? "Format nicht unterstützt" : e instanceof Error ? e.message : String(e)
  update(id, { status: "error", error: msg })
}

// what the tray shows of the hub's answer, nothing vanishes without a word
function settle(id: number, s: UploadState) {
  if ((s.status === "imported" || s.status === "formatAdded") && s.book) added(id, s.book, s.possibleDuplicates)
  else if (s.status === "duplicate" || s.status === "copy")
    update(id, { status: "duplicate", duplicates: s.duplicates ?? [], duplicateTitles: s.titles ?? [], entryId: s.entryId, copy: s.status === "copy" })
  else if (s.status === "waiting") update(id, { status: "waiting", entryId: s.entryId, confidence: s.confidence, threshold: s.threshold, error: s.error ?? undefined })
  else update(id, { status: "gone" })
}

// the Eingang's analysis and decisions take their time, the tray stays with it
async function follow(id: number, upload: UploadState) {
  update(id, { status: "checking", progress: 1, uploadId: upload.id })
  let state = upload
  while (state.status === "checking") {
    await new Promise((r) => setTimeout(r, CHECK_EVERY))
    if (!items.some((i) => i.id === id)) return
    state = await api.uploadState(upload.id)
  }
  settle(id, state)
}

async function run(item: UploadItem) {
  update(item.id, { status: "uploading", progress: 0, error: undefined })
  try {
    const res = await uploadBook(item.file, item.opts, (progress) => update(item.id, { progress }))
    if (res.status === "added") added(item.id, res.book)
    else void follow(item.id, res.upload).catch((e) => failed(item.id, e))
  } catch (e) {
    failed(item.id, e)
  } finally {
    pump()
  }
}

export function addUploads(files: File[], opts: UploadOptions) {
  for (const file of files) {
    const tooBig = file.size > MAX_UPLOAD
    items = [...items, { id: nextId++, file, opts, status: tooBig ? "error" : "queued", progress: 0, error: tooBig ? "zu groß (max. 200 MB)" : undefined }]
  }
  emit()
  pump()
}

// Answers „schon in der Bibliothek“: an entry waiting in the Eingang is
// decided there, an exact copy left nothing behind and is sent again
export function retryUpload(id: number, extra: UploadOptions = {}) {
  const item = items.find((i) => i.id === id)
  if (item?.entryId != null && item.uploadId) return decideUpload(item.id, item.entryId, item.uploadId, extra)
  items = items.map((i) => (i.id === id ? { ...i, opts: { ...i.opts, ...extra }, status: "queued", duplicates: undefined } : i))
  emit()
  pump()
}

function decideUpload(id: number, entry: number, upload: string, extra: UploadOptions) {
  const book = extra.addFormatTo
  update(id, { status: "checking", duplicates: undefined })
  write
    .intakeDecide({ decision: book == null ? "accept" : "format", target: { ids: [entry] }, book })
    .then(() => follow(id, { id: upload, name: "", status: "checking" }))
    .catch((e) => failed(id, e))
}

export function dismissUpload(id: number) {
  items = items.filter((i) => i.id !== id)
  emit()
}

export function clearFinished() {
  items = items.filter((i) => i.status === "queued" || i.status === "uploading" || i.status === "checking")
  emit()
}

export function useUploads(): UploadItem[] {
  return useSyncExternalStore(
    (l) => {
      listeners.add(l)
      return () => listeners.delete(l)
    },
    () => items,
  )
}
