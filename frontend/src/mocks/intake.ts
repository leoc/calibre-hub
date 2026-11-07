import { http, HttpResponse } from "msw"
import type { Book, ConfidenceBand, ImportRepairEntry, IntakeCandidate, IntakeDetail, IntakeEntry } from "@/lib/api"
import pdfUrl from "./fixtures/sample.pdf?url"

// The Eingang of the mock hub: a dozen files like the live backlog, then
// enough scans that the list needs a second page. The analysis stands at one
// file, so the numbers read the same in every scenario.

const ROOT = "/srv/media/ebooks/backlog"

interface Seed {
  path: string
  title: string
  authors: string[]
  confidence: number
  level: 1 | 2 | 3 | null
  decided?: string
  candidates?: [string, string[], number, string, IntakeCandidate["fields"]?][]
  action?: "add" | "addFormats" | "duplicate"
  bookId?: number
  bookTitle?: string
  sameBook?: boolean
  sameAs?: string
  notes?: IntakeEntry["notes"]
  cover?: boolean
  failed?: string
}

const SEEDS: Seed[] = [
  {
    path: "Defaults/Functional Analysis 6th ed - K. Yoshida (Springer, 1980) WW.pdf",
    title: "Functional Analysis",
    authors: ["Kosaku Yosida"],
    confidence: 98,
    level: 1,
    decided: "openlibrary",
    cover: true,
    candidates: [
      ["Functional Analysis", ["Kosaku Yosida"], 98, "openlibrary", { coverUrl: "/api/intake/1/cover?v=1" }],
      ["Functional Analysis", ["K. Yoshida"], 80, "name", { publisher: "Springer" }],
    ],
  },
  { path: "Stem Cells - From Bench to Bedside - A. Bongso, E. Lee (World, 2005) WW.pdf", title: "Stem Cells: From Bench to Bedside", authors: ["Ariff Bongso", "Eng Hin Lee"], confidence: 90, level: 2, decided: "file" },
  {
    path: "Birds.pdf",
    title: "Britannica Illustrated Science Library: Birds",
    authors: ["Unknown"],
    confidence: 85,
    level: 1,
    decided: "hardcover",
    notes: [{ kind: "duplicateIsbn", isbn: "9781593394523", books: [7, 8] }],
    candidates: [
      ["Britannica Illustrated Science Library: Birds", ["Unknown"], 85, "hardcover"],
      ["Birds", ["Unknown"], 30, "name"],
    ],
  },
  { path: "Robbins - Basic Pathology 8e.chm", title: "Basic Pathology", authors: ["Robbins"], confidence: 70, level: 3, decided: "name" },
  { path: "Mathematics of the Discrete Fourier Transform.djvu", title: "Mathematics of the Discrete Fourier Transform", authors: ["Julius Smith"], confidence: 50, level: 3, decided: "openlibrary" },
  { path: "1380293052863.pdf", title: "1380293052863", authors: ["Unknown"], confidence: 10, level: 3, decided: "unsure" },
  {
    path: "Calculus/Stewart Calculus Concepts and Contexts 2nd Edition.pdf",
    title: "Calculus: Concepts and Contexts",
    authors: ["James Stewart"],
    confidence: 78,
    level: 2,
    decided: "file",
    action: "duplicate",
    bookId: 1,
    bookTitle: "Calculus: Concepts and Contexts",
    sameBook: true,
  },
  { path: "Kopie/Stem Cells - From Bench to Bedside.pdf", title: "Stem Cells: From Bench to Bedside", authors: ["Ariff Bongso"], confidence: 80, level: 3, decided: "name", action: "duplicate", sameAs: `${ROOT}/Stem Cells - From Bench to Bedside - A. Bongso, E. Lee (World, 2005) WW.pdf` },
  { path: "kaputt.pdf", title: "", authors: [], confidence: 0, level: null, failed: "pdfinfo: not a PDF" },
]

const band = (c: number): ConfidenceBand => (c >= 90 ? "bulk" : c >= 60 ? "review" : "unsure")

