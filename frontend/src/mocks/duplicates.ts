import { http, HttpResponse } from "msw"
import type { Book } from "@/lib/api"
import type { DuplicateBook, DuplicateGroup, DuplicateReason, FieldChange, FormatMove, Merge, MergePlan } from "@/lib/duplicates"

// Duplicates of the mock hub: two seeded pairs like the live library (the
// same book twice with different editions, an Anna's Archive leftover of 80
// bytes next to the good PDF), found by ISBN and by title and author
// (normalized, the main title before ":"), merged like the hub does
// (formats, empty fields, tags, identifiers; the others to the trash) and
// undone (back from the trash with new ids, the fields set back).

interface Context {
  books: Book[]
  touch: (b: Book) => void
  moveToTrash: (b: Book) => void
  // the restored book, null when it's not in the trash
  restoreFromTrash: (id: number) => Book | null
  withLists: <T extends Book>(b: T) => T
  delay: (ms: number) => Promise<unknown>
}

const DEFAULT_THRESHOLD = 0.85
const ANNAS = "Implementing ISO 9001 2015 thrill your customers and -- Gillett, Jan -- BusinessPro collection, Oxford, United Kingdom, 2015 -- Infinite Ideas -- 9781908984500 -- -- Anna’s Archive"

const fold = (s: string) =>
  s
    .normalize("NFKD")
    .replace(/\p{Mn}/gu, "")
    .toLowerCase()
const tokens = (s: string) => fold(s).split(/[^\p{L}\p{N}]+/u).filter(Boolean)
const mainTitle = (b: Book) => {
  const parts = b.title.split(/\s+--\s+/)
  return (parts.length >= 3 ? parts[0] : b.title).split(/:\s+/)[0]
}
const UNKNOWN = new Set(["unknown", "unbekannt"])
const authorKeys = (b: Book) => {
  const parts = b.title.split(/\s+--\s+/)
  const names = b.authors.filter((a) => !UNKNOWN.has(fold(a)))
  const list = names.length ? names : parts.length >= 3 ? [parts[1]] : []
  // "Gillett, Jan" and "Jan Gillett" alike
  return list.map((a) => (a.includes(",") ? a.split(",").reverse().join(" ") : a)).map((a) => tokens(a).join(""))
}
const isbns = (b: Book) => [b.identifiers.isbn, ...(b.title.match(/97[89]\d{10}/g) ?? [])].filter((x): x is string => !!x)

function similarity(a: Book, b: Book): number {
  const ta = tokens(mainTitle(a))
  const tb = tokens(mainTitle(b))
  if (!ta.length || !tb.length) return 0
  if (ta.join(" ") === tb.join(" ")) return 1
  const [short, long] = ta.length <= tb.length ? [ta, tb] : [tb, ta]
  if (short.length >= 3 && short.every((w, i) => long[i] === w)) return 0.9
  const sa = new Set(ta)
  const both = tb.filter((w) => sa.has(w)).length
  return (2 * both) / (ta.length + tb.length)
}

// a tiny file (the leftover) for ids in tiny, sizes from the id otherwise
const tiny = new Set<number>()
const files = (b: Book) => b.formats.map((format) => ({ format, size: tiny.has(b.id) ? 80 : 200_000 + b.id * 1013, tiny: tiny.has(b.id) }))
const broken = (b: Book) => b.formats.length === 0 || (tiny.has(b.id) && b.formats.length > 0)
const quality = (b: Book) =>
  [
    broken(b) ? 0 : 1,
    [b.identifiers.isbn, b.publisher, b.pubdate, b.languages.length, b.comments, b.series, b.tags.some((t) => t !== "auto-metadaten"), !b.title.includes(" -- ")].filter(Boolean).length,
    b.formats.includes("EPUB") ? 1 : 0,
    b.formats.length,
    -b.id,
  ] as number[]
const better = (a: Book, b: Book) => {
  const qa = quality(a)
  const qb = quality(b)
  for (let i = 0; i < qa.length; i++) if (qa[i] !== qb[i]) return qb[i] - qa[i]
  return 0
}

