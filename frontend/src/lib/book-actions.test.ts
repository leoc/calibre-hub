import { describe, expect, it } from "vitest"
import type { Book, Categories, ReadingList } from "./api"
import { bookAction, bookTarget, commandLabel, needsConfirm, offeredActions, parseDirect, valueChoices, type ActionTarget } from "./book-actions"

const book = (patch: Partial<Book> = {}): Book => ({
  id: 7,
  title: "Der Hobbit",
  authors: ["J. R. R. Tolkien"],
  authorSort: null,
  tags: ["fantasy", "klassiker"],
  series: null,
  seriesIndex: null,
  formats: ["EPUB"],
  lastModified: "2026-01-01T00:00:00Z",
  added: null,
  pubdate: null,
  rating: null,
  publisher: null,
  identifiers: {},
  languages: ["deu"],
  custom: {},
  lists: [2],
  ...patch,
})

const three: ActionTarget = { bulk: { ids: [3, 1, 2] }, count: 3, ordered: true }
const all: ActionTarget = { bulk: { query: { tag: ["x"] } }, count: 120, ordered: false }

const cats: Categories = {
  kategorie: [{ name: "Sachbuch", path: "Sachbuch", count: 5, children: [{ name: "Geschichte", path: "Sachbuch.Geschichte", count: 3, children: [] }] }],
  tags: [
    { name: "Sheet Music", count: 4 },
    { name: "sheet", count: 1 },
    { name: "Krimi", count: 9 },
  ],
  authors: [],
  series: [{ name: "Dune", count: 6 }],
  languages: [{ name: "deu", count: 10 }],
}

const list = (id: number, name: string, extra: Partial<ReadingList> = {}) => ({ id, name, editable: true, count: 1, ...extra }) as ReadingList
const lists = [list(1, "Sheet Music"), list(2, "Urlaub/2026"), list(3, "Krimis", { rule: { match: "all", conditions: [] } })]

describe("command labels", () => {
  it("name the target: a count or the title", () => {
    expect(commandLabel(bookAction("addTags"), three)).toBe("Tag hinzufügen (3)")
    expect(commandLabel(bookAction("addTags"), bookTarget(book()))).toBe("Tag hinzufügen: Der Hobbit")
    expect(commandLabel(bookAction("addTags"), three, { value: "Sheet Music", label: "Sheet Music" })).toBe("Tag ‚Sheet Music‘ hinzufügen (3)")
    expect(commandLabel(bookAction("addToList"), three, { value: "Sommer", label: "Sommer", isNew: true })).toBe("Neu: Zu Liste ‚Sommer‘ (3)")
    expect(commandLabel(bookAction("kategorie"), three, { value: "", label: "", clear: true })).toBe("Kategorie entfernen (3)")
  })
})

describe("direct input", () => {
  it("takes the longest keyword and keeps the value as typed", () => {
    expect(parseDirect("tag Sheet Music").map((h) => [h.def.id, h.rest])).toEqual([["addTags", "Sheet Music"]])
    expect(parseDirect("tag entfernen krimi").map((h) => [h.def.id, h.rest])).toEqual([["removeTags", "krimi"]])
    expect(parseDirect("Zu Liste: Urlaub").map((h) => [h.def.id, h.rest])).toEqual([["addToList", "Urlaub"]])
    expect(parseDirect("neue liste Sommer 2027").map((h) => [h.def.id, h.rest])).toEqual([["newList", "Sommer 2027"]])
  })

  it("needs a value after the keyword", () => {
    expect(parseDirect("tag")).toEqual([])
    expect(parseDirect("tagebuch")).toEqual([])
    // still typing the command "Tag hinzufügen"
    expect(parseDirect("tag hinzu")).toEqual([])
    expect(parseDirect("Tag hinzufügen")).toEqual([])
  })
})

