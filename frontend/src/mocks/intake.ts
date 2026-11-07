import { http, HttpResponse } from "msw"
import type { Book, ConfidenceBand, ImportRepairEntry, IntakeBands, IntakeCandidate, IntakeDetail, IntakeEntry, IntakeOrigin, IntakeShares } from "@/lib/api"
import pdfUrl from "./fixtures/sample.pdf?url"
import { scenario, scenarioSeeds } from "./scenarios"

// The Eingang of the mock hub: a dozen files like a real inbox, then enough
// scans that the list needs a second page. The analysis stands at one file,
// so the numbers read the same in every e2e scenario. Another situation of the
// Eingang (mocks/scenarios.ts) has other files and nothing to analyse.

const ROOT = "/srv/media/ebooks/inbox"

export interface Seed {
  path: string
  title: string
  authors: string[]
  confidence: number
  level: 1 | 2 | 3 | null
  decided?: string
  candidates?: [string, string[], number, string, IntakeCandidate["fields"]?][]
  action?: "add" | "addFormats" | "duplicate"
  addFormats?: string[]
  origin?: IntakeEntry["origin"]
  skipped?: boolean
  bookId?: number
  bookTitle?: string
  sure?: boolean
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
    sure: true,
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
    origin: seed.origin ?? "inbox",
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
    addFormats: seed.addFormats ?? [],
    cover: seed.cover ? `/api/intake/${id}/cover?v=1` : null,
    analysedAt: "2026-11-06T20:00:00Z",
    skipped: seed.skipped ?? false,
    error: null,
    changes: [],
    candidates,
    bookTitle: seed.bookTitle ?? null,
    sure: seed.sure ?? false,
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

let ENTRIES = (scenarioSeeds(scenario) ?? [...SEEDS, ...scans]).map((s, i) => entry(s, i + 1)).sort(ordered)
const IDS = ENTRIES.map((e) => e.id)
const LAST = Math.max(0, ...IDS)

// what the mock hub was asked, for the scenarios (window.__intake)
const asked: { decision: string; ids: number[]; candidate?: number; picks?: unknown; title?: string; authors?: string[]; query?: unknown; expect?: number }[] = []
// the files read in, for the scenarios (window.__intakeReads)
const reads: string[] = []
const thresholds: Record<string, number | null> = { inbox: 90, upload: 90 }
// a job still running: the entry comes back with an error at the next look
let waiting: { entry: IntakeDetail; error: string } | null = null
// Taking the book adds nothing, the library has it: back in the list as a
// duplicate without an error by the time anyone looks; the other one fails
// the same way every time (localStorage hub.mock.intake.returns)
const RETURNS = "Mathematics of the Discrete Fourier Transform"
const FAILS = "Britannica Illustrated Science Library: Birds"
const returning = () => typeof localStorage !== "undefined" && !!localStorage.getItem("hub.mock.intake.returns")
if (typeof window !== "undefined") Object.assign(window, { __intake: asked, __intakeReads: reads })

// A file that came another way, for the scenarios about sources
// (localStorage hub.mock.intake.sources); one from the days of the backlog,
// which a state DB may still have, with no source of today to go by
// (localStorage hub.mock.intake.oldRow)
const UPLOADED = "Functional Analysis 6th ed - K. Yoshida (Springer, 1980) WW.pdf"
const OLD_ROW = "Robbins - Basic Pathology 8e.chm"
function sources() {
  if (typeof localStorage === "undefined") return
  for (const e of ENTRIES) {
    if (e.name === UPLOADED && localStorage.getItem("hub.mock.intake.sources")) e.origin = "upload"
    if (e.name === OLD_ROW && localStorage.getItem("hub.mock.intake.oldRow")) e.origin = "backlog" as IntakeOrigin
  }
}

// Three files skipped, one new, a possible and a sure duplicate: they count only
// there (localStorage hub.mock.intake.skipped), once, it can be taken back
const SKIPPED = ["Birds.pdf", "Stewart Calculus Concepts and Contexts 2nd Edition.pdf", "Stem Cells - From Bench to Bedside.pdf"]
let skippedOnce = false
function skippedSome() {
  if (skippedOnce || typeof localStorage === "undefined" || !localStorage.getItem("hub.mock.intake.skipped")) return
  skippedOnce = true
  for (const e of ENTRIES) if (SKIPPED.includes(e.name)) e.skipped = true
}

// The file like another in the Eingang as one more of a book, for the scenario
// without anything left behind (localStorage hub.mock.intake.sameBooks)
function sameBooks() {
  if (typeof localStorage === "undefined" || !localStorage.getItem("hub.mock.intake.sameBooks")) return
  for (const e of ENTRIES) if (e.sameAs) Object.assign(e, { sameAs: null, bookId: 2, bookTitle: e.proposal?.title, sure: true })
}

// The file like another in the Eingang as one calibre refused, of a book the
// hub didn't find (localStorage hub.mock.intake.refused)
function refused() {
  if (typeof localStorage === "undefined" || !localStorage.getItem("hub.mock.intake.refused")) return
  for (const e of ENTRIES) if (e.sameAs) Object.assign(e, { sameAs: null, match: "calibre", error: "Stem Cells (Ariff Bongso); Stem Cells 2 (Eng Hin Lee)" })
}

// The book of the possible duplicate was renamed since the list was shown: the
// first bulk finds it out (localStorage hub.mock.intake.renamed)
function renamed(): boolean {
  if (typeof localStorage === "undefined" || !localStorage.getItem("hub.mock.intake.renamed")) return false
  localStorage.removeItem("hub.mock.intake.renamed")
  for (const e of ENTRIES) e.sure = false
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

// a proposal that writes nothing has nothing to decide here
const library = () => (scenario === "leer" ? [] : proposalBoard.entries().filter((r) => r.changes.some((c) => c.field !== "candidate")).map(libraryEntry))
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
    left: { duplicates: 0, failed: list.filter((e) => e.status === "failed").length, skipped: list.filter((e) => e.status === "analysed" && e.skipped).length },
    last: Math.max(0, ...all.map((e) => e.bookId ?? 0)),
    pending: 0,
    next: null,
    entries: list,
  }
}