export function duplicateHandlers({ books, touch, moveToTrash, restoreFromTrash, withLists, delay }: Context) {
  const ignored = new Set<string>()
  const merges: Merge[] = []
  const pairKey = (a: number, b: number) => (a < b ? `${a}-${b}` : `${b}-${a}`)

  // the starting state: two pairs in the middle of the library
  if (books.length >= 200) {
    const [a, b, c, d] = [books[149], books[159], books[169], books[179]]
    const now = new Date().toISOString()
    Object.assign(a, {
      title: "Stop Letting Everything Affect You: How to Break Free From Overthinking",
      authors: ["Daniel Chidiac"],
      authorSort: "Chidiac, Daniel",
      formats: ["EPUB"],
      identifiers: { isbn: "9781764110822", goodreads: "237833933" },
      tags: ["Self Help"],
      publisher: null,
      pubdate: "2025-07-01T00:00:00+00:00",
      languages: ["eng"],
      comments: "<p>How to break free from overthinking.</p>",
      series: null,
      seriesIndex: null,
      lastModified: now,
    })
    Object.assign(b, {
      title: "Stop Letting Everything Affect You: How to break free from overthinking",
      authors: ["Daniel Chidiac"],
      authorSort: "Chidiac, Daniel",
      formats: ["EPUB", "PDF"],
      identifiers: { isbn: "9781764110808", "mobi-asin": "B0FGDPP7Q7" },
      tags: ["auto-metadaten"],
      publisher: "Undercover Publishing House",
      pubdate: null,
      languages: ["eng"],
      comments: null,
      series: null,
      seriesIndex: null,
      lastModified: now,
    })
    Object.assign(c, {
      title: "Implementing ISO 9001:2015",
      authors: ["Jan Gillett", "Paul Simpson"],
      authorSort: "Gillett, Jan & Simpson, Paul",
      formats: ["PDF"],
      identifiers: { isbn: "9781908984500" },
      series: null,
      seriesIndex: null,
      lastModified: now,
    })
    Object.assign(d, {
      title: ANNAS,
      authors: ["Unknown"],
      authorSort: "Unknown",
      formats: ["PDF"],
      identifiers: {},
      tags: [],
      publisher: null,
      pubdate: null,
      comments: null,
      series: null,
      seriesIndex: null,
      lastModified: now,
    })
    tiny.add(d.id)
  }

  function detect(threshold: number): DuplicateGroup[] {
    const reasons = new Map<string, DuplicateReason[]>()
    const add = (a: Book, b: Book, r: Omit<DuplicateReason, "bookIds">) => {
      const key = pairKey(a.id, b.id)
      if (a.id === b.id || ignored.has(key)) return
      const list = reasons.get(key) ?? []
      if (!list.some((x) => x.kind === r.kind)) list.push({ ...r, bookIds: [Math.min(a.id, b.id), Math.max(a.id, b.id)] })
      reasons.set(key, list)
    }
    const byIsbn = new Map<string, Book[]>()
    const byAuthor = new Map<string, Book[]>()
    for (const b of books) {
      isbns(b).forEach((i) => byIsbn.set(i, [...(byIsbn.get(i) ?? []), b]))
      authorKeys(b).forEach((k) => byAuthor.set(k, [...(byAuthor.get(k) ?? []), b]))
    }
    byIsbn.forEach((list, isbn) => list.forEach((a, i) => list.slice(i + 1).forEach((b) => add(a, b, { kind: "isbn", detail: isbn }))))
    byAuthor.forEach((list) =>
      list.forEach((a, i) =>
        list.slice(i + 1).forEach((b) => {
          if (a.series && a.series === b.series && a.seriesIndex !== b.seriesIndex) return
          const s = similarity(a, b)
          if (s >= threshold) add(a, b, { kind: "title", detail: String(Math.round(s * 100) / 100) })
        }),
      ),
    )
    // a broken book in a pair
    reasons.forEach((list, key) => {
      const [a, b] = key.split("-").map((id) => books.find((x) => x.id === Number(id))!)
      if (broken(a) !== broken(b)) list.push({ kind: "broken", bookIds: [a.id, b.id], detail: String((broken(a) ? a : b).id) })
    })
    // groups over shared books
    const parent = new Map<number, number>()
    const find = (x: number): number => {
      while (parent.has(x) && parent.get(x) !== x) x = parent.get(x)!
      return x
    }
    reasons.forEach((_, key) => {
      const [a, b] = key.split("-").map(Number).map(find)
      if (a !== b) parent.set(Math.max(a, b), Math.min(a, b))
    })
    const groups = new Map<number, Set<number>>()
    reasons.forEach((_, key) => key.split("-").map(Number).forEach((id) => groups.set(find(id), (groups.get(find(id)) ?? new Set()).add(id))))
    return [...groups.values()]
      .map((set) => {
        const ids = [...set].sort((x, y) => x - y)
        const members = ids.map((id) => books.find((b) => b.id === id)!)
        const rs = [...reasons.entries()].filter(([k]) => k.split("-").every((id) => set.has(Number(id)))).flatMap(([, r]) => r)
        const sure = rs.some((r) => r.kind === "isbn" || r.kind === "file" || (r.kind === "title" && r.detail === "1"))
        const score = Math.max(...rs.map((r) => (r.kind === "title" ? Number(r.detail) : r.kind === "broken" ? 0 : 1)))
        const keep = [...members].sort(better)[0]
        const entries: DuplicateBook[] = members.map((b) => ({ book: withLists(b), hasCover: b.id % 13 !== 0, broken: broken(b), files: files(b) }))
        return { id: ids.join("-"), bookIds: ids, keepId: keep.id, sure, score, reasons: rs, books: entries }
      })
      .sort((a, b) => Number(b.sure) - Number(a.sure) || b.score - a.score || a.bookIds[0] - b.bookIds[0])
  }

  const empty = (v: unknown) => v == null || v === "" || (Array.isArray(v) && v.length === 0)
  const FILL = ["publisher", "pubdate", "languages", "comments", "rating"] as const

  function plan(keep: Book, others: Book[]): MergePlan {
    const sorted = [...others].sort(better)
    const formats: FormatMove[] = []
    for (const o of sorted) {
      if (tiny.has(o.id)) continue
      for (const f of o.formats) if (!keep.formats.includes(f) && !formats.some((m) => m.format === f)) formats.push({ format: f, from: o.id, replace: false })
    }
    const fields: FieldChange[] = []
    for (const f of FILL) {
      if (!empty(keep[f])) continue
      const from = sorted.find((o) => !empty(o[f]))
      if (from) fields.push({ field: f, old: keep[f] ?? null, new: from[f] })
    }
    const ids = { ...keep.identifiers }
    sorted.forEach((o) => Object.entries(o.identifiers).forEach(([k, v]) => (ids[k] ??= v)))
    if (Object.keys(ids).length > Object.keys(keep.identifiers).length) fields.push({ field: "identifiers", old: keep.identifiers, new: ids })
    const tags = [...keep.tags]
    sorted.forEach((o) => o.tags.forEach((t) => t !== "auto-metadaten" && !tags.some((x) => x.toLowerCase() === t.toLowerCase()) && tags.push(t)))
    if (tags.length > keep.tags.length) fields.push({ field: "tags", old: keep.tags, new: tags })
    return { keepId: keep.id, otherIds: sorted.map((o) => o.id), fields, formats, coverFrom: null, lists: 0, progress: 0, trash: sorted.map((o) => o.id) }
  }

  const notFound = () => HttpResponse.json({ error: "not found" }, { status: 404 })

  return [
    http.get("/api/duplicates", ({ request }) => {
      const t = new URL(request.url).searchParams.get("threshold")
      const threshold = t ? Number(t) : DEFAULT_THRESHOLD
      if (!(threshold >= 0.5 && threshold <= 1)) return HttpResponse.json({ error: "number from 0.5 to 1 expected", field: "threshold" }, { status: 400 })
      return HttpResponse.json({ threshold, groups: detect(threshold) })
    }),
    http.post("/api/duplicates/merge", async ({ request }) => {
      const body = (await request.json()) as { keepId: number; bookIds: number[]; dryRun?: boolean; lastModified?: string }
      const keep = books.find((b) => b.id === body.keepId)
      const others = body.bookIds.filter((id) => id !== body.keepId).map((id) => books.find((b) => b.id === id))
      if (!others.length) return HttpResponse.json({ error: "at least one other book", field: "bookIds" }, { status: 400 })
      if (!keep || others.some((o) => !o)) return notFound()
      const p = plan(keep, others as Book[])
      if (body.dryRun) return HttpResponse.json({ plan: p })
      if (body.lastModified && body.lastModified !== keep.lastModified) return HttpResponse.json({ error: "changed in the meantime", book: keep }, { status: 409 })
      await delay(300)
      p.fields.forEach((f) => Object.assign(keep, { [f.field]: f.new }))
      p.formats.forEach((f) => (keep.formats = [...keep.formats, f.format]))
      touch(keep)
      const m: Merge = {
        id: merges.length + 1,
        keepId: keep.id,
        otherIds: p.otherIds,
        status: "done",
        at: new Date().toISOString(),
        undoneAt: null,
        error: null,
        fields: p.fields,
        formats: p.formats,
        coverFrom: null,
        listItems: [],
        trashed: [],
        restored: {},
        errors: [],
      }
      for (const o of others as Book[]) {
        moveToTrash(o)
        m.trashed.push(o.id)
      }
      merges.unshift(m)
      return HttpResponse.json({ merge: m, book: withLists(keep) })
    }),
    http.get("/api/duplicates/merges", () => HttpResponse.json(merges)),
    http.post("/api/duplicates/merges/:id/undo", async ({ params }) => {
      const m = merges.find((x) => x.id === Number(params.id))
      if (!m) return notFound()
      if (m.status === "undone") return HttpResponse.json({ error: "undone already" }, { status: 409 })
      await delay(300)
      for (const id of m.trashed) {
        const b = restoreFromTrash(id)
        if (b) m.restored[String(id)] = b.id
        else m.errors.push(`#${id} is not in the trash any more`)
      }
      const keep = books.find((b) => b.id === m.keepId)
      if (keep) {
        keep.formats = keep.formats.filter((f) => !m.formats.some((x) => x.format === f))
        for (const f of m.fields) {
          const now = (keep as unknown as Record<string, unknown>)[f.field]
          if (JSON.stringify(now) === JSON.stringify(f.new)) Object.assign(keep, { [f.field]: f.old })
          else m.errors.push(`${f.field} of #${keep.id} changed since, left as it is`)
        }
        touch(keep)
      }
      m.status = "undone"
      m.undoneAt = new Date().toISOString()
      const back = [m.keepId, ...Object.values(m.restored)].flatMap((id) => books.filter((b) => b.id === id))
      return HttpResponse.json({ merge: m, books: back })
    }),
    http.post("/api/duplicates/ignore/remove", async ({ request }) => {
      const { bookIds } = (await request.json()) as { bookIds: number[] }
      let removed = 0
      bookIds.forEach((a, i) => bookIds.slice(i + 1).forEach((b) => (removed += ignored.delete(pairKey(a, b)) ? 1 : 0)))
      return HttpResponse.json({ removed })
    }),
    http.post("/api/duplicates/ignore", async ({ request }) => {
      const { bookIds } = (await request.json()) as { bookIds: number[] }
      if (bookIds.length < 2) return HttpResponse.json({ error: "two books at least", field: "bookIds" }, { status: 400 })
      let n = 0
      bookIds.forEach((a, i) =>
        bookIds.slice(i + 1).forEach((b) => {
          if (!ignored.has(pairKey(a, b))) n++
          ignored.add(pairKey(a, b))
        }),
      )
      return HttpResponse.json({ ignored: n })
    }),
  ]
}
