import { describe, expect, it } from "vitest"
import { librarySearchSchema, toBookQuery, toggleTag, withFilter, PAGE_SIZE } from "./search"

describe("library search", () => {
  it("defaults to newest first, page 1", () => {
    expect(toBookQuery({})).toMatchObject({ sort: "added", order: "desc", offset: 0, limit: PAGE_SIZE })
  })

  it("sorts a series by series order unless a sort is chosen", () => {
    expect(toBookQuery({ series: "Discworld" })).toMatchObject({ sort: "series", order: "asc" })
    expect(toBookQuery({ series: "Discworld", sort: "title" })).toMatchObject({ sort: "title", order: "asc" })
  })

  it("maps page to offset and language into q", () => {
    const q = toBookQuery({ page: 3, q: "pratchett", lang: "deu" })
    expect(q.offset).toBe(2 * PAGE_SIZE)
    expect(q.q).toBe('(pratchett) and languages:"=deu"')
  })

  it("maps unsorted to an empty category column, if there is one", () => {
    expect(toBookQuery({ unsorted: true, q: "x" }, "kategorie").q).toBe("(x) and #kategorie:false")
    expect(toBookQuery({ unsorted: true }, null).q).toBeUndefined()
    expect(librarySearchSchema.parse({ unsorted: "1" }).unsorted).toBe(true)
  })

  it("parses a single tag param as array and drops junk", () => {
    expect(librarySearchSchema.parse({ tag: "leseliste", page: "x", sort: "nope" })).toEqual({
      tag: ["leseliste"],
      page: undefined,
      sort: undefined,
    })
  })

  it("resets page and detail when filters change", () => {
    expect(withFilter({ page: 4, book: 7 }, { author: "A" })).toEqual({ author: "A", page: undefined, book: undefined })
    expect(toggleTag({ tag: ["a"] }, "a").tag).toBeUndefined()
    expect(toggleTag({ tag: ["a"] }, "b").tag).toEqual(["a", "b"])
  })
})
