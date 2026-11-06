import { http, HttpResponse } from "msw"
import type { ConfidenceBand, IntakeCandidate, IntakeDetail, IntakeEntry } from "@/lib/api"

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
  candidates?: [string, string[], number, string][]
  action?: "add" | "addFormats" | "duplicate"
  bookId?: number
  bookTitle?: string
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
      ["Functional Analysis", ["Kosaku Yosida"], 98, "openlibrary"],
      ["Functional Analysis", ["K. Yoshida"], 80, "name"],
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
  { path: "Mathematics of the Discrete Fourier Transform.pdf", title: "Mathematics of the Discrete Fourier Transform", authors: ["Julius Smith"], confidence: 50, level: 3, decided: "openlibrary" },
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
  const candidates: IntakeCandidate[] = (seed.candidates ?? (failed ? [] : [[seed.title, seed.authors, seed.confidence, seed.level === 3 ? "name" : "file"]])).map(([title, authors, confidence, source]) => ({
    source,
    confidence,
    fields: { title, authors },
    url: null,
  }))
  return {
    id,
    path: `${ROOT}/${seed.path}`,
    name,
    folder: parts.join("/") || null,
    kind: "file",
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

let ENTRIES = [...SEEDS, ...scans].map((s, i) => entry(s, i + 1)).sort((a, b) => a.path.toLowerCase().localeCompare(b.path.toLowerCase()))
const IDS = ENTRIES.map((e) => e.id)
const LAST = Math.max(...IDS)

// what the mock hub was asked, for the scenarios (window.__intake)
const asked: { decision: string; ids: number[]; title?: string; authors?: string[]; query?: unknown; expect?: number }[] = []
let threshold: number | null = null
// a job still running: the entry comes back with an error at the next look
let waiting: { entry: IntakeDetail; error: string } | null = null
if (typeof window !== "undefined") (window as unknown as { __intake: unknown }).__intake = asked

const inFilter = (q: { band?: string | null; duplicates?: string | boolean | null; skipped?: string | boolean | null }) => {
  const dup = q.duplicates === null || q.duplicates === undefined ? null : String(q.duplicates) === "true"
  const skipped = String(q.skipped) === "true"
  return ENTRIES.filter((e) => (dup === null || (e.action !== "add") === dup) && (!skipped || e.skipped) && (!q.band || (e.band ?? "none") === q.band))
}

const takeable = (list: IntakeDetail[], skipped: boolean) => list.filter((e) => e.status === "analysed" && e.action !== "duplicate" && (skipped || !e.skipped))

const limitOf = (q: URLSearchParams) => Number(q.get("limit") ?? 100)

const COVER = `<svg xmlns="http://www.w3.org/2000/svg" width="300" height="400"><rect width="300" height="400" fill="#475569"/></svg>`

export const intakeHandlers = [
  http.get("/api/intake", ({ request }) => {
    const q = new URL(request.url).searchParams
    const filter = { duplicates: q.get("duplicates"), skipped: q.get("skipped") }
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
    const from = after ? list.findIndex((e) => e.path.toLowerCase().localeCompare(after.toLowerCase()) > 0) : 0
    const rest = from < 0 ? [] : list.slice(from)
    const limit = limitOf(q)
    const page = rest.slice(0, limit)
    const analysed = ENTRIES.filter((e) => e.status === "analysed").length
    const count = (b: string) => kind.filter((e) => (e.band ?? "none") === b).length
    const take = takeable(list, q.get("skipped") === "true")
    const mode = typeof localStorage === "undefined" ? null : localStorage.getItem("hub.mock.intake")
    return HttpResponse.json({
      enabled: true,
      progress: { state: mode ?? "analysing", total: 1451 - (159 - ENTRIES.length), done: ENTRIES.length, analysed, current: "Mader - Biology - Inquiry into Life 9e HQ.pdf" },
      total: list.length,
      counts: { bulk: count("bulk"), review: count("review"), unsure: count("unsure"), none: count("none") },
      takeable: take.length,
      unsure: take.filter((e) => e.band === "unsure").length,
      skipped: ENTRIES.filter((e) => e.skipped).length,
      last: LAST,
      pending,
      threshold,
      next: rest.length > limit ? page[page.length - 1].path : null,
      entries: page,
    })
  }),
  http.post("/api/intake/decide", async ({ request }) => {
    const body = (await request.json()) as {
      decision: string
      target: { ids?: number[]; query?: { band?: string; duplicates?: boolean; skipped?: boolean }; expect?: number }
      title?: string
      authors?: string[]
    }
    const { decision, target } = body
    const ids = target.ids ?? takeable(inFilter(target.query ?? {}), target.query?.skipped === true).map((e) => e.id)
    if (target.expect !== undefined && target.expect !== ids.length) {
      return HttpResponse.json({ error: "the query matches another number", field: "target", expected: target.expect, found: ids.length }, { status: 409 })
    }
    asked.push({ decision, ids, title: body.title, authors: body.authors, query: target.query, expect: target.expect })
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
    threshold = ((await request.json()) as { value: number | null }).value
    return HttpResponse.json({ threshold })
  }),
  http.get("/api/intake/:id/cover", () => new HttpResponse(COVER, { headers: { "Content-Type": "image/svg+xml" } })),
  http.get("/api/intake/:id", ({ params }) => {
    const e = ENTRIES.find((x) => x.id === Number(params.id))
    return e ? HttpResponse.json(e) : HttpResponse.json({ error: "not found" }, { status: 404 })
  }),
]
