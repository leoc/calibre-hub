import { http, HttpResponse } from "msw"
import type { Book, BookPatch, BulkChanges, BulkTarget, Job } from "@/lib/api"
import { bookSearchParams } from "@/lib/api"
import { categories, makeBooks } from "./data"

const size = Number(import.meta.env.VITE_MOCK_BOOKS ?? 400)
export const books = makeBooks(size)
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
  return books.filter((b) => {
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
  http.get("/api/config", () => auth() ?? HttpResponse.json({ fastTags: ["leseliste"], categoryColumn: "kategorie" })),
  http.get("/api/categories", () => auth() ?? HttpResponse.json(categories(books))),
  http.get("/api/books", ({ request }) => {
    const denied = auth()
    if (denied) return denied
    const p = new URL(request.url).searchParams
    let list = filterBooks(p)
    const key = SORT_KEY[p.get("sort") ?? "title"]
    if (!key) return HttpResponse.json({ error: "unknown sort" }, { status: 400 })
    const dir = p.get("order") === "desc" ? -1 : 1
    list = [...list].sort((a, b) => (key(a) < key(b) ? -dir : key(a) > key(b) ? dir : 0))
    const offset = Number(p.get("offset") ?? 0)
    const limit = Math.min(Number(p.get("limit") ?? 50), 500)
    return HttpResponse.json({ total: list.length, offset, limit, books: list.slice(offset, offset + limit).map(({ comments: _c, ...b }) => b) })
  }),
  http.get("/api/books/:id", ({ params }) => {
    const b = books.find((x) => x.id === Number(params.id))
    return auth() ?? (b ? HttpResponse.json(b) : HttpResponse.json({ error: "not found" }, { status: 404 }))
  }),
  http.get("/api/books/:id/cover", ({ params }) => {
    const custom = customCovers.get(Number(params.id))
    if (custom) return new HttpResponse(custom.body, { headers: { "Content-Type": custom.type } })
    const b = books.find((x) => x.id === Number(params.id))
    if (!b || b.id % 13 === 0) return new HttpResponse(null, { status: 404 })
    return new HttpResponse(cover(b), { headers: { "Content-Type": "image/svg+xml" } })
  }),
  http.get("/api/books/:id/download/:format", ({ params }) =>
    new HttpResponse(`mock ${params.format} of book ${params.id}`, {
      headers: { "Content-Type": "application/octet-stream", "Content-Disposition": `attachment; filename="book-${params.id}.${params.format}"` },
    }),
  ),
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
      ["Open Library", "Google Books", "Open Library"].map((source, i) => ({
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
        } else {
          applyPatch(b, patch)
          if (numberSeries) b.seriesIndex = i + 1
        }
        job.done++
      }
      job.status = job.errors.length === list.length ? "failed" : "done"
    })()
    return HttpResponse.json({ jobId, total: list.length }, { status: 202 })
  }),
  http.get("/api/jobs/:id", ({ params }) => {
    const job = jobs.get(String(params.id))
    return job ? HttpResponse.json(job) : HttpResponse.json({ error: "not found" }, { status: 404 })
  }),
]

export const setLoggedIn = (v: boolean) => {
  loggedIn = v
}

export const handlers = [...writeHandlers, ...readHandlers]
