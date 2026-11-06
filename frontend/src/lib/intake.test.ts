import { describe, expect, it } from "vitest"
import type { IntakeDetail, IntakeEntry } from "./api"
import { analysedShare, authorsText, badgeText, candidateSource, intakeFilter, noteTexts, reasonText, ringLabel, takeable, uniqueEntries } from "./intake"

const entry = (extra: Partial<IntakeDetail>): IntakeDetail => ({
  id: 1,
  path: "/b/a.pdf",
  name: "a.pdf",
  folder: null,
  kind: "file",
  files: [],
  status: "analysed",
  detail: null,
  proposal: null,
  confidence: 98,
  band: "bulk",
  titleConfidence: 98,
  authorsConfidence: 98,
  level: 1,
  source: "dnb",
  decided: "dnb",
  isbnSource: "text",
  notes: [],
  action: "add",
  bookId: null,
  match: null,
  sameAs: null,
  addFormats: [],
  cover: null,
  analysedAt: "2026-11-06T20:00:00Z",
  skipped: false,
  error: null,
  changes: [],
  candidates: [],
  bookTitle: null,
  ...extra,
})

describe("ringLabel", () => {
  it("reads out what the badge says", () => {
    expect(ringLabel(entry({}))).toBe("98 %, Sicher")
    expect(ringLabel(entry({ confidence: 70, band: "review", action: "duplicate" }))).toBe("70 %, Dublette?")
    expect(ringLabel(entry({ confidence: null, band: null }))).toBe("Fehlgeschlagen")
  })
})

describe("takeable", () => {
  it("leaves failed files, possible duplicates and skipped entries to Arthur", () => {
    expect(takeable(entry({}), "all")).toBe(true)
    expect(takeable(entry({ action: "addFormats" }), "all")).toBe(true)
    expect(takeable(entry({ action: "duplicate" }), "all")).toBe(false)
    expect(takeable(entry({ status: "failed" }), "all")).toBe(false)
    expect(takeable(entry({ skipped: true }), "all")).toBe(false)
    expect(takeable(entry({ skipped: true }), "skipped")).toBe(true)
  })
})

describe("intakeFilter", () => {
  it("is what the list and a bulk decision ask for", () => {
    expect(intakeFilter("all", "all")).toEqual({ band: undefined, duplicates: undefined, skipped: undefined })
    expect(intakeFilter("bulk", "new")).toEqual({ band: "bulk", duplicates: false, skipped: undefined })
    expect(intakeFilter("unsure", "duplicates")).toEqual({ band: "unsure", duplicates: true, skipped: undefined })
    expect(intakeFilter("all", "skipped")).toEqual({ band: undefined, duplicates: undefined, skipped: true })
  })
})

describe("badgeText", () => {
  it("names the band with its percent", () => {
    expect(badgeText(entry({}))).toBe("98 % · Sicher")
    expect(badgeText(entry({ confidence: 70, band: "review" }))).toBe("70 % · Prüfen")
  })

  it("marks a possible duplicate in the list, not in the drawer", () => {
    const e = entry({ confidence: 78, band: "review", action: "duplicate" })
    expect(badgeText(e)).toBe("78 % · Dublette?")
    expect(badgeText(e, false)).toBe("78 % · Prüfen")
  })

  it("has no percent for a file that failed", () => {
    expect(badgeText(entry({ status: "failed", confidence: null, band: null }))).toBe("Fehlgeschlagen")
  })
})

describe("reasonText", () => {
  it("says who decided", () => {
    expect(reasonText(entry({}))).toBe("ISBN im Buch, Katalog passt")
    expect(reasonText(entry({ band: "unsure", confidence: 50 }))).toBe("ISBN im Buch, aber Buch und Katalog passen nicht zusammen")
    expect(reasonText(entry({ level: 2, decided: "file" }))).toBe("Metadaten der Datei")
    expect(reasonText(entry({ level: 2, decided: "file", kind: "calibre" }))).toBe("metadata.opf des Calibre-Ordners")
    expect(reasonText(entry({ level: 3, decided: "name" }))).toBe("nur Dateiname")
    expect(reasonText(entry({ level: 3, decided: "openlibrary" }))).toBe("Dateiname, Katalog bestätigt")
    expect(reasonText(entry({ level: 3, decided: "unsure" }))).toBe("nichts sicher erkannt")
    expect(reasonText(entry({ level: null, decided: null }))).toBe("Norm, nach den Regeln")
  })

  it("shows why a file failed", () => {
    expect(reasonText(entry({ status: "failed", detail: "kaputt" }))).toBe("kaputt")
  })
})

describe("noteTexts", () => {
  it("names the book a duplicate looks like", () => {
    expect(noteTexts(entry({ action: "duplicate", bookId: 7, bookTitle: "Dune" }))).toEqual(["Mögliche Dublette von „Dune“ in der Bibliothek."])
    expect(noteTexts(entry({ action: "addFormats", bookId: 7, bookTitle: "Dune", addFormats: ["EPUB"] }))).toEqual(["Schon in der Bibliothek als „Dune“, dort fehlt EPUB."])
  })

  it("names the other file of the list", () => {
    expect(noteTexts(entry({ action: "duplicate", sameAs: "/b/x/dune.pdf" }))).toEqual(["Mögliche Dublette von „dune.pdf“ im Eingang."])
  })

  it("has the flow's notes", () => {
    expect(noteTexts(entry({ notes: [{ kind: "isbnConflict", isbn: "123", books: [] }] }))).toEqual(["Im Buch steht die ISBN 123, das Buch hat eine andere"])
  })
})

it("takes the share of what is analysed", () => {
  const p = { state: "analysing" as const, total: 1451, done: 312, analysed: 310, current: null }
  expect(analysedShare(p)).toBe(21)
  expect(analysedShare({ ...p, total: 0, analysed: 0 })).toBe(0)
})

it("shows Unknown in German", () => {
  expect(authorsText(["Unknown"])).toBe("Unbekannt")
  expect(authorsText(["A", "B"])).toBe("A, B")
  expect(authorsText(null)).toBe("Unbekannt")
})

it("names the sources of the file itself", () => {
  expect(candidateSource("name")).toBe("Dateiname")
  expect(candidateSource("openlibrary")).toBe("Open Library")
  expect(candidateSource("neu")).toBe("neu")
})

it("keeps an entry once over a moved page boundary", () => {
  const a = entry({ id: 1 }) as IntakeEntry
  const b = entry({ id: 2 }) as IntakeEntry
  expect(uniqueEntries([{ entries: [a, b] }, { entries: [b] }]).map((e) => e.id)).toEqual([1, 2])
})
