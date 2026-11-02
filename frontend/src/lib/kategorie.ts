import type { CategoryNode, Named } from "./api"
import { flattenTree } from "./palette"

// Categories are stored with dots ("Sachbuch.Geschichte"), so calibre Desktop
// keeps its hierarchy, but shown and typed as a path ("Sachbuch/Geschichte").
// URL params and the API keep the dots; only the UI converts.

export const categoryLabel = (stored: string) => stored.split(".").join("/")

export type ParsedCategory = { value: string | null } | { error: string }

// "A/B", "A › B" and "A.B" all become "A.B"; empty input clears. Once "/" or
// "›" separate the levels, a dot belongs to a name, which calibre can't
// store: the error carries that name.
export function parseCategory(input: string): ParsedCategory {
  const text = input.trim()
  const sep = /[/›]/.test(text) ? /[/›]/ : /\./
  const parts = text
    .split(sep)
    .map((p) => p.trim())
    .filter(Boolean)
  const dotted = parts.find((p) => p.includes("."))
  if (dotted) return { error: dotted }
  return { value: parts.length ? parts.join(".") : null }
}

// Suggestions for category inputs, as paths.
export const categorySuggestions = (nodes: CategoryNode[]): (Named & { path: string })[] =>
  flattenTree(nodes).map((k) => ({ ...k, path: k.name, name: categoryLabel(k.name) }))
