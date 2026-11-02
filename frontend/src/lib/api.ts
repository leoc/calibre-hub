// Types and fetch helpers for the calibre-hub API (see README.md).

export interface Book {
  id: number
  title: string
  authors: string[]
  authorSort: string | null
  tags: string[]
  series: string | null
  seriesIndex: number | null
  formats: string[]
  lastModified: string
  added: string | null
  pubdate: string | null
  rating: number | null
  publisher: string | null
  identifiers: Record<string, string>
  languages: string[]
  comments?: string | null
  custom: Record<string, unknown>
  // ids of the reading lists the book is in (older hubs: missing)
  lists?: number[]
}

export const VISIBILITIES = ["private", "readable", "editable"] as const
export type Visibility = (typeof VISIBILITIES)[number]

// A reading list, like a playlist (GET /api/lists)
export interface ReadingList {
  id: number
  name: string
  description: string
  owner: string
  visibility: Visibility
  // mirrored to the reader (leseliste handler)
  sync: boolean
  // shown in the sidebar first
  favorite: boolean
  // the bookmark on the cover saves to it
  isDefault: boolean
  count: number
  // nested lists: the name is a path ("Urlaub/2026"); the path above it
  // (null at the top) and the last level
  parent: string | null
  leaf: string
  // distinct books incl. the sublists the user sees (older hubs: missing)
  totalCount?: number
  // the most recently added books, for the cover mosaic
  coverBookIds: number[]
  createdAt: string
  updatedAt: string
  // last time books were added
  lastUsedAt: string | null
  // the user may change it
  editable: boolean
}

// A device's last reading position in a book (GET /api/books/:id/progress).
// position depends on the format: CFI (EPUB, MOBI/AZW3, CBZ), page (PDF)
export interface ProgressEntry {
  bookId: number
  device: string
  deviceName: string
  format: string
  position: string
  fraction: number
  source: "web" | "koreader"
  updatedAt: string
}

export interface BookProgress {
  // newest over all devices, null when never opened
  latest: ProgressEntry | null
  devices: ProgressEntry[]
}

export interface ProgressSave {
  format: string
  position: string
  fraction: number
  device: string
  deviceName?: string
}

export type ListPatch = Partial<Pick<ReadingList, "name" | "description" | "visibility" | "sync" | "favorite" | "isDefault">>

export interface BookPage {
  total: number
  offset: number
  limit: number
  books: Book[]
}

export interface CategoryNode {
  name: string
  path: string
  count: number
  children: CategoryNode[]
}

export interface Named {
  name: string
  count: number
}

export interface Categories {
  kategorie: CategoryNode[]
  tags: Named[]
  authors: Named[]
  series: Named[]
  languages: Named[]
}

export interface HubConfig {
  // replaced by favorite lists; still sent for older web apps
  fastTags?: string[]
  categoryColumn: string | null
  // category suggestions from a local model (services.calibre-hub.classify)
  classify?: boolean
  // metadata completion and cleanup (title, authors, ISBN, cover …)
  metadata?: boolean
}

export const METADATA_FIELDS = ["title", "authors", "authorSort", "isbn", "publisher", "pubdate", "languages", "comments", "series", "seriesIndex", "cover"] as const
export type MetadataField = (typeof METADATA_FIELDS)[number]
export type MetadataSource = "rules" | "model" | "file" | "hardcover" | "openlibrary" | "dnb" | "authors"

// One logged field change of the metadata cleanup; revertable while the
// field still has the new value
export interface MetadataChange {
  id: number
  bookId: number
  field: MetadataField
  old: unknown
  new: unknown
  source: MetadataSource
  jobId: string | null
  at: string
  revertedAt: string | null
}

export type MetadataTarget = "incomplete" | "all" | "authors" | { ids: number[] } | { query: Omit<BookQuery, "offset" | "limit"> }

export interface MetadataStatus {
  enabled: boolean
  sources?: string[]
  // model that cleans names, null without one
  model?: string | null
  // "HH:MM"
  nightly?: string | null
  running?: boolean
  // books with at least one change not reverted
  changedBooks?: number
  lastRun?: (Job & { id: string; startedAt: string; target: string }) | null
}

// What one source knows about a book; only the fields it has
export interface MetadataCandidate {
  source: "rules" | "file" | "hardcover" | "openlibrary" | "dnb"
  score: number
  // ISBN matched exactly
  sure: boolean
  url: string | null
  fields: {
    title?: string
    authors?: string[]
    isbn?: string
    publisher?: string
    pubdate?: string
    languages?: string[]
    comments?: string
    series?: string
    seriesIndex?: number
    coverUrl?: string
  }
}