function entry(seed: Seed, id: number): IntakeDetail {
  const parts = seed.path.split("/")
  const name = parts.pop() as string
  const failed = seed.failed !== undefined
  const format = (name.split(".").pop() as string).toUpperCase()
  const candidates: IntakeCandidate[] = (seed.candidates ?? (failed ? [] : [[seed.title, seed.authors, seed.confidence, seed.level === 3 ? "name" : "file"]])).map(([title, authors, confidence, source, extra]) => ({
    source,
    confidence,
    fields: { title, authors, ...extra },
    url: null,
  }))
  return {
    id,
    path: `${ROOT}/${seed.path}`,
    name,
    folder: parts.join("/") || null,
    kind: "file",
    origin: "backlog",
    files: [{ path: `${ROOT}/${seed.path}`, format, size: 4_200_000 }],
    status: failed ? "failed" : "analysed",
    detail: seed.failed ?? null,
    proposal: failed ? null : { title: seed.title, authors: seed.authors, publisher: null, pubdate: null, series: null, seriesIndex: null, isbn: null, languages: [] },
    confidence: failed ? null : seed.confidence,
    band: failed ? null : band(seed.confidence),
    titleConfidence: failed ? null : seed.confidence,
    authorsConfidence: failed ? null : seed.confidence,
    level: seed.level,
    source: failed ? null : "rules",
    decided: seed.decided ?? null,
    isbnSource: null,
    notes: seed.notes ?? [],
    action: seed.action ?? "add",
    bookId: seed.bookId ?? null,
    match: seed.bookId ? "title" : null,
    sameAs: seed.sameAs ?? null,
    addFormats: [],
    cover: seed.cover ? `/api/intake/${id}/cover?v=1` : null,
    analysedAt: "2026-11-06T20:00:00Z",
    skipped: false,
    error: null,
    changes: [],
    candidates,
    bookTitle: seed.bookTitle ?? null,
    sameBook: seed.sameBook ?? false,
  }
}

const scans: Seed[] = Array.from({ length: 150 }, (_, i) => ({
  path: `Scans/scan-${String(i + 1).padStart(3, "0")}.pdf`,
  title: `scan-${String(i + 1).padStart(3, "0")}`,
  authors: ["Unknown"],
  confidence: 30,
  level: 3,
  decided: "unsure",
}))

// the surest first, then by path, as the hub has it
const ordered = (a: { confidence: number | null; path: string }, b: { confidence: number | null; path: string }) =>
  (b.confidence ?? -1) - (a.confidence ?? -1) || a.path.toLowerCase().localeCompare(b.path.toLowerCase())

let ENTRIES = [...SEEDS, ...scans].map((s, i) => entry(s, i + 1)).sort(ordered)
const IDS = ENTRIES.map((e) => e.id)
const LAST = Math.max(...IDS)

// what the mock hub was asked, for the scenarios (window.__intake)
const asked: { decision: string; ids: number[]; candidate?: number; picks?: unknown; title?: string; authors?: string[]; query?: unknown; expect?: number }[] = []
// the files read in, for the scenarios (window.__intakeReads)
const reads: string[] = []
const thresholds: Record<string, number | null> = { backlog: null, inbox: 90, upload: 90 }
// a job still running: the entry comes back with an error at the next look
let waiting: { entry: IntakeDetail; error: string } | null = null
if (typeof window !== "undefined") Object.assign(window, { __intake: asked, __intakeReads: reads })

// Two files that came another way, for the scenarios about sources
// (localStorage hub.mock.intake.sources)
const ELSEWHERE: Record<string, "inbox" | "upload"> = { "Birds.pdf": "inbox", "Robbins - Basic Pathology 8e.chm": "upload" }
function sources() {
  if (typeof localStorage === "undefined" || !localStorage.getItem("hub.mock.intake.sources")) return
  for (const e of ENTRIES) if (ELSEWHERE[e.name]) e.origin = ELSEWHERE[e.name]
}

// The file like another in the Eingang as one more of a book, for the scenario
// without anything left behind (localStorage hub.mock.intake.sameBooks)
function sameBooks() {
  if (typeof localStorage === "undefined" || !localStorage.getItem("hub.mock.intake.sameBooks")) return
  for (const e of ENTRIES) if (e.sameAs) Object.assign(e, { sameAs: null, bookId: 2, bookTitle: e.proposal?.title, sameBook: true })
}

