import { useSyncExternalStore } from "react"
import type { QueryClient } from "@tanstack/react-query"
import { languageName, t } from "@/i18n"
import type { ReadingList, ShelfCondition, ShelfRule } from "./api"
import { categoryLabel, parseCategory } from "./kategorie"
import { inListView, unsortedQuery, type LibrarySearch } from "./search"

// Magic shelves: a reading list with a rule instead of books of its own
// (README "Magic shelves"). Shown like a list everywhere a list is opened
// (sidebar, overview, palette, ?list=), but never offered to save books to.

export const isShelf = (l: Pick<ReadingList, "rule"> | null | undefined): boolean => !!l?.rule

// The library's filters as a rule, all of them must match; null without
// filters or on a list's page (its books aren't a search)
export function ruleFromSearch(s: LibrarySearch, categoryColumn: string | null): ShelfRule | null {
  // private tags live in the hub, a shelf's calibre search can't see them
  if (inListView(s) || s.ptag?.length) return null
  const c: ShelfCondition[] = []
  if (s.q?.trim()) c.push({ field: "text", value: s.q.trim() })
  if (s.kategorie) c.push({ field: "kategorie", value: s.kategorie })
  if (s.unsorted && categoryColumn) c.push({ field: "text", value: unsortedQuery(categoryColumn) })
  s.tag?.forEach((tag) => c.push({ field: "tag", value: tag }))
  if (s.author) c.push({ field: "author", value: s.author })
  if (s.series) c.push({ field: "series", value: s.series })
  if (s.lang) c.push({ field: "language", value: s.lang })
  return c.length ? { match: "all", conditions: c } : null
}

// A suggested name for a shelf from a search: its values ("Krimi · Deutsch")
export function nameFromRule(rule: ShelfRule): string {
  return rule.conditions
    .map((c) => (c.field === "kategorie" ? categoryLabel(c.value) : c.field === "language" ? languageName(c.value) : c.value))
    .join(" · ")
    .slice(0, 120)
}

// How a value shows: categories as paths, languages by name
export const shownValue = (c: ShelfCondition) =>
  c.field === "kategorie" ? categoryLabel(c.value) : c.field === "language" ? languageName(c.value) : c.value

// "Tag ist Krimi", "Sprache ist nicht Deutsch", "Freitext passt rating:>3"
export function conditionLabel(c: ShelfCondition): string {
  const op = c.field === "text" ? t(c.not ? "shelf.op.textNot" : "shelf.op.textIs") : t(c.not ? "shelf.op.not" : "shelf.op.is")
  return `${t(`shelf.field.${c.field}`)} ${op} ${shownValue(c)}`
}

// "Tag ist Krimi und Sprache ist Deutsch"
export const ruleSummary = (rule: ShelfRule) => rule.conditions.map(conditionLabel).join(` ${t(rule.match === "any" ? "shelf.or" : "shelf.and")} `)

// What the form edits: categories typed as paths; back to the stored form
// (dots) for the API
export const toForm = (rule: ShelfRule): ShelfRule => ({
  match: rule.match,
  conditions: rule.conditions.map((c) => (c.field === "kategorie" ? { ...c, value: categoryLabel(c.value) } : { ...c })),
})

export function fromForm(rule: ShelfRule): ShelfRule {
  return {
    match: rule.match,
    conditions: rule.conditions.map((c) => {
      const value = c.value.trim()
      const stored = c.field === "kategorie" ? (() => {
        const p = parseCategory(value)
        return "value" in p && p.value ? p.value : value
      })() : value
      return c.not ? { field: c.field, value: stored, not: true } : { field: c.field, value: stored }
    }),
  }
}

export const ruleComplete = (rule: ShelfRule) => rule.conditions.length > 0 && rule.conditions.every((c) => c.value.trim())

export const emptyCondition = (): ShelfCondition => ({ field: "tag", value: "" })

// The dialog for a new shelf, opened from the toolbar, the overview and the
// palette, with the search's rule or an empty one
export interface ShelfDraft {
  rule: ShelfRule
  name?: string
}
let draft: ShelfDraft | null = null
const listeners = new Set<() => void>()
export const shelfDialog = {
  open: (d: ShelfDraft) => {
    draft = d
    listeners.forEach((l) => l())
  },
  close: () => {
    draft = null
    listeners.forEach((l) => l())
  },
}

export function useShelfDialog(): ShelfDraft | null {
  return useSyncExternalStore(
    (l) => {
      listeners.add(l)
      return () => listeners.delete(l)
    },
    () => draft,
  )
}

// Counts that follow the library: whenever books change, every place that
// changes them invalidates ["books"] or ["categories"]; then the shelves are
// read again, once per burst of changes. Wraps invalidateQueries itself, as
// the cache only reports an invalidation of a query that is still fresh.
export function followShelves(qc: QueryClient): () => void {
  let pending = false
  const invalidate = qc.invalidateQueries.bind(qc)
  qc.invalidateQueries = ((filters, options) => {
    const key = filters?.queryKey?.[0]
    if (!pending && (key === "books" || key === "categories") && qc.getQueryData<ReadingList[]>(["lists"])?.some(isShelf)) {
      pending = true
      queueMicrotask(() => {
        pending = false
        void invalidate({ queryKey: ["lists"] })
        void invalidate({ queryKey: ["list"] })
      })
    }
    return invalidate(filters, options)
  }) as QueryClient["invalidateQueries"]
  return () => {
    qc.invalidateQueries = invalidate
  }
}
