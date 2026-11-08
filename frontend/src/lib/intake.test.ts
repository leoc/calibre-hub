import { describe, expect, it } from "vitest"
import type { IntakeDetail, IntakeEntry } from "./api"
import { acceptable, analysedShare, asChosen, authorsText, autoText, badgeText, bandCount, bulkOf, candidateDiff, candidateSource, entryName, errorText, headlineText, hubTook, inBar, inKind, inLegend, intakeFilter, isPicked, kindCount, knownOrigin, leaving, noteTexts, openCount, originsInList, partTitle, shareParts, readableFormat, reasonText, ringLabel, takeable, trashable, trashAllText, uniqueEntries, unreadable, filesText, folderName, unwritableFolders, unwritableText } from "./intake"

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

describe("knownOrigin", () => {
  it("names the sources there are, a row older than them stays without a word", () => {
    expect(knownOrigin("inbox")).toBe("inbox")
    expect(knownOrigin("backlog")).toBeUndefined()
    expect(knownOrigin(undefined)).toBeUndefined()
  })
})

describe("an entry on its way out", () => {
  it("is out of the list until a list younger than the hub's answer has it", () => {
    expect(leaving(undefined, 100)).toBe(false)
    expect(leaving("sent", 100)).toBe(true)
    expect(leaving(200, 100)).toBe(true)
    expect(leaving(200, 300)).toBe(false)
  })

  it("is out of the list again when decided again", () => {
    const back = hubTook(new Map([[1, "sent"], [2, "sent"]]), [1], 500)
    expect([...back]).toEqual([[1, 500], [2, "sent"]])
    expect(leaving(back.get(1), 600)).toBe(false)
    expect(leaving(hubTook(back, [1], 700).get(1), 600)).toBe(true)
  })
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
    expect(takeable(entry({}))).toBe(true)
    expect(takeable(entry({ action: "addFormats" }))).toBe(true)
    expect(takeable(entry({ action: "duplicate" }))).toBe(false)
    expect(takeable(entry({ status: "failed" }))).toBe(false)
    expect(takeable(entry({ skipped: true }))).toBe(false)
  })
})

describe("trashable", () => {
  it("is what the hub marked as sure, nothing else of the filter", () => {
    expect(trashable(entry({ action: "duplicate", sure: true }))).toBe(true)
    expect(trashable(entry({ action: "duplicate" }))).toBe(false)
    expect(trashable(entry({ action: "addFormats", sure: true }))).toBe(false)
    expect(trashable(entry({ action: "duplicate", sure: true, status: "failed" }))).toBe(false)
    expect(trashable(entry({ action: "duplicate", sure: true, skipped: true }))).toBe(false)
  })
})

describe("trashAllText", () => {
  it("names the number and what stays, only if anything does", () => {
    expect(trashAllText(640)).toBe("640 sichere Dubletten gehen in den Papierkorb. Die Bibliothek hat Buch oder Datei schon, oder eine Kopie bleibt im Eingang.")
    expect(trashAllText(1)).toBe("1 sichere Dublette geht in den Papierkorb. Die Bibliothek hat Buch oder Datei schon, oder eine Kopie bleibt im Eingang.")
  })
})

