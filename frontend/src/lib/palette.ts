import type { CategoryNode, Named } from "./api"

export type Scope = "all" | "authors" | "series" | "tags" | "kategorie" | "lists" | "books" | "actions"

const PREFIXES: Record<string, Scope> = { a: "authors", s: "series", t: "tags", k: "kategorie", l: "lists", b: "books" }

// "a pratchett" -> authors, "> theme" / ">theme" -> actions, else everything.
export function parseInput(input: string): { scope: Scope; text: string } {
  if (input.startsWith(">")) return { scope: "actions", text: input.slice(1).trim() }
  const m = /^([a-z]) (.*)$/i.exec(input)
  const scope = m && PREFIXES[m[1].toLowerCase()]
  return scope ? { scope, text: m[2].trim() } : { scope: "all", text: input.trim() }
}

const fold = (s: string) => s.normalize("NFD").replace(/\p{Diacritic}/gu, "").toLowerCase()

// Every word must occur; prefix matches of a word rank first, then by count.
export function matchNamed<T extends Named>(items: T[], text: string, limit: number): T[] {
  const words = fold(text).split(/\s+/).filter(Boolean)
  if (!words.length) return [...items].sort((a, b) => b.count - a.count).slice(0, limit)
  const scored: [T, number][] = []
  for (const item of items) {
    const name = fold(item.name)
    if (!words.every((w) => name.includes(w))) continue
    const starts = name.startsWith(words[0]) || name.split(/[\s.,/-]+/).some((p) => p.startsWith(words[0]))
    scored.push([item, (starts ? 1e9 : 0) + item.count])
  }
  return scored
    .sort((a, b) => b[1] - a[1])
    .slice(0, limit)
    .map(([i]) => i)
}

export function flattenTree(nodes: CategoryNode[]): Named[] {
  return nodes.flatMap((n) => [{ name: n.path, count: n.count }, ...flattenTree(n.children)])
}
