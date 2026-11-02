import { describe, expect, it } from "vitest"
import { makeBooks } from "@/mocks/data"
import type { MetadataChange } from "./api"
import { toForm, toPatch } from "./book-form"
import { applyField, formatValue, formValue, groupChanges, sameValue, stripHtml } from "./metadata"

const [a, b] = makeBooks(2)
const change = (id: number, bookId: number, at: string, extra: Partial<MetadataChange> = {}): MetadataChange => ({
  id,
  bookId,
  field: "title",
  old: "x",
  new: "y",
  source: "rules",
  jobId: null,
  at,
  revertedAt: null,
  ...extra,
})

describe("groupChanges", () => {
  it("groups per book, books by their newest change, changes newest first", () => {
    const groups = groupChanges(
      [change(1, a.id, "2026-01-01T10:00:00Z"), change(2, b.id, "2026-01-02T10:00:00Z"), change(3, a.id, "2026-01-03T10:00:00Z", { revertedAt: "2026-01-04T00:00:00Z" })],
      [a, b],
    )
    expect(groups.map((g) => g.bookId)).toEqual([a.id, b.id])
    expect(groups[0].changes.map((c) => c.id)).toEqual([3, 1])
    expect(groups[0].active.map((c) => c.id)).toEqual([1])
    expect(groups[0].book).toBe(a)
  })

  it("keeps changes of a deleted book, without the book", () => {
    const [g] = groupChanges([change(1, 999, "2026-01-01T10:00:00Z")], [a])
    expect(g.book).toBeNull()
    expect(g.active).toHaveLength(1)
  })

  it("orders changes of the same moment by id", () => {
    const at = "2026-01-01T10:00:00Z"
    const [g] = groupChanges([change(1, a.id, at), change(2, a.id, at)], [a])
    expect(g.changes.map((c) => c.id)).toEqual([2, 1])
  })
})

describe("formatValue", () => {
  it("shows empty values as a dash", () => {
    expect(formatValue("publisher", null)).toBe("–")
    expect(formatValue("authors", [])).toBe("–")
    expect(formatValue("isbn", "")).toBe("–")
  })

  it("joins lists and names languages", () => {
    expect(formatValue("authors", ["A", "B"])).toBe("A, B")
    expect(formatValue("languages", ["deu", "eng"])).toBe("Deutsch, Englisch")
  })

  it("shows dates in German, whatever the time zone", () => {
    expect(formatValue("pubdate", "2012-05-21")).toBe("21. Mai 2012")
  })

  it("strips HTML from descriptions and shortens them", () => {
    expect(formatValue("comments", "<p>Kurz &amp; gut.</p>")).toBe("Kurz & gut.")
    const long = formatValue("comments", `<p>${"Wort ".repeat(60)}</p>`, 20)
    expect(long).toHaveLength(20)
    expect(long.endsWith("…")).toBe(true)
  })

  it("formats volume numbers", () => {
    expect(formatValue("seriesIndex", 2.5)).toBe("2,5")
  })
})

describe("stripHtml", () => {
  it("decodes entities and collapses whitespace", () => {
    expect(stripHtml("<p>a&nbsp;b</p>\n<p>&#228;&#x2013;&quot;c&quot;</p>")).toBe("a b ä–\"c\"")
  })
})

describe("candidate fields in the form", () => {
  const book = { ...a, identifiers: { goodreads: "1" }, series: null, seriesIndex: null }
  const form = toForm(book, "kategorie")

  it("adds an ISBN to the identifiers and keeps the others", () => {
    const f = applyField(form, "isbn", "9783608939842")
    expect(f.identifiers).toEqual([
      ["goodreads", "1"],
      ["isbn", "9783608939842"],
    ])
    expect(toPatch(form, f, "LM")?.identifiers).toEqual({ goodreads: "1", isbn: "9783608939842" })
    // replacing an existing one
    expect(applyField(f, "isbn", "123").identifiers).toEqual([
      ["goodreads", "1"],
      ["isbn", "123"],
    ])
  })

  it("compares ISBNs without hyphens", () => {
    const f = applyField(form, "isbn", "978-3-608-93984-2")
    expect(sameValue(f, "isbn", "9783608939842")).toBe(true)
  })

  it("puts series numbers and dates into the form's string fields", () => {
    const f = applyField(applyField(applyField(form, "series", "Foundation"), "seriesIndex", 2), "pubdate", "2011-09-15")
    expect([f.series, f.seriesIndex, f.pubdate]).toEqual(["Foundation", "2", "2011-09-15"])
    expect(formValue(f, "seriesIndex")).toBe(2)
    expect(sameValue(f, "seriesIndex", 2)).toBe(true)
    expect(toPatch(form, f, "LM")).toMatchObject({ series: "Foundation", seriesIndex: 2, pubdate: "2011-09-15" })
  })

  it("knows when the form already has a value", () => {
    expect(sameValue(form, "title", ` ${form.title} `)).toBe(true)
    expect(sameValue(form, "authors", form.authors)).toBe(true)
    expect(sameValue(form, "publisher", "Anderer Verlag")).toBe(false)
    expect(sameValue(form, "coverUrl", "https://x/c.jpg")).toBe(false)
  })

  it("leaves the form alone for a cover", () => {
    expect(applyField(form, "coverUrl", "https://x/c.jpg")).toBe(form)
  })
})
