import { describe, expect, it } from "vitest"
import { makeBooks } from "@/mocks/data"
import { compareRows, formatSize, groupReasons, planLines, reasonLabel, type DuplicateGroup } from "./duplicates"

const [a, b] = makeBooks(2)

const group: DuplicateGroup = {
  id: "1-2",
  bookIds: [1, 2],
  keepId: 1,
  sure: true,
  score: 1,
  reasons: [
    { kind: "title", bookIds: [1, 2], detail: "0.9" },
    { kind: "broken", bookIds: [1, 2], detail: "2" },
    { kind: "isbn", bookIds: [1, 2], detail: "9781908984500" },
    { kind: "title", bookIds: [1, 2], detail: "0.95" },
  ],
  books: [
    { book: { ...a, title: "Buch", formats: ["PDF"], publisher: "Verlag" }, hasCover: true, broken: false, files: [{ format: "PDF", size: 3_000_000, tiny: false }] },
    { book: { ...b, title: "Buch", formats: ["PDF"], publisher: null }, hasCover: false, broken: true, files: [{ format: "PDF", size: 80, tiny: true }] },
  ],
}

describe("duplicates", () => {
  it("formats file sizes", () => {
    expect(formatSize(80)).toBe("80 B")
    expect(formatSize(5_000)).toBe("5 KB")
    expect(formatSize(3_000_000)).toBe("2,9 MB")
  })

  it("names the reasons, sure ones first, the best title match once", () => {
    expect(groupReasons(group).map(reasonLabel)).toEqual(["Gleiche ISBN 9781908984500", "Titel und Autor (95 %)", "Defekte Datei (#2)"])
    expect(reasonLabel({ kind: "file", bookIds: [1, 2], detail: "EPUB" })).toBe("Gleiche Datei (EPUB)")
  })

  it("compares the books row by row and marks differences", () => {
    const rows = compareRows(group, "kategorie")
    const row = (key: string) => rows.find((r) => r.key === key)!
    expect(row("title")).toMatchObject({ values: ["Buch", "Buch"], differs: false })
    expect(row("formats").values).toEqual(["PDF 2,9 MB", "PDF 80 B (defekt)"])
    expect(row("publisher")).toMatchObject({ values: ["Verlag", "–"], differs: true })
    expect(row("cover").values).toEqual(["ja", "–"])
    expect(rows.some((r) => r.key === "kategorie")).toBe(true)
    expect(compareRows(group, null).some((r) => r.key === "kategorie")).toBe(false)
  })

  it("describes a merge plan", () => {
    const lines = planLines(
      {
        keepId: 1,
        otherIds: [2],
        fields: [
          { field: "publisher", old: null, new: "Verlag" },
          { field: "identifiers", old: {}, new: { isbn: "1" } },
        ],
        formats: [
          { format: "EPUB", from: 2, replace: false },
          { format: "PDF", from: 2, replace: true },
        ],
        coverFrom: 2,
        lists: 2,
        progress: 1,
        trash: [2],
      },
      () => "Zwei",
    )
    expect(lines).toEqual([
      "EPUB von #2 kommt dazu",
      "PDF von #2 ersetzt die defekte Datei",
      "Übernimmt Verlag, Kennungen",
      "Cover von #2",
      "In 2 weitere Listen",
      "Lesestand wird übernommen",
      "#2 „Zwei“ kommt in den Papierkorb",
    ])
  })
})