const isSure = (e: IntakeDetail) => e.status === "analysed" && e.action === "duplicate" && e.sure === true && !e.skipped

// the hub's filter on duplicates: sure ones, those for a person, the new ones,
// none of them with what is skipped
const ofKind = (e: IntakeDetail, duplicates: string | boolean | null | undefined) => {
  if (duplicates === null || duplicates === undefined) return true
  if (duplicates === "sure") return isSure(e)
  return !e.skipped && (String(duplicates) === "true" ? e.action !== "add" && !isSure(e) : e.action === "add")
}

const inFilter = (q: { band?: string | null; duplicates?: string | boolean | null; skipped?: string | boolean | null; origin?: string | null }) => {
  const skipped = String(q.skipped) === "true"
  return ENTRIES.filter((e) => ofKind(e, q.duplicates) && (!skipped || e.skipped) && (!q.band || (e.band ?? "none") === q.band) && (!q.origin || e.origin === q.origin))
}

const takeable = (list: IntakeDetail[], skipped: boolean) => list.filter((e) => e.status === "analysed" && e.action !== "duplicate" && (skipped || !e.skipped))

const trashable = (list: IntakeDetail[]) => list.filter(isSure)

const limitOf = (q: URLSearchParams) => Number(q.get("limit") ?? 100)

// the files of the analysis still ahead, as in the header of this file
const WAITING = scenario === "analyse" ? 1292 : 0

const bandsOf = (list: IntakeDetail[]): IntakeBands => {
  const count = (b: string) => list.filter((e) => (e.band ?? "none") === b).length
  return { bulk: count("bulk"), review: count("review"), unsure: count("unsure"), none: count("none") }
}

// the hub's kinds: each entry in one, skipped first
function shares(origin: string | null, waiting: number): IntakeShares {
  const files = ENTRIES.filter((e) => !origin || e.origin === origin)
  const kind = (fits: (e: IntakeDetail) => boolean) => bandsOf(files.filter(fits))
  return {
    kinds: {
      new: kind((e) => !e.skipped && e.action === "add"),
      sure: kind(isSure),
      duplicates: kind((e) => !e.skipped && e.action !== "add" && !isSure(e)),
      skipped: kind((e) => e.skipped),
      library: bandsOf(library()),
    },
    waiting,
    books: proposalBoard.books.length,
  }
}

const COVER = `<svg xmlns="http://www.w3.org/2000/svg" width="300" height="400"><rect width="300" height="400" fill="#475569"/></svg>`

export const intakeHandlers = [
  http.get("/api/intake", ({ request }) => {
    const q = new URL(request.url).searchParams
    sources()
    sameBooks()
    refused()
    skippedSome()
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
      duplicates: q.get("duplicates") === "sure" ? 0 : list.filter((e) => e.status === "analysed" && e.action === "duplicate").length,
      failed: list.filter((e) => e.status !== "analysed").length,
      skipped: skippedFilter ? 0 : list.filter((e) => e.status === "analysed" && e.action !== "duplicate" && e.skipped).length,
    }
    const mode = typeof localStorage === "undefined" ? null : localStorage.getItem("hub.mock.intake")
    const ahead = mode === "idle" ? 0 : WAITING
    return HttpResponse.json({
      enabled: true,
      progress: { state: mode ?? (WAITING ? "analysing" : "idle"), total: ENTRIES.length + ahead, done: ENTRIES.length, analysed, current: "Mader - Biology - Inquiry into Life 9e HQ.pdf" },
      total: list.length,
      counts: { bulk: count("bulk"), review: count("review"), unsure: count("unsure"), none: count("none") },
      takeable: take.length,
      unsure: take.filter((e) => e.band === "unsure").length,
      trashable: trashable(inFilter({ band: q.get("band"), origin: q.get("origin") })).length,
      left,
      skipped: ENTRIES.filter((e) => e.skipped).length,
      last: LAST,
      pending,
      thresholds,
      origins: ENTRIES.reduce<Record<string, number>>((n, e) => ({ ...n, [e.origin as string]: (n[e.origin as string] ?? 0) + 1 }), {}),
      shares: shares(q.get("origin"), ahead),
      next: rest.length > limit ? `${page[page.length - 1].confidence ?? -1}:${page[page.length - 1].path}` : null,
      entries: page,
      ...(q.get("library") === "true" ? libraryList(q) : {}),
    })
  }),
  http.post("/api/intake/decide", async ({ request }) => {
    const body = (await request.json()) as {
      decision: string
      target: { ids?: number[]; query?: { band?: string; duplicates?: boolean | "sure"; skipped?: boolean; origin?: string }; expect?: number }
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
    const back = ENTRIES.filter((e) => returning() && ids.includes(e.id) && [RETURNS, FAILS].includes(e.proposal?.title ?? ""))
    for (const e of back) Object.assign(e, e.proposal?.title === RETURNS ? { action: "duplicate", bookId: 1, match: "title", bookTitle: "Dune" } : { error: "calibre kann die Datei nicht lesen" })
    ENTRIES = ENTRIES.filter((e) => !ids.includes(e.id) || back.includes(e))
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