export interface MetadataChangesQuery {
  bookId?: number
  since?: string
  reverted?: boolean
  limit?: number
}

export type SuggestionStatus = "pending" | "auto" | "applied" | "rejected" | "none"

// The latest category suggestion for a book; category is stored dotted, null
// when no category of the tree fits
export interface Suggestion {
  bookId: number
  category: string | null
  confidence: number
  reason: string
  model: string
  at: string
  status: SuggestionStatus
}

export interface ClassifyStatus {
  enabled: boolean
  model?: string
  threshold?: number
  // nodes in the category tree; below minCategories nothing is suggested
  categories?: number
  minCategories?: number
  pending?: number
  running?: boolean
  lastRun?: (Job & { id: string; startedAt: string }) | null
}

export type ClassifyTarget = "unsorted" | { ids: number[] }

export const SORTS = ["title", "author", "added", "modified", "published", "series", "rating"] as const
// inside a list: the time a book was added to it first, no manual order
export const LIST_SORTS = ["listAdded", "title", "author", "series"] as const
export const ALL_SORTS = [...SORTS, "listAdded"] as const
export type Sort = (typeof ALL_SORTS)[number]

export interface BookQuery {
  q?: string
  kategorie?: string
  tag?: string[]
  author?: string
  series?: string
  // books of a reading list (and its sublists unless direct)
  list?: number
  // a level of the list tree that may have no list of its own
  listPath?: string
  listOwner?: string
  direct?: boolean

  sort?: Sort
  order?: "asc" | "desc"
  offset?: number
  limit?: number
}

export class ApiError extends Error {
  constructor(
    public status: number,
    message: string,
    public body: Record<string, unknown> | null = null,
  ) {
    super(message)
  }
}

export async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  const method = (init.method ?? "GET").toUpperCase()
  const headers = new Headers(init.headers)
  if (method !== "GET" && method !== "HEAD") headers.set("X-Calibre-Hub", "1")
  if (init.body && !headers.has("Content-Type")) headers.set("Content-Type", "application/json")
  const res = await fetch(path, { ...init, headers, credentials: "same-origin" })
  if (!res.ok) {
    const body = await res.json().catch(() => null)
    throw new ApiError(res.status, body?.error ?? res.statusText, body)
  }
  return res.status === 204 ? (undefined as T) : ((await res.json()) as T)
}

export function bookSearchParams(query: BookQuery): URLSearchParams {
  const p = new URLSearchParams()
  for (const [k, v] of Object.entries(query)) {
    if (v === undefined || v === "") continue
    if (Array.isArray(v)) v.forEach((x) => p.append(k, x))
    else p.set(k, String(v))
  }
  return p
}

export const api = {
  session: () => request<{ user: string }>("/api/session"),
  login: (user: string, password: string) =>
    request<{ user: string }>("/api/session", { method: "POST", body: JSON.stringify({ user, password }) }),
  logout: () => request<void>("/api/session", { method: "DELETE" }),
  books: (query: BookQuery) => request<BookPage>(`/api/books?${bookSearchParams(query)}`),
  book: (id: number) => request<Book>(`/api/books/${id}`),
  categories: () => request<Categories>("/api/categories"),
  trash: () => request<TrashEntry[]>("/api/trash"),
  suggestions: (status?: SuggestionStatus) =>
    request<(Suggestion & { book: Book })[]>(`/api/suggestions${status ? `?status=${status}` : ""}`),
  // null when the book has none
  suggestion: (bookId: number) =>
    request<Suggestion>(`/api/suggestions/${bookId}`).catch((e) => {
      if (e instanceof ApiError && e.status === 404) return null
      throw e
    }),
  classifyStatus: () => request<ClassifyStatus>("/api/classify/status"),
  metadataStatus: () => request<MetadataStatus>("/api/metadata/status"),
  metadataChanges: (query: MetadataChangesQuery = {}) =>
    request<{ changes: MetadataChange[]; books: Book[] }>(`/api/metadata/changes?${new URLSearchParams(Object.entries(query).flatMap(([k, v]) => (v === undefined ? [] : [[k, String(v)]])))}`),
  // q: own search text instead of the book's title and author
  metadataCandidates: (bookId: number, q?: string) =>
    request<{ candidates: MetadataCandidate[] }>(`/api/books/${bookId}/metadata/candidates${q ? `?${new URLSearchParams({ q })}` : ""}`),
  progress: (bookId: number) => request<BookProgress>(`/api/books/${bookId}/progress`),
  // the newest position per book (bars on the covers); older hubs: none
  allProgress: () =>
    request<Pick<ProgressEntry, "bookId" | "fraction" | "format" | "updatedAt">[]>("/api/progress").catch((e) => {
      if (e instanceof ApiError && e.status === 404) return []
      throw e
    }),
  lists: () => request<ReadingList[]>("/api/lists"),
  list: (id: number) => request<ReadingList>(`/api/lists/${id}`),
  // not every hub has /api/config yet (#8391); fall back to the defaults
  config: () =>
    request<HubConfig>("/api/config").catch((e) => {
      if (e instanceof ApiError && e.status === 404) return DEFAULT_CONFIG
      throw e
    }),
}

