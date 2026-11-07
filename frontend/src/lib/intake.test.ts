import { describe, expect, it } from "vitest"
import type { IntakeDetail, IntakeEntry } from "./api"
import { acceptable, analysedShare, asChosen, authorsText, autoText, badgeText, candidateDiff, candidateSource, entryName, errorText, intakeFilter, leftText, noteTexts, originsInList, readableFormat, reasonText, ringLabel, takeable, trashable, trashAllText, uniqueEntries, unreadable } from "./intake"

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

describe("trashable", () => {
  it("is what the hub marked as the same book, nothing else of the filter", () => {
    expect(trashable(entry({ action: "duplicate", sameBook: true }))).toBe(true)
    expect(trashable(entry({ action: "duplicate" }))).toBe(false)
    expect(trashable(entry({ action: "addFormats", sameBook: true }))).toBe(false)
    expect(trashable(entry({ action: "duplicate", sameBook: true, status: "failed" }))).toBe(false)
    expect(trashable(entry({ action: "duplicate", sameBook: true, skipped: true }))).toBe(false)
  })
})

describe("trashAllText", () => {
  it("names the number and what stays, only if anything does", () => {
    expect(trashAllText(640, 0)).toBe("640 Dateien mit gleichem Autor und Titel wie ein Buch der Bibliothek gehen in den Papierkorb.")
    expect(trashAllText(1, 0)).toBe("1 Datei mit gleichem Autor und Titel wie ein Buch der Bibliothek geht in den Papierkorb.")
    expect(trashAllText(2, 1)).toBe("2 Dateien mit gleichem Autor und Titel wie ein Buch der Bibliothek gehen in den Papierkorb. 1 weiterer Eintrag bleibt in der Liste.")
    expect(trashAllText(2, 3)).toBe("2 Dateien mit gleichem Autor und Titel wie ein Buch der Bibliothek gehen in den Papierkorb. 3 weitere Einträge bleiben in der Liste.")
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

describe("leftText", () => {
  const left = { duplicates: 0, failed: 0, skipped: 0, unchanged: 0 }
  it("says nothing when the bulk takes everything", () => {
    expect(leftText(left)).toBeNull()
    expect(leftText(undefined)).toBeNull()
  })
  it("names what stays", () => {
    expect(leftText({ ...left, duplicates: 59 })).toBe("59 mögliche Dubletten bleiben in der Liste")
    expect(leftText({ ...left, duplicates: 1 })).toBe("1 mögliche Dublette bleibt in der Liste")
    expect(leftText({ duplicates: 2, failed: 1, skipped: 3, unchanged: 0 })).toBe("2 mögliche Dubletten, 1 fehlgeschlagen und 3 übersprungen bleiben in der Liste")
  })
})

describe("candidateDiff", () => {
  const proposal = { title: "A", authors: ["B"], publisher: "P", pubdate: "1999-01-01", series: null, seriesIndex: null, isbn: "978-3-16-148410-0", languages: [] }
  const candidate = (fields: object) => ({ source: "dnb", confidence: 50, fields, url: null })
  it("is empty for the same book", () => {
    expect(candidateDiff(candidate({ title: "A", authors: ["B"], publisher: "P", pubdate: "1999", isbn: "9783161484100" }), proposal)).toEqual([])
  })
  it("names what would change and what would be missing", () => {
    expect(candidateDiff(candidate({ title: "C", authors: ["D"], pubdate: "2000" }), proposal)).toEqual(["Titel C", "Autoren D", "ohne Verlag", "Erscheinungsdatum 2000", "ohne ISBN"])
  })
  it("keeps the proposal's authors where the candidate has none", () => {
    expect(candidateDiff(candidate({ title: "A", publisher: "P", pubdate: "1999", isbn: "9783161484100" }), proposal)).toEqual([])
  })
})

describe("a library entry", () => {
  const library = entry({ kind: "library", action: "update", name: "", bookId: 7, bookTitle: "Alt", confidence: 80, band: "review", proposal: { title: "Neu", authors: ["X"], publisher: null, pubdate: null, series: null, seriesIndex: null, isbn: null, languages: [] } })
  it("is called by the book where there is no file", () => {
    expect(entryName(library)).toBe("Alt")
    expect(entryName({ ...library, name: "a.pdf" })).toBe("a.pdf")
  })
  it("is tagged as such and reads no note of a duplicate", () => {
    expect(badgeText(library)).toBe("80 % · Bibliothek")
    expect(badgeText({ ...library, confidence: null, band: null })).toBe("Bibliothek")
    expect(noteTexts(library)).toEqual([])
  })
  it("can't be accepted failed or with nothing to write", () => {
    expect(acceptable(library)).toBe(true)
    expect(acceptable({ ...library, status: "failed" })).toBe(false)
    expect(acceptable({ ...library, unchanged: true })).toBe(false)
    expect(takeable({ ...library, unchanged: true }, "library")).toBe(false)
  })
  it("says in German which field changed", () => {
    expect(errorText({ ...library, error: "title changed since the plan" })).toBe("Titel wurde seit dem Vorschlag geändert. Bitte ablehnen oder Bestand neu prüfen.")
    expect(errorText({ ...library, error: "calibre down" })).toBe("calibre down")
  })
  it("is its own filter", () => {
    expect(intakeFilter("all", "library")).toEqual({ band: undefined, duplicates: undefined, skipped: undefined, library: true })
  })
})

describe("reading in", () => {
  const files = (...formats: string[]) => entry({ files: formats.map((format) => ({ path: "", format, size: 1 })) })
  it("takes the reader's first format", () => {
    expect(readableFormat(files("PDF", "EPUB"))).toBe("EPUB")
    expect(readableFormat(files("CHM"))).toBeNull()
  })
  it("reads a DjVu when there is nothing better, not a library's", () => {
    expect(readableFormat(files("DJVU"))).toBe("DJVU")
    expect(readableFormat(files("CHM", "DJV"))).toBe("DJV")
    expect(readableFormat(files("DJVU", "PDF"))).toBe("PDF")
    expect(readableFormat({ ...files("DJVU"), kind: "library" })).toBeNull()
  })
  it("has a line only for CHM", () => {
    expect(unreadable(files("CHM"))).toBe(true)
    expect(unreadable(files("DJVU"))).toBe(false)
    expect(unreadable(files("CHM", "DJVU"))).toBe(false)
    expect(unreadable(files("RTF"))).toBe(false)
  })
})

describe("asChosen", () => {
  it("is as sure as the candidate", () => {
    const c = { source: "name", confidence: 40, fields: {}, url: null }
    expect(badgeText(asChosen(entry({}), c), false)).toBe("40 % · Unsicher")
    expect(asChosen(entry({}))).toEqual(entry({}))
  })
})

describe("the sources", () => {
  it("names only the sources with entries", () => {
    expect(originsInList({ origins: { backlog: 3, inbox: 0, upload: 1 } })).toEqual(["backlog", "upload"])
    expect(originsInList({})).toEqual([])
    expect(originsInList(undefined)).toEqual([])
  })

  it("says per source what goes by itself, only for the sources there are", () => {
    expect(autoText({ backlog: null, inbox: 90, upload: 75 })).toBe("Automatisch übernehmen: Backlog aus, Inbox ab 90 %, Upload ab 75 %")
    expect(autoText({ upload: 90 })).toBe("Automatisch übernehmen: Upload ab 90 %")
  })

  it("leaves the source out of a filter of the library's books", () => {
    expect(intakeFilter("all", "all", "inbox").origin).toBe("inbox")
    expect(intakeFilter("all", "all", "all").origin).toBeUndefined()
    expect(intakeFilter("all", "library", "inbox").origin).toBeUndefined()
  })
})
