import { http, HttpResponse } from "msw"
import type { Book, BookPatch, BulkChanges, BulkTarget, ClassifyTarget, Job, Suggestion, SuggestionStatus, TrashEntry } from "@/lib/api"
import { bookSearchParams } from "@/lib/api"
import { categories, makeBooks } from "./data"
import { metadataHandlers } from "./metadata"
import { progressHandlers } from "./progress"
import { duplicateHandlers } from "./duplicates"
import { readerSettingsHandlers } from "./reader-settings"
import { dropFromLists, listHandlers, listQueryIds, seedLists, withLists } from "./lists"


const size = Number(import.meta.env.VITE_MOCK_BOOKS ?? 400)
export const books = makeBooks(size)
seedLists(books)
let loggedIn = true

const SORT_KEY: Record<string, (b: Book) => string | number> = {
  title: (b) => b.title.toLowerCase(),
  author: (b) => b.authorSort ?? "",
  added: (b) => b.added ?? "",
  modified: (b) => b.lastModified,
  published: (b) => b.pubdate ?? "",
  series: (b) => `${b.series ?? "￿"}\u0000${String(b.seriesIndex ?? 0).padStart(6, "0")}`,
  rating: (b) => b.rating ?? 0,
}

// Small subset of calibre's search: free words, languages:"=x" and
// #column:false (column empty).
function matches(b: Book, q: string) {
  const lang = /languages:"=([^"]+)"/.exec(q)?.[1]
  if (lang && !b.languages.includes(lang)) return false
  const empty = /#(\w+):false/.exec(q)?.[1]
  if (empty && b.custom[empty]) return false
  const text = q
    .replace(/languages:"=[^"]+"/, "")
    .replace(/#\w+:false/, "")
    .replace(/[()]|\band\b/g, " ")
    .toLowerCase()
  const hay = [b.title, ...b.authors, b.series ?? "", ...b.tags].join(" ").toLowerCase()
  return text.split(/\s+/).filter(Boolean).every((w) => hay.includes(w))
}

const cover = (b: Book) => {
  const hue = (b.id * 47) % 360
  const title = b.title.replace(/[<&]/g, "")
  return `<svg xmlns="http://www.w3.org/2000/svg" width="300" height="400"><rect width="300" height="400" fill="hsl(${hue} 45% 40%)"/><text x="20" y="60" font-family="serif" font-size="26" fill="#fff">${title.slice(0, 18)}</text><text x="20" y="92" font-family="serif" font-size="26" fill="#fff">${title.slice(18, 36)}</text><text x="20" y="370" font-family="sans-serif" font-size="16" fill="#fff">${b.authors[0]}</text></svg>`
}

function filterBooks(p: URLSearchParams) {
  const k = p.get("kategorie")
  const members = listQueryIds(p)
  const inList = members !== undefined ? new Set(members ?? []) : null
  return books.filter((b) => {
    if (inList && !inList.has(b.id)) return false
    const cat = b.custom.kategorie as string | null
    if (k && !(cat === k || cat?.startsWith(`${k}.`))) return false
    if (p.getAll("tag").some((t) => !b.tags.includes(t))) return false
    if (p.get("author") && !b.authors.includes(p.get("author")!)) return false
    if (p.get("series") && b.series !== p.get("series")) return false
    return !p.get("q") || matches(b, p.get("q")!)
  })
}

function touch(b: Book) {
  b.lastModified = new Date(Math.max(Date.now(), Date.parse(b.lastModified) + 1000)).toISOString()
}

function applyPatch(b: Book, patch: BookPatch) {
  const { addTags, removeTags, kategorie, lastModified: _lm, ...fields } = patch
  Object.assign(b, fields)
  if (addTags) b.tags = [...new Set([...b.tags, ...addTags])]
  if (removeTags) b.tags = b.tags.filter((t) => !removeTags.includes(t))
  if (kategorie !== undefined) b.custom = { ...b.custom, kategorie }
  if (patch.series === null) b.seriesIndex = null
  else if (patch.series && b.seriesIndex == null) b.seriesIndex = 1
  touch(b)
}

// calibre's trash: deleted books with the id they had; restoring adds them
// again under a new id, like the hub does
const trash: { entry: TrashEntry; book: Book }[] = []

