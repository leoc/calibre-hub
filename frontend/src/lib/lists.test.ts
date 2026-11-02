import { describe, expect, it } from "vitest"
import type { ReadingList } from "./api"
import { buildListTree, favoriteTree, findNode, flattenListTree, isBelow, listLabel, listLeaf, nodeCount, nodeSearch, nodeTrail } from "./lists"

let id = 0
const list = (name: string, patch: Partial<ReadingList> = {}): ReadingList => ({
  id: ++id,
  name,
  description: "",
  owner: "arthur",
  visibility: "private",
  sync: false,
  favorite: false,
  isDefault: false,
  count: 1,
  totalCount: 1,
  parent: null,
  leaf: name,
  coverBookIds: [],
  createdAt: "",
  updatedAt: "",
  lastUsedAt: null,
  editable: true,
  ...patch,
})

describe("list paths", () => {
  it("shows a path and its last level", () => {
    expect(listLabel(" Urlaub / 2026 ")).toBe("Urlaub/2026")
    expect(listLeaf({ name: "Urlaub/2026" })).toBe("2026")
    expect(isBelow("urlaub", "Urlaub/2026")).toBe(true)
    expect(isBelow("Urlaub", "Urlaubsziele")).toBe(false)
    expect(isBelow("Urlaub", "Urlaub")).toBe(false)
  })
})

describe("buildListTree", () => {
  const lists = [
    list("Klassiker"),
    list("Urlaub/2026", { count: 2, totalCount: 2 }),
    list("Urlaub", { favorite: true, totalCount: 3 }),
    list("Reise/Meer"),
    list("Krimis", { owner: "tilli", visibility: "readable", editable: false }),
    list("urlaub/2025"),
  ]
  const tree = buildListTree(lists, "arthur")

  it("nests by path, favorites first, levels without a list in between, others last", () => {
    const rows = flattenListTree(tree).map((n) => `${"  ".repeat(n.depth)}${n.name}${n.list ? "" : "/"} ${n.owner}`)
    expect(rows).toEqual(["Urlaub arthur", "  2025 arthur", "  2026 arthur", "Klassiker arthur", "Reise/ arthur", "  Meer arthur", "Krimis tilli"])
  })

  it("counts a node with its sublists, a level without a list not", () => {
    const all = flattenListTree(tree)
    expect(nodeCount(all[0])).toBe(3)
    expect(nodeCount(all.find((n) => n.name === "Reise")!)).toBeUndefined()
  })

  it("shows favorites with their sublists", () => {
    expect(favoriteTree(tree).map((n) => [n.name, n.children.length])).toEqual([["Urlaub", 2]])
  })

  it("finds the node of a page and the levels above it", () => {
    const sub = findNode(tree, { list: lists[1].id }, "arthur")!
    expect(sub.path).toBe("Urlaub/2026")
    expect(nodeTrail(tree, sub).map((n) => n.name)).toEqual(["Urlaub", "2026"])
    const reise = findNode(tree, { listPath: "reise" }, "arthur")!
    expect(reise.list).toBeNull()
    expect(nodeSearch(reise, "arthur")).toEqual({ listPath: "Reise", listOwner: undefined })
    expect(nodeSearch(sub, "arthur")).toEqual({ list: lists[1].id })
    expect(findNode(tree, { listPath: "Reise", listOwner: "tilli" }, "arthur")).toBeUndefined()
  })
})
