import { http, HttpResponse } from "msw"
import type { Book, BulkTarget, ListPatch, ReadingList, Visibility } from "@/lib/api"
import { VISIBILITIES } from "@/lib/api"

// Reading lists like the hub keeps them: "Leseliste" (from the old tag,
// synced, default, favorite), "Urlaub" (favorite) and "Klassiker".
interface MockList extends Omit<ReadingList, "count" | "coverBookIds" | "editable"> {
  items: { bookId: number; addedAt: number }[]
}

const USER = "arthur"
let nextId = 1
const lists: MockList[] = []
const now = () => new Date().toISOString()

function make(name: string, patch: Partial<MockList> = {}): MockList {
  const at = now()
  const l: MockList = {
    id: nextId++, name, description: "", owner: USER, visibility: "private", sync: false, favorite: false, isDefault: false,
    createdAt: at, updatedAt: at, lastUsedAt: null, items: [], ...patch,
  }
  lists.push(l)
  return l
}

export function seedLists(books: Book[]) {
  const t0 = Date.UTC(2026, 9, 1)
  const leseliste = make("Leseliste", { sync: true, isDefault: true, favorite: true, description: "Was als Nächstes auf den Boox kommt." })
  books.filter((b) => b.tags.includes("leseliste")).forEach((b, i) => leseliste.items.push({ bookId: b.id, addedAt: t0 + i * 60_000 }))
  const urlaub = make("Urlaub", { favorite: true, description: "Für den Sommer am Meer." })
  ;[11, 12, 13].forEach((id, i) => urlaub.items.push({ bookId: id, addedAt: t0 + i * 60_000 }))
  urlaub.lastUsedAt = new Date(t0).toISOString()
  make("Klassiker")
}

const view = (l: MockList): ReadingList => {
  const { items, ...rest } = l
  const newest = [...items].sort((a, b) => b.addedAt - a.addedAt)
  return { ...rest, count: items.length, coverBookIds: newest.slice(0, 4).map((i) => i.bookId), editable: true }
}

const sorted = () => [...lists].sort((a, b) => Number(b.favorite) - Number(a.favorite) || a.name.localeCompare(b.name, "de", { sensitivity: "base" }))

export const withLists = <T extends Book>(b: T): T => ({ ...b, lists: lists.filter((l) => l.items.some((i) => i.bookId === b.id)).map((l) => l.id) })

// ids of a list, most recently added first; null for an unknown list
export function listBookIds(id: number): number[] | null {
  const l = lists.find((x) => x.id === id)
  return l ? [...l.items].sort((a, b) => b.addedAt - a.addedAt).map((i) => i.bookId) : null
}

// a deleted book leaves its lists
export const dropFromLists = (bookId: number) => lists.forEach((l) => (l.items = l.items.filter((i) => i.bookId !== bookId)))

const notFound = () => HttpResponse.json({ error: "not found" }, { status: 404 })
const invalid = (field: string, error: string) => HttpResponse.json({ error, field }, { status: 400 })

function apply(l: MockList, patch: ListPatch): Response | null {
  if (patch.name !== undefined) {
    const name = patch.name.trim()
    if (!name) return invalid("name", "name expected")
    if (lists.some((x) => x !== l && x.name.toLowerCase() === name.toLowerCase())) return HttpResponse.json({ error: `a list named ${name} exists`, field: "name" }, { status: 409 })
    l.name = name
  }
  if (patch.description !== undefined) l.description = (patch.description ?? "").trim()
  if (patch.visibility !== undefined) {
    if (!VISIBILITIES.includes(patch.visibility as Visibility)) return invalid("visibility", "one of private, readable, editable")
    l.visibility = patch.visibility
  }
  if (patch.sync !== undefined) l.sync = patch.sync
  if (patch.favorite !== undefined) l.favorite = patch.favorite
  if (patch.isDefault !== undefined) {
    if (patch.isDefault) lists.forEach((x) => (x.isDefault = false))
    l.isDefault = patch.isDefault
  }
  l.updatedAt = now()
  return null
}

export function listHandlers(books: Book[], resolve: (target: BulkTarget) => Book[]) {
  const bookIdsOf = async (request: Request) => {
    const body = (await request.json()) as { bookIds?: number[]; target?: BulkTarget }
    if (body.bookIds) return body.bookIds
    if (body.target) return resolve(body.target).map((b) => b.id)
    return null
  }
  return [
    http.get("/api/lists", () => HttpResponse.json(sorted().map(view))),
    http.post("/api/lists", async ({ request }) => {
      const patch = (await request.json()) as ListPatch
      if (!patch.name?.trim()) return invalid("name", "name expected")
      if (lists.some((x) => x.name.toLowerCase() === patch.name!.trim().toLowerCase())) return HttpResponse.json({ error: "a list with this name exists", field: "name" }, { status: 409 })
      const l = make(patch.name.trim())
      apply(l, { ...patch, name: undefined })
      return HttpResponse.json(view(l), { status: 201 })
    }),
    http.get("/api/lists/:id", ({ params }) => {
      const l = lists.find((x) => x.id === Number(params.id))
      return l ? HttpResponse.json(view(l)) : notFound()
    }),
    http.patch("/api/lists/:id", async ({ params, request }) => {
      const l = lists.find((x) => x.id === Number(params.id))
      if (!l) return notFound()
      return apply(l, (await request.json()) as ListPatch) ?? HttpResponse.json(view(l))
    }),
    http.delete("/api/lists/:id", ({ params }) => {
      const i = lists.findIndex((x) => x.id === Number(params.id))
      if (i < 0) return notFound()
      const [l] = lists.splice(i, 1)
      return HttpResponse.json({ list: view(l) })
    }),
    http.post("/api/lists/:id/books/remove", async ({ params, request }) => {
      const l = lists.find((x) => x.id === Number(params.id))
      if (!l) return notFound()
      const ids = await bookIdsOf(request)
      if (!ids) return invalid("bookIds", "bookIds or target expected")
      const removed = l.items.filter((i) => ids.includes(i.bookId)).map((i) => i.bookId)
      l.items = l.items.filter((i) => !ids.includes(i.bookId))
      return HttpResponse.json({ list: view(l), removed })
    }),
    http.post("/api/lists/:id/books", async ({ params, request }) => {
      const l = lists.find((x) => x.id === Number(params.id))
      if (!l) return notFound()
      const ids = await bookIdsOf(request)
      if (!ids) return invalid("bookIds", "bookIds or target expected")
      const known = new Set(books.map((b) => b.id))
      const at = Date.now()
      const added = [...new Set(ids)].filter((id) => known.has(id) && !l.items.some((i) => i.bookId === id))
      added.forEach((bookId) => l.items.push({ bookId, addedAt: at }))
      l.lastUsedAt = now()
      return HttpResponse.json({ list: view(l), added })
    }),
    http.get("/api/books/:id/lists", ({ params }) => HttpResponse.json(sorted().filter((l) => l.items.some((i) => i.bookId === Number(params.id))).map(view))),
  ]
}
