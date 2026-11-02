import { describe, expect, it } from "vitest"
import { categoryLabel, categorySuggestions, parseCategory } from "./kategorie"

describe("category paths", () => {
  it("shows stored dots as slashes", () => {
    expect(categoryLabel("Sachbuch.Geschichte.Antike")).toBe("Sachbuch/Geschichte/Antike")
    expect(categoryLabel("Roman")).toBe("Roman")
  })

  it("stores slashes, › and dots as dots", () => {
    expect(parseCategory("Sachbuch/Geschichte")).toEqual({ value: "Sachbuch.Geschichte" })
    expect(parseCategory(" Sachbuch / Geschichte ")).toEqual({ value: "Sachbuch.Geschichte" })
    expect(parseCategory("Roman › SF › Neu")).toEqual({ value: "Roman.SF.Neu" })
    expect(parseCategory("Roman . SF.Neu")).toEqual({ value: "Roman.SF.Neu" })
    expect(parseCategory("Roman/SF›Neu")).toEqual({ value: "Roman.SF.Neu" })
  })

  it("drops empty levels and clears on empty input", () => {
    expect(parseCategory("Sachbuch/")).toEqual({ value: "Sachbuch" })
    expect(parseCategory("/A//B/")).toEqual({ value: "A.B" })
    expect(parseCategory("  ")).toEqual({ value: null })
  })

  it("rejects a dot inside a name of a path", () => {
    expect(parseCategory("Reisen/St. Petersburg")).toEqual({ error: "St. Petersburg" })
    expect(parseCategory("Reisen › Dr.Who")).toEqual({ error: "Dr.Who" })
  })

  it("round-trips the shown path", () => {
    expect(parseCategory(categoryLabel("A.B.C"))).toEqual({ value: "A.B.C" })
  })

  it("suggests paths and keeps the stored value", () => {
    const tree = [{ name: "Sach", path: "Sach", count: 3, children: [{ name: "Gesch", path: "Sach.Gesch", count: 1, children: [] }] }]
    expect(categorySuggestions(tree)).toEqual([
      { name: "Sach", path: "Sach", count: 3 },
      { name: "Sach/Gesch", path: "Sach.Gesch", count: 1 },
    ])
  })
})