// The book of the possible duplicate was renamed since the list was shown: the
// first bulk finds it out (localStorage hub.mock.intake.renamed)
function renamed(): boolean {
  if (typeof localStorage === "undefined" || !localStorage.getItem("hub.mock.intake.renamed")) return false
  localStorage.removeItem("hub.mock.intake.renamed")
  for (const e of ENTRIES) e.sameBook = false
  return true
}

// What an upload waits for in the mock Eingang (mocks/handlers.ts): the entry
// a decision goes to, the book added then
export const uploadBoard = {
  decide: (_entry: number, _decision: string, _book?: number) => false,
}

// The proposals for the library's books (mocks/metadata.ts). A proposal
// without a confidence is taken as it is.
export const proposalBoard = {
  entries: (): ImportRepairEntry[] => [],
  books: [] as Book[],
  decide: (_ids: number[], _how: "applied" | "rejected") => {},
}
const skippedBooks = new Set<number>()
// the book the accept job found changed: it stays, failed, and says why
const failedBooks = new Map<number, string>()
// the file of the one whose title was edited since the plan
const CHANGED = "Wine Tasting"
let rechecked = false

function libraryEntry(r: ImportRepairEntry): IntakeDetail {
  const book = proposalBoard.books.find((b) => b.id === r.bookId)
  const change = (field: string) => r.changes.find((c) => c.field === field)?.new
  const error = failedBooks.get(r.bookId) ?? null
  return {
    id: -r.bookId,
    path: r.file,
    name: r.file.split("/").pop() ?? "",
    folder: null,
    kind: "library",
    files: (book?.formats ?? []).map((format) => ({ path: "", format, size: 0 })),
    status: error ? "failed" : "analysed",
    detail: null,
    proposal: { title: (change("title") as string) ?? book?.title ?? "", authors: (change("authors") as string[]) ?? book?.authors ?? [], publisher: null, pubdate: null, series: null, seriesIndex: null, isbn: null, languages: [] },
    confidence: r.confidence,
    band: r.band,
    titleConfidence: r.titleConfidence,
    authorsConfidence: r.authorsConfidence,
    level: r.level,
    source: r.source,
    decided: r.decided,
    isbnSource: null,
    notes: r.notes,
    action: "update",
    bookId: r.bookId,
    match: null,
    sameAs: null,
    addFormats: [],
    cover: null,
    analysedAt: r.at,
    skipped: skippedBooks.has(r.bookId),
    error,
    bookTitle: book?.title ?? null,
    changes: r.changes.map((c) => ({ ...c, source: "rules" })),
    candidates: [],
    unsureTag: "auto-unsicher",
  }
}

const library = () => proposalBoard.entries().map(libraryEntry)
const libraryTakeable = (list: IntakeDetail[]) => list.filter((e) => e.status === "analysed" && !e.skipped)

function libraryList(q: URLSearchParams) {
  const all = library()
  const list = all.filter((e) => !q.get("band") || e.band === q.get("band")).sort((a, b) => (b.confidence ?? -1) - (a.confidence ?? -1) || (a.bookId ?? 0) - (b.bookId ?? 0))
  const take = libraryTakeable(list)
  const count = (b: string) => all.filter((e) => e.band === b).length
  return {
    total: list.length,
    counts: { bulk: count("bulk"), review: count("review"), unsure: count("unsure"), none: 0 },
    takeable: take.length,
    unsure: take.filter((e) => e.band === "unsure").length,
    left: { duplicates: 0, failed: list.filter((e) => e.status === "failed").length, skipped: list.filter((e) => e.status === "analysed" && e.skipped).length, unchanged: 0 },
    last: Math.max(0, ...all.map((e) => e.bookId ?? 0)),
    pending: 0,
    next: null,
    entries: list,
  }
}

