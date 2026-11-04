import { http, HttpResponse } from "msw"
import type { Book, ImportRepairEntry, Job, MetadataCandidate, MetadataChange, MetadataField, MetadataSource, MetadataStatus, MetadataTarget } from "@/lib/api"
import { bookSearchParams } from "@/lib/api"

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

  let importPolls = 0
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
  const repairCounts = { applied: 0, rejected: 0, failed: 0 }
  const samples: { band: string; checked: number; correct: number; at: string }[] = []
  let repairJob: Job | null = null

  return [
    // the backlog import: a running import of 500 books (5 more each time
    // it is polled), a dry run walking another folder, a finished import,
    // a dry run and a cleanup
    // the repair of plain-file imports: three proposals (a name, a source
    // and an unsure one); accept applies title and authors, reject drops
    http.get("/api/import/repair", () => {
      const ids = repair.map((e) => e.bookId)
      return HttpResponse.json({
        entries: repair,
        books: books.filter((b) => ids.includes(b.id)),
        counts: { ...repairCounts, pending: repair.length },
        job: repairJob,
        planning: false,
        unsureTag: "auto-unsicher",
      })
    }),
    // the quality report: the library and two runs
    http.get("/api/import/quality", () =>
      HttpResponse.json({
        total: 1846,
        suspect: 212,
        reasons: { unknownAuthor: 191, notAPerson: 0, publisherAuthor: 4, titleSaysNothing: 11, leftoverTitle: 1, fileNameTitle: 24, unsure: 11 },
        runs: [
          { run: "77ec37bda5d6d688", at: "2026-11-03T08:48:59Z", total: 437, suspect: 120 },
          { run: "8c6205172f4fdbb7", at: "2026-11-03T07:35:32Z", total: 196, suspect: 41 },
        ],
        books: [{ id: 1617, title: "Compilers: Principles, Techniques and Tools", authors: ["Unknown"], reasons: ["unknownAuthor"] }],
        bands: { bulk: 900, review: 500, unsure: 346, none: 100 },
        levels: { "1": 700, "2": 600, "3": 446 },
        isbn: { with: 800, without: 1046, sources: { text: 400, ocr: 120, calibre: 280 } },
        conflicts: { duplicates: [{ isbn: "9780201914658", books: [1, 2] }], duplicateCount: 1, noted: [], notedCount: 3 },
        samples,
      }),
    ),
    http.get("/api/import/quality/sample", ({ request }) =>
      HttpResponse.json({
        band: new URL(request.url).searchParams.get("band"),
        books: [{ id: r2.id, title: r2.title, authors: r2.authors, confidence: 98, level: 1, source: "hardcover" }],
      }),
    ),
    http.post("/api/import/quality/sample", async ({ request }) => {
      const body = (await request.json()) as { band: string; checked: number; correct: number }
      const sample = { ...body, at: "2026-11-04T12:00:00Z" }
      samples.splice(0, samples.length, sample)
      return HttpResponse.json(sample, { status: 201 })
    }),
    http.post("/api/import/repair", () => {
      repairJob = { status: "done", done: 3, total: 3, errors: [] }
      return HttpResponse.json({ dryRun: true, books: 3, job: { id: "repair-plan", ...repairJob } }, { status: 202 })
    }),
    http.post("/api/import/repair/accept", async ({ request }) => {
      const body = (await request.json()) as { bookIds?: number[]; band?: string }
      const take = repair.filter((e) => e.band === body.band || body.bookIds?.includes(e.bookId))
      for (const e of take) {
        const b = books.find((x) => x.id === e.bookId)
        if (!b) continue
        for (const c of e.changes) {
          if (c.field === "title") b.title = String(c.new)
          if (c.field === "authors") b.authors = c.new as string[]
          if (c.field === "tags") b.tags = c.new as string[]
        }
        touch(b)
      }
      repair = repair.filter((e) => !take.includes(e))
      repairCounts.applied += take.length
      repairJob = { status: "done", done: take.length, total: take.length, errors: [] }
      return HttpResponse.json({ books: take.length, job: { id: "repair-apply", ...repairJob } }, { status: 202 })
    }),
    http.post("/api/import/repair/reject", async ({ request }) => {
      const body = (await request.json()) as { bookIds?: number[]; all?: boolean }
      const before = repair.length
      repair = repair.filter((e) => !(body.all || body.bookIds?.includes(e.bookId)))
      repairCounts.rejected += before - repair.length
      return HttpResponse.json({ rejected: before - repair.length })
    }),
    http.get("/api/import", () => {
      importPolls += 1
      const done = Math.min(260 + importPolls * 5, 500)
      const summary = {
        books: 1240, files: 1530, formats: { PDF: 900, MOBI: 400, EPUB: 230 }, calibreFolders: 360, withCover: 340,
        toAdd: 1100, toAddFormats: 40, duplicates: { total: 100, isbn: 60, title: 30, file: 10 }, alreadyImported: 0,
        skipped: { total: 9800, byReason: { "not a book format": 9700, "too small": 100 }, byType: { mp3: 4505, flv: 3740 } },
      }
      const backlogSummary = {
        books: 17_900, files: 21_400, formats: { EPUB: 9000, PDF: 8000, MOBI: 900 }, calibreFolders: 6000, withCover: 5900,
        toAdd: 17_500, toAddFormats: 100, duplicates: { total: 300, title: 200, isbn: 100 }, alreadyImported: 12,
        limit: 500, selected: { books: 500, toAdd: 490, toAddFormats: 2, duplicates: 8 }, deferred: 17_400,
        skipped: { total: 2100, byReason: { "not a book format": 2000, "too small": 100 }, byType: { jpg: 2000, txt: 100 } },
      }
      // of the running import: 2 failed, 8 duplicates, the rest imported
      const imported = Math.max(done - 10, 0)
      return HttpResponse.json({
        enabled: true,
        roots: ["/srv/media/ebooks/inbox"],
        running: true,
        scanning: true,
        hooksPaused: true,
        phase: "import",
        backlog: {
          imported: 1100 + imported, formatAdded: 40, duplicates: 106,
          open: { books: 17_500 - 10 - imported, formats: 100, duplicates: 292, failed: 2 },
          total: 18_590,
          basis: { runId: "r4", paths: ["/srv/media/ebooks/backlog"], createdAt: "2026-11-03T09:00:00Z" },
          etaSeconds: 49_800,
        },
        followup: { paused: true, total: 1360, queues: { embed: 60, metadata: 1300 } },
        runs: [
          { id: "r4", path: "/srv/media/ebooks/backlog", paths: ["/srv/media/ebooks/backlog"], dryRun: false, limit: 500,
            createdAt: "2026-11-03T09:00:00Z", jobId: "j4", status: "running", phase: "import",
            current: "/srv/media/ebooks/backlog/Fontane, Theodor/Effi Briest (412)",
            startedAt: "2026-11-03T09:00:05Z", scannedAt: "2026-11-03T09:04:00Z", finishedAt: null,
            elapsedSeconds: 3725, filesPerSecond: null, booksPerMinute: 21.5, etaSeconds: 250, done, total: 500, error: null,
            scan: { files: 23_500, units: 17_900, planned: 17_900, phase: "check", path: null }, summary: backlogSummary,
            results: { imported, duplicate: 8, failed: 2, pending: 500 - done, deferred: 17_400 },
            failures: [
              { path: "/srv/media/ebooks/backlog/Unbekannt/kaputt.pdf", detail: "calibre-server: HTTP 500 (NoSuchBook)" },
              { path: "/srv/media/ebooks/backlog/Alt/Scan (3)", detail: "ebook-meta timed out" },
            ] },
          { id: "r3", path: "/srv/media/ebooks/neu", paths: ["/srv/media/ebooks/neu"], dryRun: true, limit: 200,
            createdAt: "2026-11-03T08:00:00Z", jobId: "j3", status: "scanning", phase: "scan", current: "/srv/media/ebooks/neu/Comics/Asterix",
            startedAt: "2026-11-03T08:00:01Z", scannedAt: null, finishedAt: null, elapsedSeconds: 95, filesPerSecond: 135.2, booksPerMinute: null,
            etaSeconds: null, done: null, total: 0, error: null,
            scan: { files: 12840, units: 6210, planned: 0, phase: "scan", path: "/srv/media/ebooks/neu/Comics/Asterix" }, summary: null, results: {}, failures: [] },
          { id: "r2", path: "/srv/media/ebooks/inbox", dryRun: false, createdAt: "2026-11-02T20:10:00Z", jobId: "j2", status: "done", phase: "done",
            startedAt: "2026-11-02T20:10:00Z", scannedAt: "2026-11-02T20:11:00Z", finishedAt: "2026-11-02T21:12:30Z", elapsedSeconds: 3750, booksPerMinute: 20.2,
            done: 1240, total: 1240, error: null, summary, results: { imported: 1100, formatAdded: 40, duplicate: 98, failed: 2 } },
          { id: "r1", path: "/srv/media/ebooks/inbox", dryRun: true, createdAt: "2026-11-02T20:00:00Z", jobId: null, status: "planned",
            done: null, total: 1240, error: null, summary, results: { pending: 1240 } },
        ],
        cleanups: [{ id: "c1", createdAt: "2026-11-02T19:00:00Z", total: 1038, job: { status: "done", done: 1038, total: 1038, errors: [] }, undoJob: null }],
      })
    }),
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
