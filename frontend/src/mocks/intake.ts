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

const ENTRIES = [...SEEDS, ...scans].map((s, i) => entry(s, i + 1)).sort((a, b) => a.path.toLowerCase().localeCompare(b.path.toLowerCase()))

const COVER = `<svg xmlns="http://www.w3.org/2000/svg" width="300" height="400"><rect width="300" height="400" fill="#475569"/></svg>`

export const intakeHandlers = [
  http.get("/api/intake", ({ request }) => {
    const q = new URL(request.url).searchParams
    const duplicates = q.get("duplicates")
    const kind = ENTRIES.filter((e) => duplicates === null || (e.action !== "add") === (duplicates === "true"))
    const wanted = q.get("band")
    const list = wanted ? kind.filter((e) => (e.band ?? "none") === wanted) : kind
    const offset = Number(q.get("offset") ?? 0)
    const limit = Number(q.get("limit") ?? 100)
    const analysed = ENTRIES.filter((e) => e.status === "analysed").length
    const count = (b: string) => kind.filter((e) => (e.band ?? "none") === b).length
    return HttpResponse.json({
      enabled: true,
      progress: { state: "analysing", total: 1451, done: ENTRIES.length, analysed, current: "Mader - Biology - Inquiry into Life 9e HQ.pdf" },
      total: list.length,
      counts: { bulk: count("bulk"), review: count("review"), unsure: count("unsure"), none: count("none") },
      entries: list.slice(offset, offset + limit),
    })
  }),
  http.get("/api/intake/:id/cover", () => new HttpResponse(COVER, { headers: { "Content-Type": "image/svg+xml" } })),
  http.get("/api/intake/:id", ({ params }) => {
    const e = ENTRIES.find((x) => x.id === Number(params.id))
    return e ? HttpResponse.json(e) : HttpResponse.json({ error: "not found" }, { status: 404 })
  }),
]
