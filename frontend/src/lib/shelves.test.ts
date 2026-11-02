import { describe, expect, it } from "vitest"
import { QueryClient } from "@tanstack/react-query"
import type { ReadingList, ShelfRule } from "./api"
import { defaultList, lastUsedList, savableLists } from "./lists"
import { conditionLabel, followShelves, fromForm, isShelf, nameFromRule, ruleComplete, ruleFromSearch, ruleSummary, toForm } from "./shelves"

const list = (id: number, patch: Partial<ReadingList> = {}): ReadingList => ({
  id,
  name: `L${id}`,
  description: "",
  owner: "arthur",
  visibility: "private",
  sync: false,
  favorite: false,
  isDefault: false,
  count: 0,
  parent: null,
  leaf: `L${id}`,
  coverBookIds: [],
  createdAt: "",
  updatedAt: "",
  lastUsedAt: null,
  editable: true,
  ...patch,
})

const krimi: ShelfRule = { match: "all", conditions: [{ field: "tag", value: "Krimi" }] }

describe("magic shelves", () => {
  it("turns the library's filters into a rule", () => {
    expect(ruleFromSearch({}, "kategorie")).toBeNull()
    expect(ruleFromSearch({ list: 3, tag: ["a"] }, "kategorie")).toBeNull()
    expect(ruleFromSearch({ q: " dune ", kategorie: "Roman.SF", unsorted: true, tag: ["a", "b"], author: "Frank Herbert", series: "Dune", lang: "deu" }, "kategorie")).toEqual({
      match: "all",
      conditions: [
        { field: "text", value: "dune" },
        { field: "kategorie", value: "Roman.SF" },
        { field: "text", value: "#kategorie:false" },
        { field: "tag", value: "a" },
        { field: "tag", value: "b" },
        { field: "author", value: "Frank Herbert" },
        { field: "series", value: "Dune" },
        { field: "language", value: "deu" },
      ],
    })
  })

  it("names and describes a rule in German", () => {
    const rule: ShelfRule = { match: "any", conditions: [{ field: "kategorie", value: "Roman.Krimi" }, { field: "language", value: "deu", not: true }] }
    expect(nameFromRule(rule)).toBe("Roman/Krimi · Deutsch")
    expect(conditionLabel({ field: "text", value: "rating:>3", not: true })).toBe("Freitext passt nicht rating:>3")
    expect(ruleSummary(rule)).toBe("Kategorie ist Roman/Krimi oder Sprache ist nicht Deutsch")
  })

  it("edits categories as paths and stores them with dots", () => {
    const rule: ShelfRule = { match: "all", conditions: [{ field: "kategorie", value: "Roman.Krimi" }, { field: "tag", value: " x ", not: false }] }
    const form = toForm(rule)
    expect(form.conditions[0].value).toBe("Roman/Krimi")
    expect(fromForm(form)).toEqual({ match: "all", conditions: [{ field: "kategorie", value: "Roman.Krimi" }, { field: "tag", value: "x" }] })
    expect(ruleComplete(form)).toBe(true)
    expect(ruleComplete({ match: "all", conditions: [{ field: "tag", value: " " }] })).toBe(false)
  })

  it("never offers a shelf to save books to", () => {
    const shelf = list(1, { rule: krimi, isDefault: true, lastUsedAt: "2026-11-02T00:00:00Z" })
    const plain = list(2, { lastUsedAt: "2026-11-01T00:00:00Z" })
    expect(isShelf(shelf)).toBe(true)
    expect(isShelf(plain)).toBe(false)
    expect(savableLists([shelf, plain]).map((l) => l.id)).toEqual([2])
    expect(defaultList([shelf, plain])).toBeUndefined()
    expect(lastUsedList([shelf, plain])?.id).toBe(2)
  })

  it("reads the shelves again when books change", async () => {
    const qc = new QueryClient()
    let fetched = 0
    qc.setQueryData(["lists"], [list(1)])
    const stop = followShelves(qc)
    const lists = qc.getQueryCache().find({ queryKey: ["lists"] })!
    qc.getQueryCache().subscribe((e) => e.query === lists && e.type === "updated" && e.action.type === "invalidate" && fetched++)
    // without a shelf nothing happens
    await qc.invalidateQueries({ queryKey: ["books"] })
    await Promise.resolve()
    expect(fetched).toBe(0)
    qc.setQueryData(["lists"], [list(1, { rule: krimi })])
    // one burst of changes, one read
    void qc.invalidateQueries({ queryKey: ["books"] })
    void qc.invalidateQueries({ queryKey: ["books"] })
    await new Promise((r) => setTimeout(r, 0))
    expect(fetched).toBe(1)
    stop()
  })
})
