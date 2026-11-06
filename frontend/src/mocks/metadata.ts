import { http, HttpResponse } from "msw"
import type { Book, ImportRepairEntry, Job, MetadataCandidate, MetadataChange, MetadataField, MetadataSource, MetadataStatus, MetadataTarget } from "@/lib/api"
import { bookSearchParams } from "@/lib/api"
import { proposalBoard } from "./intake"

// Metadata cleanup of the mock hub: a few changed books from the start (a
// messy file name, an unknown author, an author spelling, a reverted
// publisher), runs that fill missing fields by id, reverts that restore the
// fields, and candidates for any book (DNB sure, Open Library, rules).

interface Context {
  books: Book[]
  jobs: Map<string, Job>
  touch: (b: Book) => void
  filterBooks: (p: URLSearchParams) => Book[]
  setCover: (id: number, svg: string | null) => void
  delay: (ms: number) => Promise<unknown>
}

const TAG = "auto-metadaten"
// spellings the author unification merges
const VARIANTS: Record<string, string> = { "Ursula K. LeGuin": "Ursula K. Le Guin", "Gaiman, Neil": "Neil Gaiman", "Kahneman, Daniel": "Daniel Kahneman" }

const coverSvg = (label: string, hue: number) =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="300" height="400"><rect width="300" height="400" fill="hsl(${hue} 55% 30%)"/><text x="20" y="200" font-family="serif" font-size="24" fill="#fff">${label.replace(/[<&]/g, "")}</text></svg>`

// "tolkien - der herr der ringe (z-lib.org)" → "Der herr der ringe"
export function cleanTitle(title: string): string {
  const t = title
    .replace(/\((z-lib\.org|libgen[^)]*|epub)\)/gi, "")
    .replace(/\.(epub|pdf|mobi|azw3)$/i, "")
    .replace(/_/g, " ")
    .replace(/^[^-]+ - /, "")
    .replace(/\s+/g, " ")
    .trim()
  return t ? t[0].toUpperCase() + t.slice(1) : title
}

export function metadataHandlers({ books, jobs, touch, filterBooks, setCover, delay }: Context) {
  const changes: MetadataChange[] = []
  let nextId = 1
  let lastRun: MetadataStatus["lastRun"] = null

  const get = (b: Book, field: MetadataField): unknown => {
    if (field === "isbn") return b.identifiers.isbn ?? null
    if (field === "cover") return null
    return b[field] ?? null
  }
  const put = (b: Book, field: MetadataField, value: unknown) => {
    if (field === "isbn") {
      const { isbn: _old, ...rest } = b.identifiers
      b.identifiers = value ? { ...rest, isbn: String(value) } : rest
    } else if (field === "cover") setCover(b.id, value ? coverSvg("neues Cover", (b.id * 71) % 360) : null)
    else Object.assign(b, { [field]: value })
  }

  function record(b: Book, field: MetadataField, value: unknown, source: MetadataSource, jobId: string | null, at = new Date().toISOString()) {
    const old = get(b, field)
    put(b, field, value)
    changes.push({ id: nextId++, bookId: b.id, field, old, new: value, source, jobId, at, revertedAt: null })
    if (!b.tags.includes(TAG)) b.tags = [...b.tags, TAG]
    touch(b)
  }

  type Revert = { ok: true; book: Book } | { ok: false; status: number; error: string; book?: Book }
  function revert(c: MetadataChange): Revert {
    const b = books.find((x) => x.id === c.bookId)
    if (!b) return { ok: false, status: 404, error: "book not found" }
    if (c.revertedAt) return { ok: false, status: 409, error: "already reverted", book: b }
    if (c.field !== "cover" && JSON.stringify(get(b, c.field)) !== JSON.stringify(c.new)) return { ok: false, status: 409, error: "changed in the meantime", book: b }
    put(b, c.field, c.old)
    c.revertedAt = new Date().toISOString()
    if (!changes.some((x) => x.bookId === b.id && !x.revertedAt)) b.tags = b.tags.filter((t) => t !== TAG)
    touch(b)
    return { ok: true, book: b }
  }

  // The starting state: books from the end of the library, set to how they
  // looked before the cleanup, then changed through the log
  if (books.length >= 12) {
    const ago = (days: number, minutes = 0) => new Date(Date.now() - days * 864e5 - minutes * 6e4).toISOString()
    const tail = books.slice(-12)
    const [lotr, leGuin1, leGuin2, kahneman, gaiman] = [tail[11], tail[10], tail[9], tail[8], tail[7]]
    // not in a series yet: series counts stay as the other tests expect
    const series = tail.slice(0, 7).find((b) => !b.series)

    Object.assign(lotr, { title: "tolkien - der herr der ringe (z-lib.org)", authors: ["Unbekannt"], authorSort: "Unbekannt", publisher: null, languages: [], identifiers: {} })
    record(lotr, "title", "Der Herr der Ringe", "rules", "seed-1", ago(1, 5))
    record(lotr, "authors", ["J. R. R. Tolkien"], "model", "seed-1", ago(1, 5))
    record(lotr, "authorSort", "Tolkien, J. R. R.", "rules", "seed-1", ago(1, 5))
    record(lotr, "isbn", "9783608939842", "dnb", "seed-1", ago(1, 4))
    record(lotr, "publisher", "Klett-Cotta", "dnb", "seed-1", ago(1, 4))
    record(lotr, "languages", ["deu"], "file", "seed-1", ago(1, 4))
    record(lotr, "cover", "https://covers.example/openlibrary/tolkien.jpg", "openlibrary", "seed-1", ago(1, 3))

    for (const b of [leGuin1, leGuin2]) {
      Object.assign(b, { authors: ["Ursula K. LeGuin"], authorSort: "LeGuin, Ursula K." })
      record(b, "authors", ["Ursula K. Le Guin"], "authors", "seed-2", ago(2))
      record(b, "authorSort", "Le Guin, Ursula K.", "authors", "seed-2", ago(2))
    }

    Object.assign(kahneman, { title: "Kahneman_Schnelles Denken, langsames Denken", authors: ["Daniel Kahneman"], authorSort: "Kahneman, Daniel", pubdate: null, comments: null })
    record(kahneman, "title", "Schnelles Denken, langsames Denken", "rules", "seed-3", ago(3))
    record(kahneman, "pubdate", "2012-05-21", "openlibrary", "seed-3", ago(3))
    record(kahneman, "comments", "<p>Ein Klassiker der Verhaltensökonomie über die zwei Systeme des Denkens &amp; ihre Denkfehler.</p>", "dnb", "seed-3", ago(3))

    if (series) {
      series.publisher = "Piper"
      record(series, "series", "Foundation", "openlibrary", "seed-4", ago(4))
      record(series, "seriesIndex", 4, "openlibrary", "seed-4", ago(4))
      record(series, "publisher", "Goldmann", "dnb", "seed-4", ago(4))
      revert(changes[changes.length - 1])
    }

    // left for "Autoren vereinheitlichen"
    Object.assign(gaiman, { authors: ["Gaiman, Neil"], authorSort: "Gaiman, Neil" })
  }

  const incomplete = (b: Book) =>
    !b.identifiers.isbn || !b.publisher || !b.pubdate || !b.languages.length || cleanTitle(b.title) !== b.title || b.authors.some((a) => VARIANTS[a])

  // what a run finds for a book, decided by id
  function check(b: Book, jobId: string, onlyAuthors: boolean) {
    const authors = b.authors.map((a) => VARIANTS[a] ?? a)
    if (authors.some((a, i) => a !== b.authors[i])) {
      record(b, "authors", authors, "authors", jobId)
      record(b, "authorSort", authors[0].split(" ").reverse().join(", "), "authors", jobId)
    }
    if (onlyAuthors) return
    if (cleanTitle(b.title) !== b.title) record(b, "title", cleanTitle(b.title), "rules", jobId)
    if (!b.identifiers.isbn && b.id % 4 === 0) record(b, "isbn", `978360${String(b.id).padStart(6, "0")}`, "dnb", jobId)
    if (!b.publisher && b.id % 4 === 1) record(b, "publisher", "Fischer Taschenbuch", "openlibrary", jobId)
    if (!b.pubdate && b.id % 4 === 2) record(b, "pubdate", `${1980 + (b.id % 40)}-03-01`, "file", jobId)
    if (!b.languages.length) record(b, "languages", ["deu"], "file", jobId)
  }

  function targetBooks(target: MetadataTarget): Book[] {
    if (target === "all" || target === "authors") return books
    if (target === "incomplete") return books.filter(incomplete)
    if ("ids" in target) return target.ids.flatMap((id) => books.filter((b) => b.id === id))
    return filterBooks(bookSearchParams(target.query))
  }

  const [r1, r2, r3] = books
  const sure = (confidence: number, band: ImportRepairEntry["band"], level: ImportRepairEntry["level"], source: string) =>
    ({ confidence, band, level, source, titleConfidence: confidence, authorsConfidence: confidence, notes: [] })
  let repair: ImportRepairEntry[] = [
    { bookId: r1.id, file: "/srv/media/ebooks/backlog/Defaults/Algebra/Carr - Formulas and Theorems in Pure Mathematics 2e (Chelsea, 1970).djvu",
      decided: "name", status: "pending", at: "2026-11-03T12:00:00Z", ...sure(70, "review", 3, "rules"),
      changes: [
        { field: "title", old: r1.title, new: "Formulas and Theorems in Pure Mathematics" },
        { field: "authors", old: r1.authors, new: ["Carr"] },
        { field: "publisher", old: null, new: "Chelsea" },
        { field: "pubdate", old: null, new: "1970" },
      ] },
    { bookId: r2.id, file: "/srv/media/ebooks/backlog/fiction.science/Herbert - Dune.mobi", decided: "hardcover", status: "pending",
      at: "2026-11-03T12:00:00Z", ...sure(98, "bulk", 1, "hardcover"), changes: [{ field: "title", old: r2.title, new: "Dune" }, { field: "authors", old: r2.authors, new: ["Herbert"] }] },
    { bookId: r3.id, file: "/srv/media/ebooks/backlog/Defaults/Wine Tasting - A Professional Handbook.pdf", decided: "unsure", status: "pending",
      at: "2026-11-03T12:00:00Z", ...sure(30, "unsure", 3, "rules"), changes: [{ field: "tags", old: [], new: ["auto-unsicher"] }] },
  ]
  // the Eingang's filter shows these
  proposalBoard.entries = () => repair
  proposalBoard.books = books
  proposalBoard.decide = (ids) => {
    repair = repair.filter((e) => !ids.includes(e.bookId))
  }
  return [
    http.get("/api/metadata/status", () => {
      const active = new Set(changes.filter((c) => !c.revertedAt).map((c) => c.bookId))
      return HttpResponse.json({
        enabled: true,
        sources: ["file", "hardcover", "dnb", "openlibrary"],
        model: "qwen2.5:3b",
        nightly: "03:30",
        running: lastRun?.status === "running",
        changedBooks: active.size,
        lastRun,
      } satisfies MetadataStatus)
    }),
    http.post("/api/metadata/run", async ({ request }) => {
      const { target = "incomplete" } = (await request.json().catch(() => ({}))) as { target?: MetadataTarget }
      const list = targetBooks(target)
      const jobId = Math.random().toString(36).slice(2)
      const job = {
        id: jobId,
        startedAt: new Date().toISOString(),
        target: typeof target === "string" ? target : "ids" in target ? "ids" : "query",
        status: "running" as Job["status"],
        done: 0,
        total: list.length,
        errors: [] as Job["errors"],
      }
      jobs.set(jobId, job)
      lastRun = job
      ;(async () => {
        for (const b of list) {
          await delay(target === "authors" ? 2 : 8)
          // Open Library times out for some books
          if (target !== "authors" && b.id % 53 === 0) job.errors.push({ bookId: b.id, error: "Open Library: timeout" })
          else check(b, jobId, target === "authors")
          job.done++
        }
        job.status = "done"
      })()
      return HttpResponse.json({ jobId, total: list.length }, { status: 202 })
    }),
    http.get("/api/metadata/changes", ({ request }) => {
      const p = new URL(request.url).searchParams
      const bookId = p.get("bookId")
      const since = p.get("since")
      const reverted = p.get("reverted")
      const list = changes
        .filter(
          (c) =>
            (!bookId || c.bookId === Number(bookId)) &&
            (!since || c.at >= since) &&
            (reverted == null || (reverted === "true") === !!c.revertedAt),
        )
        .sort((a, b) => b.at.localeCompare(a.at) || b.id - a.id)
        .slice(0, Number(p.get("limit") ?? 500))
      const ids = new Set(list.map((c) => c.bookId))
      return HttpResponse.json({ changes: list, books: books.filter((b) => ids.has(b.id)).map(({ comments: _c, ...b }) => b) })
    }),
    http.post("/api/metadata/changes/revert", async ({ request }) => {
      const { bookIds = [], changeIds = [] } = (await request.json()) as { bookIds?: number[]; changeIds?: number[] }
      await delay(200)
      const picked = changes.filter((c) => !c.revertedAt && (bookIds.includes(c.bookId) || changeIds.includes(c.id)))
      const reverted: MetadataChange[] = []
      const errors: { changeId: number; bookId: number; error: string }[] = []
      // newest first: an older change of the same field comes back last
      for (const c of [...picked].sort((a, b) => b.id - a.id)) {
        const r = revert(c)
        if (r.ok) reverted.push(c)
        else errors.push({ changeId: c.id, bookId: c.bookId, error: r.error })
      }
      return HttpResponse.json({ reverted, errors })
    }),
    http.post("/api/metadata/changes/:id/revert", async ({ params }) => {
      const c = changes.find((x) => x.id === Number(params.id))
      if (!c) return HttpResponse.json({ error: "not found" }, { status: 404 })
      await delay(150)
      const r = revert(c)
      return r.ok ? HttpResponse.json({ change: c, book: r.book }) : HttpResponse.json({ error: r.error, book: r.book }, { status: r.status })
    }),
    http.get("/api/books/:id/metadata/candidates", async ({ params, request }) => {
      const b = books.find((x) => x.id === Number(params.id))
      if (!b) return HttpResponse.json({ error: "not found" }, { status: 404 })
      const q = new URL(request.url).searchParams.get("q")?.trim()
      await delay(600)
      if (q === "nichts") return HttpResponse.json({ candidates: [] })
      const title = q || cleanTitle(b.title)
      const authors = b.authors.map((a) => VARIANTS[a] ?? a)
      const candidates: MetadataCandidate[] = [
        {
          source: "dnb",
          score: 0.97,
          sure: true,
          url: `https://d-nb.info/${1_000_000_000 + b.id}`,
          fields: { title, authors, isbn: `978360${String(b.id).padStart(6, "0")}`, publisher: "Klett-Cotta", pubdate: "2012-03-01", languages: ["deu"] },
        },
        {
          source: "openlibrary",
          score: 0.81,
          sure: false,
          url: `https://openlibrary.org/works/OL${b.id}W`,
          fields: {
            title,
            authors,
            pubdate: "2011-09-15",
            comments: `<p>${title}: eine Geschichte über <b>Mut</b> und Freundschaft.</p>`,
            series: "Foundation",
            seriesIndex: 2,
            coverUrl: `https://covers.example/openlibrary/${b.id}.jpg`,
          },
        },
      ]
      if (!q) candidates.push({ source: "rules", score: 0.6, sure: false, url: null, fields: { title: cleanTitle(b.title), authors } })
      return HttpResponse.json({ candidates })
    }),
    // stand-ins for cover images of the sources (never fetch the real ones)
    http.get("https://covers.example/*", ({ request }) => {
      const name = new URL(request.url).pathname.split("/").pop() ?? ""
      return new HttpResponse(coverSvg(name, (name.length * 53) % 360), { headers: { "Content-Type": "image/svg+xml" } })
    }),
  ]
}
