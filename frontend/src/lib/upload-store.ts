import { useSyncExternalStore } from "react"
import type { QueryClient } from "@tanstack/react-query"
import { ApiError, uploadBook, type Book, type UploadOptions } from "./api"

export const MAX_UPLOAD = 200 * 1024 * 1024
const PARALLEL = 2

export interface UploadItem {
  id: number
  file: File
  opts: UploadOptions
  status: "queued" | "uploading" | "done" | "duplicate" | "error"
  progress: number
  book?: Book
  duplicates?: Book[]
  error?: string
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

async function run(item: UploadItem) {
  update(item.id, { status: "uploading", progress: 0, error: undefined })
  try {
    const res = await uploadBook(item.file, item.opts, (progress) => update(item.id, { progress }))
    if (res.status === "added") {
      update(item.id, { status: "done", progress: 1, book: res.book })
      queryClient?.invalidateQueries({ queryKey: ["books"] })
      queryClient?.invalidateQueries({ queryKey: ["categories"] })
      if (item.opts.addFormatTo != null) queryClient?.invalidateQueries({ queryKey: ["book", item.opts.addFormatTo] })
    } else update(item.id, { status: "duplicate", duplicates: res.duplicates })
  } catch (e) {
    const msg = e instanceof ApiError && e.status === 413 ? "zu groß" : e instanceof ApiError && e.status === 415 ? "Format nicht unterstützt" : e instanceof Error ? e.message : String(e)
    update(item.id, { status: "error", error: msg })
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

export function retryUpload(id: number, extra: UploadOptions = {}) {
  items = items.map((i) => (i.id === id ? { ...i, opts: { ...i.opts, ...extra }, status: "queued", duplicates: undefined } : i))
  emit()
  pump()
}

export function dismissUpload(id: number) {
  items = items.filter((i) => i.id !== id)
  emit()
}

export function clearFinished() {
  items = items.filter((i) => i.status === "queued" || i.status === "uploading")
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