export interface BookPatch {
  title?: string
  authors?: string[]
  series?: string | null
  seriesIndex?: number | null
  tags?: string[]
  addTags?: string[]
  removeTags?: string[]
  kategorie?: string | null
  comments?: string | null
  publisher?: string | null
  pubdate?: string | null // YYYY-MM-DD
  languages?: string[]
  rating?: number | null
  identifiers?: Record<string, string>
  // optimistic concurrency: 409 when the book changed since
  lastModified?: string
}

export interface BulkChanges {
  addTags?: string[]
  removeTags?: string[]
  kategorie?: string | null
  series?: string | null
  // with series and an ids target: volumes 1..n in the order of the ids
  numberSeries?: boolean
  // moves the books to the trash; only on its own
  delete?: true
}

// A book in calibre's trash. id is the id it had; a restored book gets a new one.
export interface TrashEntry {
  id: number
  title: string
  authors: string[]
  formats: string[]
  deletedAt: string
}

export type BulkTarget = { ids: number[] } | { query: Omit<BookQuery, "offset" | "limit"> }

export interface Job {
  status: "running" | "done" | "failed"
  done: number
  total: number
  errors: { bookId: number; error: string }[]
  // why a job stopped early (e.g. the model is unavailable)
  error?: string
}

export interface CoverHit {
  url: string
  source: string
  width: number | null
  height: number | null
}

export interface UploadOptions {
  tags?: string[]
  kategorie?: string
  force?: boolean
  addFormatTo?: number
}

// possibleDuplicates: books the hub's own detection pairs with the new one
export type UploadResult = { status: "added"; book: Book; possibleDuplicates?: Book[] } | { status: "duplicate"; duplicates: Book[]; titles: string[] }

const json = (body: unknown): RequestInit => ({ body: JSON.stringify(body) })

// books to add to or remove from a list
export type ListBooks = { bookIds: number[] } | { target: BulkTarget }
// the list afterwards and the books that were new in it, or left it
export interface ListChange {
  list: ReadingList
  added?: number[]
  removed?: number[]
}

