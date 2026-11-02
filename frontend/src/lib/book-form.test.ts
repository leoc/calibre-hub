import { describe, expect, it } from "vitest"
import { makeBooks } from "@/mocks/data"
import { changedFields, toForm, toPatch } from "./book-form"

const book = { ...makeBooks(1)[0], series: null, seriesIndex: null, rating: 6, custom: { kategorie: "Roman.Fantasy" } }

describe("book form", () => {
  it("sends nothing when nothing changed", () => {
    const f = toForm(book, "kategorie")
    expect(toPatch(f, { ...f }, book.lastModified)).toBeNull()
  })

  it("sends only changed fields, normalized, with lastModified", () => {
    const f = toForm(book, "kategorie")
    const p = toPatch(f, { ...f, title: " Neu ", series: "Erdsee", seriesIndex: "2,5", kategorie: "Roman › SF . Neu", rating: 0 }, "LM")
    expect(p).toEqual({ title: "Neu", series: "Erdsee", seriesIndex: 2.5, kategorie: "Roman.SF.Neu", rating: null, lastModified: "LM" })
  })

  it("clears empty strings to null and drops empty identifier rows", () => {
    const f = { ...toForm(book, "kategorie"), identifiers: [["isbn", "1"]] as [string, string][] }
    const p = toPatch(f, { ...f, kategorie: "  ", identifiers: [["ISBN", " 1 "], ["", ""]] }, "LM")
    expect(p).toEqual({ kategorie: null, lastModified: "LM" })
  })

  it("lists fields changed elsewhere", () => {
    const f = toForm(book, "kategorie")
    expect(changedFields(f, { ...f, tags: ["x"], title: "y" })).toEqual(["title", "tags"])
  })
})
