import { describe, expect, it } from "vitest"
import { flattenTree, matchNamed, parseInput } from "./palette"

describe("palette input", () => {
  it("reads prefixes", () => {
    expect(parseInput("a pratchett")).toEqual({ scope: "authors", text: "pratchett" })
    expect(parseInput("K sach")).toEqual({ scope: "kategorie", text: "sach" })
    expect(parseInput(">dunkel")).toEqual({ scope: "actions", text: "dunkel" })
    expect(parseInput("> dunkel")).toEqual({ scope: "actions", text: "dunkel" })
  })

  it("treats unknown or missing prefixes as plain text", () => {
    expect(parseInput("x ray")).toEqual({ scope: "all", text: "x ray" })
    expect(parseInput("asimov")).toEqual({ scope: "all", text: "asimov" })
    expect(parseInput("a")).toEqual({ scope: "all", text: "a" })
  })
})

describe("matchNamed", () => {
  const items = [
    { name: "Terry Pratchett", count: 40 },
    { name: "Neil Gaiman", count: 10 },
    { name: "Brigitte Präger", count: 2 },
  ]

  it("needs all words, ignores accents, prefers word starts", () => {
    expect(matchNamed(items, "pra", 5).map((i) => i.name)).toEqual(["Terry Pratchett", "Brigitte Präger"])
    expect(matchNamed(items, "terry gai", 5)).toEqual([])
    expect(matchNamed(items, "man", 5).map((i) => i.name)).toEqual(["Neil Gaiman"])
  })

  it("returns the most frequent without text", () => {
    expect(matchNamed(items, "", 1)[0].name).toBe("Terry Pratchett")
  })
})

it("flattens the category tree to paths", () => {
  const tree = [{ name: "Sach", path: "Sach", count: 3, children: [{ name: "Gesch", path: "Sach.Gesch", count: 1, children: [] }] }]
  expect(flattenTree(tree)).toEqual([
    { name: "Sach", count: 3 },
    { name: "Sach.Gesch", count: 1 },
  ])
})