describe("intakeFilter", () => {
  it("is what the list and a bulk decision ask for", () => {
    expect(intakeFilter("all", "all")).toEqual({ band: undefined, duplicates: undefined, skipped: undefined })
    expect(intakeFilter("bulk", "new")).toEqual({ band: "bulk", duplicates: false, skipped: undefined })
    expect(intakeFilter("unsure", "duplicates")).toEqual({ band: "unsure", duplicates: true, skipped: undefined })
    expect(intakeFilter("bulk", "sure", "inbox")).toEqual({ band: "bulk", duplicates: "sure", skipped: undefined, origin: "inbox" })
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

describe("the shares", () => {
  const bands = (bulk: number, review: number, unsure: number, none = 0) => ({ bulk, review, unsure, none })
  const shares = { kinds: { new: bands(0, 122, 241, 1), sure: bands(2, 1, 0), duplicates: bands(34, 89, 20), skipped: bands(0, 5, 0), library: bands(1, 1, 0) }, waiting: 12, books: 3179 }
  const ids = (list: { id: string }[]) => list.map((p) => p.id)

  it("adds the files of every kind up for Alle, not the library's books", () => {
    expect(kindCount(shares, "all")).toBe(515)
    expect(kindCount(shares, "library")).toBe(2)
    expect(kindCount(shares, "skipped")).toBe(5)
  })

  it("says per kind what its bands hold, Alle over all files", () => {
    expect(bandCount(shares, "new", "review")).toBe(122)
    expect(bandCount(shares, "all", "review")).toBe(217)
    expect(bandCount(shares, "duplicates", "all")).toBe(143)
    expect(bandCount(shares, "all", "none")).toBe(1)
  })

  it("adds the parts up to what is open", () => {
    const open = openCount({ progress: { state: "analysing", total: 527, done: 515, analysed: 514, current: null }, shares })
    expect(open).toBe(529)
    expect(shareParts(shares, "all").reduce((n, p) => n + p.count, 0)).toBe(open)
  })

  it("keeps the order of the design, a part at 0 only in the legend", () => {
    const parts = shareParts(shares, "all")
    expect(ids(parts)).toEqual(["bulk", "review", "unsure", "none", "sure", "duplicates", "skipped", "library", "waiting"])
    expect(ids(inBar(parts))).not.toContain("bulk")
    expect(ids(inLegend(parts))).toContain("bulk")
  })

  it("has failed files, the library and what waits in the legend only above 0", () => {
    const none = { kinds: { ...shares.kinds, new: bands(0, 0, 0), library: bands(0, 0, 0) }, waiting: 0, books: 1 }
    expect(ids(inLegend(shareParts(none, "all")))).toEqual(["bulk", "review", "unsure", "sure", "duplicates", "skipped"])
  })

  it("leaves what has no source out of a source's parts", () => {
    const parts = shareParts(shares, "inbox")
    expect(ids(inBar(parts))).toEqual(["review", "unsure", "none", "sure", "duplicates", "skipped"])
    expect(ids(inLegend(parts))).not.toContain("library")
  })

  it("marks the part of the filter", () => {
    const [bulk, , , , sure] = shareParts(shares, "all")
    expect(isPicked(bulk, "new", "bulk")).toBe(true)
    expect(isPicked(bulk, "new", "all")).toBe(false)
    expect(isPicked(sure, "sure", "all")).toBe(true)
    expect(isPicked(sure, "sure", "bulk")).toBe(false)
  })

  it("names a part with its number", () => {
    expect(partTitle({ id: "skipped", kind: "skipped", band: "all", count: 1234 })).toBe("Übersprungen: 1.234")
  })

  it("has a bulk only for what is sure of the new files and for the sure duplicates, never at 0", () => {
    expect(bulkOf(shares, "sure", "all")).toEqual({ decision: "trash", count: 3 })
    expect(bulkOf(shares, "sure", "review")).toEqual({ decision: "trash", count: 1 })
    expect(bulkOf(shares, "sure", "unsure")).toBeNull()
    expect(bulkOf(shares, "new", "bulk")).toBeNull()
    const sure = { ...shares, kinds: { ...shares.kinds, new: bands(7, 0, 0) } }
    expect(bulkOf(sure, "new", "bulk")).toEqual({ decision: "accept", count: 7 })
    for (const [kind, band] of [["new", "all"], ["new", "review"], ["all", "bulk"], ["duplicates", "bulk"], ["skipped", "bulk"], ["library", "bulk"]] as const) expect(bulkOf(sure, kind, band)).toBeNull()
  })

  it("says what waits, else that all is analysed", () => {
    expect(headlineText(412, 1200)).toBe("412 von 1.200 noch zu analysieren")
    expect(headlineText(0, 368)).toBe("368 Dateien warten auf dich, alle analysiert")
    expect(headlineText(0, 1)).toBe("1 Datei wartet auf dich, alle analysiert")
    expect(headlineText(0, 0)).toBe("Nichts wartet auf dich, alle analysiert")
  })

  it("moves a skipped entry out of the filters on kinds", () => {
    expect(inKind(entry({ skipped: true }), "new")).toBe(false)
    expect(inKind(entry({ skipped: true }), "sure")).toBe(false)
    expect(inKind(entry({ skipped: true }), "duplicates")).toBe(false)
    expect(inKind(entry({ skipped: true }), "all")).toBe(true)
    expect(inKind(entry({ skipped: true }), "skipped")).toBe(true)
    expect(inKind(entry({ skipped: false }), "skipped")).toBe(false)
    expect(inKind(entry({ skipped: true }), "library")).toBe(true)
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
  })
  it("says in German which field changed", () => {
    expect(errorText({ ...library, error: "title changed since the plan" })).toBe("Titel wurde seit dem Vorschlag geändert. Bitte ablehnen oder Bestand neu prüfen.")
    expect(errorText({ ...library, error: "calibre down" })).toBe("calibre down")
  })
  it("says what calibre refused an entry for, when the hub found no such book", () => {
    const refused = { ...library, kind: "file" as const, action: "duplicate" as const, match: "calibre", bookId: null, error: "Dune (Frank Herbert)" }
    expect(errorText(refused)).toBe("calibre lehnt das als Dublette ab, es gibt schon „Dune (Frank Herbert)“.")
    expect(errorText({ ...refused, error: "Dune (Frank Herbert); Dune (F. Herbert)" })).toBe("calibre lehnt das als Dublette ab, es gibt schon „Dune (Frank Herbert)“, „Dune (F. Herbert)“.")
    expect(errorText({ ...refused, bookId: 7, error: "a.pdf too large for another format" })).toBe("a.pdf too large for another format")
    expect(noteTexts({ ...refused, notes: [], changes: [], candidates: [] })).toEqual([])
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
    expect(originsInList({ origins: { inbox: 3, upload: 0 } })).toEqual(["inbox"])
    expect(originsInList({ origins: { inbox: 3, upload: 1 } })).toEqual(["inbox", "upload"])
    expect(originsInList({})).toEqual([])
    expect(originsInList(undefined)).toEqual([])
  })

  it("says per source what goes by itself, only for the sources there are", () => {
    expect(autoText({ inbox: null, upload: 75 })).toBe("Automatisch übernehmen: Inbox aus, Upload ab 75 %")
    expect(autoText({ upload: 90 })).toBe("Automatisch übernehmen: Upload ab 90 %")
  })

  it("leaves the source out of a filter of the library's books", () => {
    expect(intakeFilter("all", "all", "inbox").origin).toBe("inbox")
    expect(intakeFilter("all", "all", "all").origin).toBeUndefined()
    expect(intakeFilter("all", "library", "inbox").origin).toBeUndefined()
  })
})

describe("the folders the hub may not move files out of", () => {
  const folders = Array.from({ length: 13 }, (_, i) => ({ path: `Ordner ${i}`, files: 20 - i }))

  it("shows the first ten and says how many more", () => {
    const shown = unwritableFolders({ files: 2829, folders })
    expect(shown.folders.map((f) => f.path)).toEqual(folders.slice(0, 10).map((f) => f.path))
    expect(shown.more).toBe(3)
    expect(unwritableFolders({ files: 1, folders: folders.slice(0, 1) }).more).toBe(0)
  })

  it("counts in German", () => {
    expect(unwritableText(2829)).toBe("2.829 Dateien nicht beschreibbar für den Hub")
    expect(unwritableText(1)).toBe("1 Datei nicht beschreibbar für den Hub")
    expect(filesText(306)).toBe("306 Dateien")
    expect(filesText(1)).toBe("1 Datei")
  })

  it("names the inbox itself", () => {
    expect(folderName("Networks")).toBe("Networks")
    expect(folderName("")).toBe("Eingangsordner selbst")
  })
})
