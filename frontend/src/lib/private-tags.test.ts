import { describe, expect, it } from "vitest"
import type { Book, Categories } from "./api"
import { bookAction, bookTarget, offeredActions, parseDirect, valueChoices, type ActionTarget } from "./book-actions"
import { bulkTarget, hasFilters, librarySearchSchema, toBookQuery, togglePrivateTag } from "./search"
import { ruleFromSearch } from "./shelves"
import { maySync } from "./session"

// Private tags: the user's own tags in the hub, apart from calibre's
const book = (patch: Partial<Book> = {}): Book => ({
  id: 7,
  title: "Der Hobbit",
  authors: ["J. R. R. Tolkien"],
  authorSort: null,
  tags: ["fantasy"],
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
  privateTags: ["Abends"],
  ...patch,
})

const cats: Categories = {
  kategorie: [],
  tags: [{ name: "fantasy", count: 9 }],
  authors: [],
  series: [],
  languages: [],
  privateTags: [
    { name: "Abends", count: 2 },
    { name: "Urlaub", count: 5 },
  ],
}

const three: ActionTarget = { bulk: { ids: [3, 1, 2] }, count: 3, ordered: true }

describe("private tags in the search", () => {
  it("filters by them apart from the tags, in the URL and the query", () => {
    const s = librarySearchSchema.parse({ ptag: "Urlaub", tag: "fantasy" })
    expect(s.ptag).toEqual(["Urlaub"])
    expect(hasFilters({ ptag: ["Urlaub"] })).toBe(true)
    expect(toBookQuery(s)).toMatchObject({ tag: ["fantasy"], ptag: ["Urlaub"] })
    expect(bulkTarget({ ptag: ["Urlaub"] }, null, 5)).toEqual({ query: expect.objectContaining({ ptag: ["Urlaub"] }), expect: 5 })
  })

  it("toggles one of them and starts again at page 1", () => {
    expect(togglePrivateTag({ page: 3 }, "Urlaub")).toMatchObject({ ptag: ["Urlaub"], page: undefined })
    expect(togglePrivateTag({ ptag: ["Urlaub"] }, "Urlaub").ptag).toBeUndefined()
  })

  it("makes no magic shelf of them: calibre's search can't see them", () => {
    expect(ruleFromSearch({ tag: ["fantasy"], ptag: ["Urlaub"] }, null)).toBeNull()
    expect(ruleFromSearch({ tag: ["fantasy"] }, null)).not.toBeNull()
  })
})

describe("private tag commands", () => {
  it("are typed like the tag commands", () => {
    expect(parseDirect("mein tag Abends").map((h) => [h.def.id, h.rest])).toEqual([["addPrivateTags", "Abends"]])
    expect(parseDirect("meinen tag entfernen Urlaub").map((h) => [h.def.id, h.rest])).toEqual([["removePrivateTags", "Urlaub"]])
    // the shared tags keep their words
    expect(parseDirect("tag Noten").map((h) => h.def.id)).toEqual(["addTags"])
  })

  it("pick from the user's own tags, a new one when adding", () => {
    expect(valueChoices(bookAction("addPrivateTags"), { cats }, "urla").map((v) => v.value)).toEqual(["Urlaub", "urla"])
    expect(valueChoices(bookAction("addPrivateTags"), { cats }, "Neu").at(-1)).toMatchObject({ value: "Neu", isNew: true })
    // removing from one book: its own private tags, never calibre's
    expect(valueChoices(bookAction("removePrivateTags"), { cats, book: book() }, "").map((v) => v.value)).toEqual(["Abends"])
    expect(valueChoices(bookAction("removePrivateTags"), { cats }, "fanta")).toEqual([])
  })

  it("are the reader's, with the lists and what changes nothing", () => {
    const reader = offeredActions(three, { metadata: true, classify: true }, false).map((a) => a.id)
    expect(reader).toEqual(expect.arrayContaining(["addPrivateTags", "removePrivateTags", "addToList", "removeFromList", "download"]))
    for (const id of ["addTags", "kategorie", "delete", "metadata", "classify", "epubFix", "duplicates"]) expect(reader).not.toContain(id)
    expect(offeredActions(bookTarget(book()), {}, false).map((a) => a.id)).toContain("read")
    expect(offeredActions(three, {}).map((a) => a.id)).toEqual(expect.arrayContaining(["addTags", "addPrivateTags", "delete"]))
  })
})

describe("syncing lists", () => {
  it("is for admins and readers with a reader folder of their own", () => {
    expect(maySync({ user: "arthur", role: "admin" })).toBe(true)
    expect(maySync({ user: "lea", role: "reader" })).toBe(false)
    expect(maySync({ user: "lea", role: "reader", sync: true })).toBe(true)
    expect(maySync(undefined)).toBe(false)
  })
})
