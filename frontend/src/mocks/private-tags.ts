import { http, HttpResponse } from "msw"
import type { Book, BulkTarget, Named } from "@/lib/api"

// The users' private tags, like the hub's private_tags table: per user and
// book, a tag keeps the spelling the user has for it already
const store = new Map<string, Map<number, string[]>>()

const of = (user: string) => {
  let m = store.get(user)
  if (!m) store.set(user, (m = new Map()))
  return m
}
const same = (a: string, b: string) => a.toLowerCase() === b.toLowerCase()
const spelling = (user: string, tag: string) => [...of(user).values()].flat().find((t) => same(t, tag)) ?? tag
const sortTags = (tags: string[]) => [...tags].sort((a, b) => a.localeCompare(b, "de", { sensitivity: "base" }))

export const privateTagsOf = (user: string, bookId: number) => of(user).get(bookId) ?? []

export const withPrivateTags = <T extends Book>(user: string, b: T): T => ({ ...b, privateTags: privateTagsOf(user, b.id) })

export function privateCounts(user: string): Named[] {
  const counts = new Map<string, number>()
  for (const tags of of(user).values()) tags.forEach((t) => counts.set(t, (counts.get(t) ?? 0) + 1))
  return sortTags([...counts.keys()]).map((name) => ({ name, count: counts.get(name)! }))
}

// ptag=…: the books with all of them; null without ptag
export function privateFilter(user: string, p: URLSearchParams): Set<number> | null {
  const wanted = p.getAll("ptag").filter((t) => t.trim())
  if (!wanted.length) return null
  return new Set([...of(user).entries()].filter(([, tags]) => wanted.every((w) => tags.some((t) => same(t, w)))).map(([id]) => id))
}

const clean = (tags: unknown): string[] | string => {
  if (!Array.isArray(tags) || tags.some((t) => typeof t !== "string")) return "list of tags expected"
  const out: string[] = []
  for (const t of (tags as string[]).map((x) => x.trim()).filter(Boolean)) {
    if (t.includes(",")) return "no commas in a tag"
    if (!out.some((o) => same(o, t))) out.push(t)
  }
  return out
}

function change(user: string, bookId: number, add: string[], remove: string[]): boolean {
  const before = privateTagsOf(user, bookId)
  const next = [...before.filter((t) => !remove.some((r) => same(r, t)))]
  add.forEach((a) => next.some((t) => same(t, a)) || next.push(spelling(user, a)))
  if (next.length === before.length && next.every((t) => before.includes(t))) return false
  if (next.length) of(user).set(bookId, sortTags(next))
  else of(user).delete(bookId)
  return true
}

export function privateTagHandlers(books: Book[], user: () => string, resolve: (target: BulkTarget) => Book[]) {
  return [
    http.get("/api/private-tags", () => HttpResponse.json(privateCounts(user()))),
    http.post("/api/private-tags", async ({ request }) => {
      const body = (await request.json()) as { bookIds?: number[]; target?: BulkTarget; add?: unknown; remove?: unknown }
      const add = clean(body.add ?? [])
      const remove = clean(body.remove ?? [])
      if (typeof add === "string") return HttpResponse.json({ error: add, field: "add" }, { status: 400 })
      if (typeof remove === "string") return HttpResponse.json({ error: remove, field: "remove" }, { status: 400 })
      if (!add.length && !remove.length) return HttpResponse.json({ error: "nothing to change", field: "add" }, { status: 400 })
      const ids = body.bookIds ?? (body.target ? resolve(body.target).map((b) => b.id) : null)
      if (!ids) return HttpResponse.json({ error: "bookIds or target expected", field: "bookIds" }, { status: 400 })
      const known = ids.filter((id) => books.some((b) => b.id === id))
      const changed = known.filter((id) => change(user(), id, add, remove)).sort((a, b) => a - b)
      return HttpResponse.json({ total: known.length, changed })
    }),
    http.put("/api/books/:id/private-tags", async ({ params, request }) => {
      const id = Number(params.id)
      if (!books.some((b) => b.id === id)) return HttpResponse.json({ error: "not found" }, { status: 404 })
      const tags = clean(((await request.json()) as { tags?: unknown }).tags ?? [])
      if (typeof tags === "string") return HttpResponse.json({ error: tags, field: "tags" }, { status: 400 })
      change(user(), id, tags, privateTagsOf(user(), id).filter((t) => !tags.some((n) => same(n, t))))
      return HttpResponse.json({ bookId: id, privateTags: privateTagsOf(user(), id) })
    }),
  ]
}
