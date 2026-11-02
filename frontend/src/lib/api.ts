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
}

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
  fastTags: string[]
  categoryColumn: string | null
}

export const SORTS = ["title", "author", "added", "modified", "published", "series", "rating"] as const
export type Sort = (typeof SORTS)[number]

export interface BookQuery {
  q?: string
  kategorie?: string
  tag?: string[]
  author?: string
  series?: string
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

async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
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
}

export type BulkTarget = { ids: number[] } | { query: Omit<BookQuery, "offset" | "limit"> }

export interface Job {
  status: "running" | "done" | "failed"
  done: number
  total: number
  errors: { bookId: number; error: string }[]
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

export type UploadResult = { status: "added"; book: Book } | { status: "duplicate"; duplicates: Book[] }

const json = (body: unknown): RequestInit => ({ body: JSON.stringify(body) })

export const write = {
  patchBook: (id: number, patch: BookPatch) => request<Book>(`/api/books/${id}`, { method: "PATCH", ...json(patch) }),
  bulk: (target: BulkTarget, changes: BulkChanges) =>
    request<{ jobId: string; total: number }>("/api/books/bulk", { method: "POST", ...json({ target, changes }) }),
  job: (id: string) => request<Job>(`/api/jobs/${id}`),
  coverUpload: (id: number, image: Blob) =>
    request<Book>(`/api/books/${id}/cover`, { method: "PUT", body: image, headers: { "Content-Type": image.type || "image/jpeg" } }),
  coverFromFile: (id: number, format?: string) =>
    request<Book>(`/api/books/${id}/cover/from-file`, { method: "POST", ...json({ format }) }),
  coverFromUrl: (id: number, url: string) => request<Book>(`/api/books/${id}/cover/from-url`, { method: "POST", ...json({ url }) }),
  coverSearch: (id: number) => request<CoverHit[]>(`/api/books/${id}/cover/search`),
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
      if (xhr.status === 201 || xhr.status === 200) resolve({ status: "added", book: body.book })
      else if (xhr.status === 409 && body?.duplicates) resolve({ status: "duplicate", duplicates: body.duplicates })
      else reject(new ApiError(xhr.status, body?.error ?? xhr.statusText))
    }
    signal?.addEventListener("abort", () => xhr.abort())
    xhr.send(form)
  })
}

export const DEFAULT_CONFIG: HubConfig = { fastTags: ["leseliste"], categoryColumn: "kategorie" }

export const coverUrl = (id: number, thumb = true, version?: string) =>
  `/api/books/${id}/cover${thumb ? "?size=thumb" : ""}${version ? `${thumb ? "&" : "?"}v=${encodeURIComponent(version)}` : ""}`

export const downloadUrl = (id: number, format: string) => `/api/books/${id}/download/${format.toLowerCase()}`

export function categoryOf(book: Book, column: string | null): string | null {
  if (!column) return null
  const v = book.custom[column]
  return typeof v === "string" && v ? v : null
}