describe("values", () => {
  it("offers existing values first, then the typed one", () => {
    const v = valueChoices(bookAction("addTags"), { cats }, "sheet music")
    expect(v.map((x) => [x.label, !!x.isNew])).toEqual([["Sheet Music", false]])
    const n = valueChoices(bookAction("addTags"), { cats }, "sheet")
    expect(n.map((x) => x.label)).toEqual(["Sheet Music", "sheet"])
    expect(valueChoices(bookAction("addTags"), { cats }, "noten").map((x) => [x.label, x.isNew])).toEqual([["noten", true]])
  })

  it("removes only what can be removed", () => {
    expect(valueChoices(bookAction("removeTags"), { cats, book: book() }, "").map((x) => x.label)).toEqual(["fantasy", "klassiker"])
    // nothing new to take away
    expect(valueChoices(bookAction("removeTags"), { cats }, "noten")).toEqual([])
  })

  it("never offers a magic shelf as a list, and a book's own lists to leave", () => {
    expect(valueChoices(bookAction("addToList"), { lists }, "").map((x) => x.label)).toEqual(["Sheet Music", "Urlaub/2026"])
    expect(valueChoices(bookAction("removeFromList"), { lists, book: book() }, "").map((x) => x.label)).toEqual(["Urlaub/2026"])
  })

  it("shows categories as a tree, stores them dotted", () => {
    const v = valueChoices(bookAction("kategorie"), { cats }, "")
    expect(v.map((x) => [x.label, x.value, x.depth ?? null, !!x.clear])).toEqual([
      ["Sachbuch", "Sachbuch", 0, false],
      ["Sachbuch/Geschichte", "Sachbuch.Geschichte", 1, false],
      ["Kategorie entfernen", "", null, true],
    ])
    expect(valueChoices(bookAction("kategorie"), { cats }, "Roman/Krimi").at(-1)).toMatchObject({ value: "Roman.Krimi", isNew: true })
  })

  it("takes a year, a rating and a language", () => {
    expect(valueChoices(bookAction("year"), {}, "1987")).toEqual([{ value: "1987", label: "1987", isNew: true }])
    expect(valueChoices(bookAction("year"), {}, "neunzehn")).toEqual([])
    expect(valueChoices(bookAction("rating"), {}, "4").map((x) => x.value)).toEqual(["8"])
    expect(valueChoices(bookAction("language"), { cats }, "deutsch").map((x) => x.value)).toEqual(["deu"])
  })
})

describe("changes", () => {
  it("numbers a series only for books selected one by one", () => {
    expect(offeredActions(three, {}).some((a) => a.id === "seriesNumbered")).toBe(true)
    expect(offeredActions(all, {}).some((a) => a.id === "seriesNumbered")).toBe(false)
    expect(bookAction("seriesNumbered").changes!("Dune", three)).toEqual({ series: "Dune", numberSeries: true })
    expect(bookAction("authors").changes!("Terry Pratchett & Neil Gaiman", three)).toEqual({ authors: ["Terry Pratchett", "Neil Gaiman"] })
    expect(bookAction("year").changes!(null, three)).toEqual({ pubYear: null })
  })

  it("offers runs by the hub's features and the book's formats", () => {
    const ids = (t: ActionTarget, c = {}) => offeredActions(t, c).map((a) => a.id)
    expect(ids(three)).not.toContain("metadata")
    expect(ids(three, { metadata: true, classify: true })).toEqual(expect.arrayContaining(["metadata", "classify"]))
    expect(ids(bookTarget(book()))).toEqual(expect.arrayContaining(["read", "epubFix"]))
    expect(ids(bookTarget(book()))).not.toContain("convert")
    expect(ids(bookTarget(book({ formats: ["PDF"] })))).toContain("convert")
    expect(ids(three)).not.toContain("read")
  })

  it("asks before deleting and before runs over more than 50 books", () => {
    expect(needsConfirm(bookAction("delete"), bookTarget(book()))).toBe(true)
    expect(needsConfirm(bookAction("addTags"), three)).toBe(false)
    expect(needsConfirm(bookAction("addTags"), all)).toBe(true)
    expect(needsConfirm(bookAction("copyLink"), all)).toBe(false)
  })
})