function moveToTrash(b: Book) {
  books.splice(books.indexOf(b), 1)
  dropFromLists(b.id)
  trash.unshift({ entry: { id: b.id, title: b.title, authors: b.authors, formats: b.formats, deletedAt: new Date().toISOString() }, book: b })
}

// adds a deleted book again under a new id; null when it isn't in the trash
function restoreFromTrash(id: number): Book | null {
  const i = trash.findIndex((t) => t.entry.id === id)
  if (i < 0) return null
  const [{ book }] = trash.splice(i, 1)
  const restored = { ...book, id: Math.max(...books.map((x) => x.id), ...trash.map((t) => t.entry.id), book.id) + 1 }
  touch(restored)
  books.push(restored)
  return restored
}

// Category suggestions of the "model": a few open ones for unsorted books
// from the start; a run suggests by id (id % 3: 0 sure and applied, 1 open,
// 2 nothing fits). Only categories of the tree, like the hub.
const THRESHOLD = 0.85
const suggestions = new Map<number, Suggestion>()
const treePaths = () => {
  const paths = new Set<string>()
  books.forEach((b) => {
    const k = b.custom.kategorie
    if (typeof k !== "string" || !k) return
    k.split(".").forEach((_, i, parts) => paths.add(parts.slice(0, i + 1).join(".")))
  })
  return [...paths].sort()
}
const unsorted = () => books.filter((b) => !b.custom.kategorie)

function suggest(b: Book, kind: number): Suggestion {
  const paths = treePaths().filter((p) => p.includes("."))
  const category = kind === 2 ? null : paths[b.id % paths.length]
  const confidence = kind === 0 ? 0.92 : kind === 1 ? 0.55 + (b.id % 4) * 0.05 : 0
  const reason = category ? `Titel und Beschreibung passen zu ${category.split(".").join("/")}.` : "Keine Kategorie passt."
  const s: Suggestion = { bookId: b.id, category, confidence, reason, model: "qwen2.5:3b", at: new Date().toISOString(), status: "pending" }
  if (!category) s.status = "none"
  else if (confidence >= THRESHOLD && !b.custom.kategorie) {
    applyPatch(b, { kategorie: category, addTags: ["auto-kategorie"] })
    s.status = "auto"
  }
  suggestions.set(b.id, s)
  return s
}
unsorted()
  .slice(0, 5)
  .forEach((b) => suggest(b, 1))

let lastClassify: (Job & { id: string; startedAt: string }) | null = null

const jobs = new Map<string, Job>()
const retried = new Set<number>()
const delay = (ms: number) => new Promise((r) => setTimeout(r, ms))
// covers set through the cover endpoints (object URLs are not reachable from the worker, so keep bytes)
const customCovers = new Map<number, { body: ArrayBuffer; type: string }>()

const auth = () => (loggedIn ? null : HttpResponse.json({ error: "login required" }, { status: 401 }))

export const readHandlers = [
  http.get("/api/session", () => auth() ?? HttpResponse.json({ user: "arthur" })),
  http.post("/api/session", async ({ request }) => {
    const { password } = (await request.json()) as { password: string }
    if (password !== "hub") return HttpResponse.json({ error: "wrong user or password" }, { status: 401 })
    loggedIn = true
    return HttpResponse.json({ user: "arthur" })
  }),
  http.delete("/api/session", () => {
    loggedIn = false
    return new HttpResponse(null, { status: 204 })
  }),
  http.get("/api/config", () => auth() ?? HttpResponse.json({ fastTags: ["leseliste"], categoryColumn: "kategorie", classify: true, metadata: true })),
  http.get("/api/categories", () => auth() ?? HttpResponse.json(categories(books))),
  http.get("/api/books", ({ request }) => {
    const denied = auth()
    if (denied) return denied
    const p = new URL(request.url).searchParams
    const members = listQueryIds(p)
    if (members === null) return HttpResponse.json({ error: "not found" }, { status: 404 })
    const listId = members !== undefined
    let list = filterBooks(p)
    const dir = p.get("order") === "desc" ? -1 : 1
    if (listId && (p.get("sort") ?? "listAdded") === "listAdded") {
      // newest first, like the hub
      const order = members!
      list = [...list].sort((a, b) => (order.indexOf(a.id) - order.indexOf(b.id)) * (p.get("order") === "asc" ? -1 : 1))
    } else {
      const key = SORT_KEY[p.get("sort") ?? "title"]
      if (!key || (listId && !["title", "author", "series"].includes(p.get("sort")!))) return HttpResponse.json({ error: "unknown sort" }, { status: 400 })
      list = [...list].sort((a, b) => (key(a) < key(b) ? -dir : key(a) > key(b) ? dir : 0))
    }
    const offset = Number(p.get("offset") ?? 0)
    const limit = Math.min(Number(p.get("limit") ?? 50), 500)
    return HttpResponse.json({ total: list.length, offset, limit, books: list.slice(offset, offset + limit).map(({ comments: _c, ...b }) => withLists(b)) })
  }),
  http.get("/api/books/:id", ({ params }) => {
    const b = books.find((x) => x.id === Number(params.id))
    return auth() ?? (b ? HttpResponse.json(withLists(b)) : HttpResponse.json({ error: "not found" }, { status: 404 }))
  }),
  http.get("/api/books/:id/cover", ({ params }) => {
    const custom = customCovers.get(Number(params.id))
    if (custom) return new HttpResponse(custom.body, { headers: { "Content-Type": custom.type } })
    const b = books.find((x) => x.id === Number(params.id))
    if (!b || b.id % 13 === 0) return new HttpResponse(null, { status: 404 })
    return new HttpResponse(cover(b), { headers: { "Content-Type": "image/svg+xml" } })
  }),
  // book files: progress.ts
]