const inFilter = (q: { band?: string | null; duplicates?: string | boolean | null; skipped?: string | boolean | null; origin?: string | null }) => {
  const dup = q.duplicates === null || q.duplicates === undefined ? null : String(q.duplicates) === "true"
  const skipped = String(q.skipped) === "true"
  return ENTRIES.filter((e) => (dup === null || (e.action !== "add") === dup) && (!skipped || e.skipped) && (!q.band || (e.band ?? "none") === q.band) && (!q.origin || e.origin === q.origin))
}

const takeable = (list: IntakeDetail[], skipped: boolean) => list.filter((e) => e.status === "analysed" && e.action !== "duplicate" && (skipped || !e.skipped))

const trashable = (list: IntakeDetail[]) => list.filter((e) => e.status === "analysed" && e.action === "duplicate" && e.sameBook && !e.skipped)

const limitOf = (q: URLSearchParams) => Number(q.get("limit") ?? 100)

const COVER = `<svg xmlns="http://www.w3.org/2000/svg" width="300" height="400"><rect width="300" height="400" fill="#475569"/></svg>`

export const intakeHandlers = [
  http.get("/api/intake", ({ request }) => {
    const q = new URL(request.url).searchParams
    sources()
    sameBooks()
    const filter = { duplicates: q.get("duplicates"), skipped: q.get("skipped"), origin: q.get("origin") }
    const pending = waiting ? 1 : 0
    if (waiting && limitOf(q) > 1) {
      // the job got to it: back in the list, with the reason
      waiting.entry.error = waiting.error
      ENTRIES = [...ENTRIES, waiting.entry].sort((a, b) => IDS.indexOf(a.id) - IDS.indexOf(b.id))
      waiting = null
    }
    const kind = inFilter(filter)
    const list = inFilter({ ...filter, band: q.get("band") })
    const after = q.get("after")
    const place = after ? { confidence: Number(after.slice(0, after.indexOf(":"))), path: after.slice(after.indexOf(":") + 1) } : null
    const from = place ? list.findIndex((e) => ordered(place, e) < 0) : 0
    const rest = from < 0 ? [] : list.slice(from)
    const limit = limitOf(q)
    const page = rest.slice(0, limit)
    const analysed = ENTRIES.filter((e) => e.status === "analysed").length
    const count = (b: string) => kind.filter((e) => (e.band ?? "none") === b).length
    const take = takeable(list, q.get("skipped") === "true")
    const skippedFilter = q.get("skipped") === "true"
    const left = {
      duplicates: list.filter((e) => e.status === "analysed" && e.action === "duplicate").length,
      failed: list.filter((e) => e.status !== "analysed").length,
      skipped: skippedFilter ? 0 : list.filter((e) => e.status === "analysed" && e.action !== "duplicate" && e.skipped).length,
      unchanged: 0,
    }
    const mode = typeof localStorage === "undefined" ? null : localStorage.getItem("hub.mock.intake")
    return HttpResponse.json({
      enabled: true,
      progress: { state: mode ?? "analysing", total: 1451 - (159 - ENTRIES.length), done: ENTRIES.length, analysed, current: "Mader - Biology - Inquiry into Life 9e HQ.pdf" },
      total: list.length,
      counts: { bulk: count("bulk"), review: count("review"), unsure: count("unsure"), none: count("none") },
      takeable: take.length,
      unsure: take.filter((e) => e.band === "unsure").length,
      trashable: q.get("duplicates") === "true" ? trashable(list).length : 0,
      left,
      skipped: ENTRIES.filter((e) => e.skipped).length,
      last: LAST,
      pending,
      thresholds,
      origins: ENTRIES.reduce<Record<string, number>>((n, e) => ({ ...n, [e.origin as string]: (n[e.origin as string] ?? 0) + 1 }), {}),
      next: rest.length > limit ? `${page[page.length - 1].confidence ?? -1}:${page[page.length - 1].path}` : null,
      entries: page,
      ...(q.get("library") === "true" ? libraryList(q) : {}),
    })
  }),
  http.post("/api/intake/decide", async ({ request }) => {
    const body = (await request.json()) as {
      decision: string
      target: { ids?: number[]; query?: { band?: string; duplicates?: boolean; skipped?: boolean; origin?: string }; expect?: number }
      book?: number
      candidate?: number
      picks?: unknown
      title?: string
      authors?: string[]
    }
    const { decision, target } = body
    if (target.ids?.length === 1 && uploadBoard.decide(target.ids[0], decision, body.book)) return HttpResponse.json({ jobId: "upload", total: 1 }, { status: 202 })
    const libraryIds = target.query && "library" in target.query ? libraryTakeable(library()).map((e) => e.id) : null
    const bulkTrash = decision === "trash" && target.query !== undefined
    if (bulkTrash) renamed()
    const ids = target.ids ?? libraryIds ?? (bulkTrash ? trashable(inFilter(target.query ?? {})) : takeable(inFilter(target.query ?? {}), target.query?.skipped === true)).map((e) => e.id)
    if (target.expect !== undefined && target.expect !== ids.length) {
      return HttpResponse.json({ error: "the query matches another number", field: "target", expected: target.expect, found: ids.length }, { status: 409 })
    }
    asked.push({ decision, ids, candidate: body.candidate, picks: body.picks, title: body.title, authors: body.authors, query: target.query, expect: target.expect })
    if (ids.some((id) => id < 0)) {
      const books = ids.map((id) => -id)
      if (decision === "skip" || decision === "unskip") books.forEach((b) => (decision === "skip" ? skippedBooks.add(b) : skippedBooks.delete(b)))
      else if (decision === "reject") {
        books.forEach((b) => failedBooks.delete(b))
        proposalBoard.decide(books, "rejected")
      } else {
        const changed = proposalBoard.entries().filter((r) => books.includes(r.bookId) && r.file.includes(CHANGED)).map((r) => r.bookId)
        changed.forEach((b) => failedBooks.set(b, "title changed since the plan"))
        proposalBoard.decide(books.filter((b) => !changed.includes(b)), "applied")
      }
      return HttpResponse.json({ jobId: decision === "accept" ? "repair-apply" : null, total: ids.length }, { status: decision === "accept" ? 202 : 200 })
    }
    if (decision === "skip" || decision === "unskip") {
      for (const e of ENTRIES) if (ids.includes(e.id)) e.skipped = decision === "skip"
      return HttpResponse.json({ total: ids.length })
    }
    const failing = ENTRIES.find((e) => ids.includes(e.id) && e.name === "kaputt.pdf")
    if (failing) waiting = { entry: failing, error: "calibre kann die Datei nicht lesen" }
    ENTRIES = ENTRIES.filter((e) => !ids.includes(e.id))
    return HttpResponse.json({ jobId: "intake-job", total: ids.length }, { status: 202 })
  }),
  http.post("/api/intake/threshold", async ({ request }) => {
    const body = (await request.json()) as { origin: string; value: number | null }
    thresholds[body.origin] = body.value
    return HttpResponse.json({ thresholds })
  }),
  // once: what is left to plan
  http.post("/api/import/repair/recheck", () => {
    const books = rechecked ? 0 : 2
    rechecked = true
    return HttpResponse.json({ books, job: { id: "recheck", status: "running", done: 0, total: books, errors: [] } }, { status: 202 })
  }),
  http.get("/api/intake/:id/file", async ({ params, request }) => {
    const query = new URL(request.url).searchParams
    const format = query.get("format")
    reads.push(`${params.id}/${format}${query.get("first") ? "/first" : ""}`)
    const data = await (await fetch(pdfUrl)).arrayBuffer()
    // a DjVu and the large file of the list come as their first pages
    const excerpt = format === "DJVU" || ENTRIES.find((x) => x.id === Number(params.id))?.cover
    return new HttpResponse(data, {
      headers: { "Content-Type": "application/octet-stream", "Content-Disposition": "attachment", "Content-Length": String(data.byteLength), ...(excerpt && { "X-Hub-Excerpt-Pages": "30" }) },
    })
  }),
  http.get("/api/intake/:id/cover", () => new HttpResponse(COVER, { headers: { "Content-Type": "image/svg+xml" } })),
  http.get("/api/intake/:id", ({ params }) => {
    const e = [...ENTRIES, ...library()].find((x) => x.id === Number(params.id))
    return e ? HttpResponse.json(e) : HttpResponse.json({ error: "not found" }, { status: 404 })
  }),
]
