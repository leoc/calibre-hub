import { http, HttpResponse } from "msw"
import type { Book } from "@/lib/api"
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

// Small subset of calibre's search: free words and languages:"=x".
function matches(b: Book, q: string) {
  const lang = /languages:"=([^"]+)"/.exec(q)?.[1]
  if (lang && !b.languages.includes(lang)) return false
  const text = q.replace(/languages:"=[^"]+"/, "").replace(/[()]|\band\b/g, " ").toLowerCase()
  const hay = [b.title, ...b.authors, b.series ?? "", ...b.tags].join(" ").toLowerCase()
  return text.split(/\s+/).filter(Boolean).every((w) => hay.includes(w))
}

const cover = (b: Book) => {
  const hue = (b.id * 47) % 360
  const title = b.title.replace(/[<&]/g, "")
  return `<svg xmlns="http://www.w3.org/2000/svg" width="300" height="400"><rect width="300" height="400" fill="hsl(${hue} 45% 40%)"/><text x="20" y="60" font-family="serif" font-size="26" fill="#fff">${title.slice(0, 18)}</text><text x="20" y="92" font-family="serif" font-size="26" fill="#fff">${title.slice(18, 36)}</text><text x="20" y="370" font-family="sans-serif" font-size="16" fill="#fff">${b.authors[0]}</text></svg>`
}

const auth = () => (loggedIn ? null : HttpResponse.json({ error: "login required" }, { status: 401 }))

export const handlers = [
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
    const k = p.get("kategorie")
    let list = books.filter((b) => {
      const cat = b.custom.kategorie as string | null
      if (k && !(cat === k || cat?.startsWith(`${k}.`))) return false
      if (p.getAll("tag").some((t) => !b.tags.includes(t))) return false
      if (p.get("author") && !b.authors.includes(p.get("author")!)) return false
      if (p.get("series") && b.series !== p.get("series")) return false
      return !p.get("q") || matches(b, p.get("q")!)
    })
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

export const setLoggedIn = (v: boolean) => {
  loggedIn = v
}