export const writeHandlers = [
  http.patch("/api/books/:id", async ({ params, request }) => {
    const b = books.find((x) => x.id === Number(params.id))
    if (!b) return HttpResponse.json({ error: "not found" }, { status: 404 })
    const patch = (await request.json()) as BookPatch
    await delay(300)
    if (patch.title !== undefined && !patch.title.trim()) return HttpResponse.json({ error: "title must not be empty", field: "title" }, { status: 400 })
    if (patch.lastModified && patch.lastModified !== b.lastModified) return HttpResponse.json({ error: "changed elsewhere", book: b }, { status: 409 })
    applyPatch(b, patch)
    return HttpResponse.json(b)
  }),
  http.delete("/api/books/:id", async ({ params }) => {
    const b = books.find((x) => x.id === Number(params.id))
    if (!b) return HttpResponse.json({ error: "not found" }, { status: 404 })
    await delay(200)
    moveToTrash(b)
    return HttpResponse.json({ book: b })
  }),
  http.get("/api/trash", () => HttpResponse.json(trash.map((t) => t.entry))),
  http.post("/api/trash/:id/restore", async ({ params }) => {
    if (!trash.some((t) => t.entry.id === Number(params.id))) return HttpResponse.json({ error: "not found" }, { status: 404 })
    await delay(300)
    return HttpResponse.json({ book: restoreFromTrash(Number(params.id)) })
  }),
  http.post("/api/books", async ({ request }) => {
    const form = await request.formData()
    const file = form.get("file") as File
    const ext = file.name.split(".").pop()?.toUpperCase() ?? ""
    await delay(500)
    if (!["EPUB", "PDF", "AZW3", "MOBI", "CBZ"].includes(ext)) return HttpResponse.json({ error: "unsupported format" }, { status: 415 })
    const title = file.name.replace(/\.[^.]+$/, "").replace(/[_-]+/g, " ")
    const target = form.get("addFormatTo")
    if (target) {
      const b = books.find((x) => x.id === Number(target))!
      b.formats = [...new Set([...b.formats, ext])]
      touch(b)
      return HttpResponse.json({ book: b }, { status: 200 })
    }
    const dups = books.filter((b) => b.title.toLowerCase() === title.toLowerCase())
    if (dups.length && form.get("force") !== "1") return HttpResponse.json({ error: "duplicate", duplicates: dups, titles: dups.map((d) => `${d.title} (${d.authors.join(" & ")})`) }, { status: 409 })
    const now = new Date().toISOString()
    const b: Book = {
      id: Math.max(...books.map((x) => x.id)) + 1, title, authors: ["Unbekannt"], authorSort: "Unbekannt", tags: form.getAll("tags") as string[],
      series: null, seriesIndex: null, formats: [ext], lastModified: now, added: now, pubdate: null, rating: null, publisher: null,
      identifiers: {}, languages: [], comments: null, custom: { kategorie: (form.get("kategorie") as string) || null },
    }
    books.push(b)
    return HttpResponse.json({ book: b }, { status: 201 })
  }),
  http.put("/api/books/:id/cover", async ({ params, request }) => {
    const b = books.find((x) => x.id === Number(params.id))!
    customCovers.set(b.id, { body: await request.arrayBuffer(), type: request.headers.get("Content-Type") ?? "image/jpeg" })
    touch(b)
    return HttpResponse.json(b)
  }),
  http.post("/api/books/:id/cover/from-file", async ({ params }) => {
    const b = books.find((x) => x.id === Number(params.id))!
    customCovers.delete(b.id)
    await delay(400)
    touch(b)
    return HttpResponse.json(b)
  }),
  http.post("/api/books/:id/cover/from-url", async ({ params, request }) => {
    const b = books.find((x) => x.id === Number(params.id))!
    const { url } = (await request.json()) as { url: string }
    if (!/^https?:\/\//.test(url)) return HttpResponse.json({ error: "only http(s) urls" }, { status: 400 })
    const hue = (url.length * 37) % 360
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="300" height="400"><rect width="300" height="400" fill="hsl(${hue} 60% 35%)"/><text x="20" y="200" font-size="22" fill="#fff">von URL</text></svg>`
    customCovers.set(b.id, { body: new TextEncoder().encode(svg).buffer as ArrayBuffer, type: "image/svg+xml" })
    touch(b)
    return HttpResponse.json(b)
  }),
  http.get("/api/books/:id/cover/search", async () => {
    await delay(600)
    return HttpResponse.json(
      ["Open Library", "DNB", "Open Library"].map((source, i) => ({
        url: `https://covers.example/${source.replace(" ", "").toLowerCase()}/${i}.jpg`, source, width: 600 + i * 100, height: 900 + i * 120,
      })),
    )
  }),
  http.post("/api/books/bulk", async ({ request }) => {
    const { target, changes } = (await request.json()) as { target: BulkTarget; changes: BulkChanges }
    if ("query" in target) {
      const bad = Object.keys(target.query).find((k) => ["offset", "limit", "sort", "order"].includes(k))
      if (bad) return HttpResponse.json({ error: "not allowed in bulk query", field: bad }, { status: 400 })
    }
    if (changes.numberSeries && !("ids" in target && changes.series)) return HttpResponse.json({ error: "numberSeries needs series and ids", field: "numberSeries" }, { status: 400 })
    // ids in the given order: numberSeries counts along it
    const list = "ids" in target ? target.ids.flatMap((id) => books.filter((b) => b.id === id)) : filterBooks(bookSearchParams(target.query))
    const { numberSeries, ...patch } = changes
    const jobId = Math.random().toString(36).slice(2)
    const job: Job = { status: "running", done: 0, total: list.length, errors: [] }
    jobs.set(jobId, job)
    ;(async () => {
      for (const [i, b] of list.entries()) {
        await delay(15)
        // in query jobs, books with id divisible by 97 fail once (error path)
        if ("query" in target && b.id % 97 === 0 && !retried.has(b.id)) {
          retried.add(b.id)
          job.errors.push({ bookId: b.id, error: "calibre-server: Connection refused" })
        } else if (changes.delete) moveToTrash(b)
        else {
          applyPatch(b, patch)
          if (numberSeries) b.seriesIndex = i + 1
        }
        job.done++
      }
      job.status = job.errors.length === list.length ? "failed" : "done"
    })()
    return HttpResponse.json({ jobId, total: list.length }, { status: 202 })
  }),
  http.get("/api/classify/status", () => {
    const pending = [...suggestions.values()].filter((s) => s.status === "pending").length
    return HttpResponse.json({
      enabled: true, model: "qwen2.5:3b", threshold: THRESHOLD, categories: treePaths().length, minCategories: 2,
      pending, running: lastClassify?.status === "running", lastRun: lastClassify,
    })
  }),
  http.get("/api/suggestions", ({ request }) => {
    const status = new URL(request.url).searchParams.get("status") as SuggestionStatus | null
    const list = [...suggestions.values()].filter((s) => !status || s.status === status).sort((a, b) => b.at.localeCompare(a.at) || a.bookId - b.bookId)
    return HttpResponse.json(list.flatMap((s) => {
      const b = books.find((x) => x.id === s.bookId)
      return b ? [{ ...s, book: b }] : []
    }))
  }),
  http.get("/api/suggestions/:id", ({ params }) => {
    const s = suggestions.get(Number(params.id))
    return s ? HttpResponse.json(s) : HttpResponse.json({ error: "not found" }, { status: 404 })
  }),
  http.post("/api/suggestions/accept", async ({ request }) => {
    const { bookIds } = (await request.json()) as { bookIds: number[] }
    await delay(200)
    const accepted: Suggestion[] = []
    const errors: { bookId: number; error: string }[] = []
    for (const id of bookIds) {
      const s = suggestions.get(id)
      const b = books.find((x) => x.id === id)
      if (!s || !b) errors.push({ bookId: id, error: "not found" })
      else if (!s.category) errors.push({ bookId: id, error: "no suggested category, name one" })
      else {
        applyPatch(b, { kategorie: s.category })
        s.status = "applied"
        accepted.push(s)
      }
    }
    return HttpResponse.json({ accepted, errors })
  }),
  http.post("/api/suggestions/:id/accept", async ({ params, request }) => {
    const s = suggestions.get(Number(params.id))
    const b = books.find((x) => x.id === Number(params.id))
    if (!s || !b) return HttpResponse.json({ error: "not found" }, { status: 404 })
    const body = (await request.json().catch(() => ({}))) as { category?: string }
    const category = body.category?.split(/[/.]/).map((p) => p.trim()).filter(Boolean).join(".") || s.category
    if (!category) return HttpResponse.json({ error: "no suggested category, name one", field: "category" }, { status: 400 })
    await delay(200)
    applyPatch(b, { kategorie: category })
    Object.assign(s, { status: "applied", category })
    return HttpResponse.json(s)
  }),
  http.post("/api/suggestions/:id/reject", async ({ params }) => {
    const s = suggestions.get(Number(params.id))
    if (!s) return HttpResponse.json({ error: "not found" }, { status: 404 })
    await delay(150)
    s.status = "rejected"
    return HttpResponse.json(s)
  }),
  http.post("/api/classify", async ({ request }) => {
    const { target = "unsorted" } = (await request.json().catch(() => ({}))) as { target?: ClassifyTarget }
    const paths = treePaths()
    if (paths.length < 2) return HttpResponse.json({ error: "too few categories", categories: paths.length, minCategories: 2 }, { status: 409 })
    const list =
      target === "unsorted"
        ? unsorted().filter((b) => !["pending", "rejected", "none"].includes(suggestions.get(b.id)?.status ?? ""))
        : target.ids.flatMap((id) => books.filter((b) => b.id === id))
    const jobId = Math.random().toString(36).slice(2)
    const job = { id: jobId, startedAt: new Date().toISOString(), status: "running" as Job["status"], done: 0, total: list.length, errors: [] }
    jobs.set(jobId, job)
    lastClassify = job
    ;(async () => {
      for (const b of list) {
        await delay(25)
        suggest(b, b.id % 3)
        job.done++
      }
      job.status = "done"
    })()
    return HttpResponse.json({ jobId, total: list.length }, { status: 202 })
  }),
  http.get("/api/jobs/:id", ({ params }) => {
    const job = jobs.get(String(params.id))
    return job ? HttpResponse.json(job) : HttpResponse.json({ error: "not found" }, { status: 404 })
  }),
]

const metadata = metadataHandlers({
  books,
  jobs,
  touch,
  filterBooks,
  delay,
  setCover: (id, svg) => {
    if (svg) customCovers.set(id, { body: new TextEncoder().encode(svg).buffer as ArrayBuffer, type: "image/svg+xml" })
    else customCovers.delete(id)
  },
})

export const setLoggedIn = (v: boolean) => {
  loggedIn = v
}

const listMocks = listHandlers(books, (target) => ("ids" in target ? books.filter((b) => target.ids.includes(b.id)) : filterBooks(bookSearchParams(target.query))))

const duplicates = duplicateHandlers({ books, touch, moveToTrash, restoreFromTrash, withLists, delay })

export const handlers = [...listMocks, ...progressHandlers, ...readerSettingsHandlers, ...writeHandlers, ...metadata, ...duplicates, ...readHandlers]