export const write = {
  // keepalive: also when the page is closing
  saveProgress: (bookId: number, p: ProgressSave, keepalive = false) =>
    request<ProgressEntry>(`/api/books/${bookId}/progress`, { method: "PUT", keepalive, ...json(p) }),
  createList: (list: ListPatch & { name: string }) => request<ReadingList>("/api/lists", { method: "POST", ...json(list) }),
  updateList: (id: number, patch: ListPatch) => request<ReadingList>(`/api/lists/${id}`, { method: "PATCH", ...json(patch) }),
  deleteList: (id: number) => request<{ list: ReadingList }>(`/api/lists/${id}`, { method: "DELETE" }),
  addToList: (id: number, books: ListBooks) => request<ListChange>(`/api/lists/${id}/books`, { method: "POST", ...json(books) }),
  removeFromList: (id: number, books: ListBooks) => request<ListChange>(`/api/lists/${id}/books/remove`, { method: "POST", ...json(books) }),
  patchBook: (id: number, patch: BookPatch) => request<Book>(`/api/books/${id}`, { method: "PATCH", ...json(patch) }),
  // into calibre's trash; returns the book as it was
  deleteBook: (id: number) => request<{ book: Book }>(`/api/books/${id}`, { method: "DELETE" }),
  restore: (trashId: number) => request<{ book: Book }>(`/api/trash/${trashId}/restore`, { method: "POST" }),
  bulk: (target: BulkTarget, changes: BulkChanges) =>
    request<{ jobId: string; total: number }>("/api/books/bulk", { method: "POST", ...json({ target, changes }) }),
  job: (id: string) => request<Job>(`/api/jobs/${id}`),
  // category: another one than suggested, path or dotted
  acceptSuggestion: (bookId: number, category?: string) =>
    request<Suggestion>(`/api/suggestions/${bookId}/accept`, { method: "POST", ...json(category ? { category } : {}) }),
  rejectSuggestion: (bookId: number) => request<Suggestion>(`/api/suggestions/${bookId}/reject`, { method: "POST" }),
  acceptSuggestions: (bookIds: number[]) =>
    request<{ accepted: Suggestion[]; errors: { bookId: number; error: string }[] }>("/api/suggestions/accept", { method: "POST", ...json({ bookIds }) }),
  // 409 with {categories, minCategories} while the tree is too small
  classify: (target: ClassifyTarget) => request<{ jobId: string; total: number }>("/api/classify", { method: "POST", ...json({ target }) }),
  // converts every book without the target format (default: the configured one)
  convert: (target?: string) => request<{ jobId: string; total: number }>("/api/convert", { method: "POST", ...json(target ? { target } : {}) }),
  metadataRun: (target: MetadataTarget = "incomplete") =>
    request<{ jobId: string; total: number }>("/api/metadata/run", { method: "POST", ...json({ target }) }),
  // 409 {error, book} when the field was changed in the meantime
  revertMetadataChange: (id: number) => request<{ change: MetadataChange; book: Book }>(`/api/metadata/changes/${id}/revert`, { method: "POST" }),
  // by book: all active changes of those books
  revertMetadataChanges: (target: { bookIds?: number[]; changeIds?: number[] }) =>
    request<{ reverted: MetadataChange[]; errors: { changeId: number; bookId: number; error: string }[] }>("/api/metadata/changes/revert", {
      method: "POST",
      ...json(target),
    }),
  coverUpload: (id: number, image: Blob) =>
    request<Book>(`/api/books/${id}/cover`, { method: "PUT", body: image, headers: { "Content-Type": image.type || "image/jpeg" } }),
  coverFromFile: (id: number, format?: string) =>
    request<Book>(`/api/books/${id}/cover/from-file`, { method: "POST", ...json({ format }) }),
  coverFromUrl: (id: number, url: string) => request<Book>(`/api/books/${id}/cover/from-url`, { method: "POST", ...json({ url }) }),
  // q overrides the default (title, first author, ISBN)
  coverSearch: (id: number, q?: string) =>
    request<CoverHit[]>(`/api/books/${id}/cover/search${q ? `?${new URLSearchParams({ q })}` : ""}`),
}

// XHR instead of fetch for upload progress.
export function uploadBook(file: File, opts: UploadOptions, onProgress: (fraction: number) => void, signal?: AbortSignal): Promise<UploadResult> {
  return new Promise((resolve, reject) => {
    const form = new FormData()
    form.append("file", file)
    opts.tags?.forEach((t) => form.append("tags", t))
    if (opts.kategorie) form.append("kategorie", opts.kategorie)
    if (opts.force) form.append("force", "1")
    if (opts.addFormatTo != null) form.append("addFormatTo", String(opts.addFormatTo))
    const xhr = new XMLHttpRequest()
    xhr.open("POST", "/api/books")
    xhr.setRequestHeader("X-Calibre-Hub", "1")
    xhr.upload.onprogress = (e) => e.lengthComputable && onProgress(e.loaded / e.total)
    xhr.onerror = () => reject(new ApiError(0, "network error"))
    xhr.onabort = () => reject(new DOMException("aborted", "AbortError"))
    xhr.onload = () => {
      const body = (() => {
        try {
          return JSON.parse(xhr.responseText)
        } catch {
          return null
        }
      })()
      if (xhr.status === 201 || xhr.status === 200) resolve({ status: "added", book: body.book, possibleDuplicates: body.possibleDuplicates })
      else if (xhr.status === 409 && body?.error === "duplicate") resolve({ status: "duplicate", duplicates: body.duplicates ?? [], titles: body.titles ?? [] })
      else reject(new ApiError(xhr.status, body?.error ?? xhr.statusText))
    }
    signal?.addEventListener("abort", () => xhr.abort())
    xhr.send(form)
  })
}

export const DEFAULT_CONFIG: HubConfig = { categoryColumn: "kategorie", classify: false, metadata: false }

export const coverUrl = (id: number, thumb = true, version?: string) =>
  `/api/books/${id}/cover${thumb ? "?size=thumb" : ""}${version ? `${thumb ? "&" : "?"}v=${encodeURIComponent(version)}` : ""}`

export const downloadUrl = (id: number, format: string) => `/api/books/${id}/download/${format.toLowerCase()}`

export function categoryOf(book: Book, column: string | null): string | null {
  if (!column) return null
  const v = book.custom[column]
  return typeof v === "string" && v ? v : null
}
