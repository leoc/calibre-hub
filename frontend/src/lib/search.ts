import { z } from "zod"
import { ALL_SORTS, LIST_SORTS, SORTS, type BookQuery, type QueryTarget, type Sort } from "./api"

export const PAGE_SIZE = 60

// "?edit=1" / "?edit=true" -> true
export const flag = z
  .union([z.boolean(), z.string()])
  .transform((v) => v === true || v === "1" || v === "true" || undefined)
  .optional()
  .catch(undefined)

// Library state lives in the URL, so back/forward and shared links restore it.
export const librarySearchSchema = z.object({
  q: z.string().optional().catch(undefined),
  kategorie: z.string().optional().catch(undefined),
  tag: z
    .union([z.string(), z.array(z.string())])
    .transform((v) => (Array.isArray(v) ? v : [v]))
    .optional()
    .catch(undefined),
  author: z.string().optional().catch(undefined),
  series: z.string().optional().catch(undefined),
  lang: z.string().optional().catch(undefined),
  // books without a category ("Ohne Kategorie")
  unsorted: flag,
  // a reading list: its page, with description and covers; with the books
  // of its sublists unless direct
  list: z.coerce.number().int().optional().catch(undefined),
  // a level of the list tree without a list of its own ("Reise" above
  // "Reise/Meer"), of listOwner when it is someone else's
  listPath: z.string().optional().catch(undefined),
  listOwner: z.string().optional().catch(undefined),
  direct: flag,
  sort: z.enum(ALL_SORTS).optional().catch(undefined),
  order: z.enum(["asc", "desc"]).optional().catch(undefined),
  page: z.coerce.number().int().min(1).optional().catch(undefined),
  // book opened in the detail panel (desktop) or as a page (small screens)
  book: z.coerce.number().int().optional().catch(undefined),
  edit: flag,
})

export type LibrarySearch = z.infer<typeof librarySearchSchema>

const FILTER_KEYS = ["q", "kategorie", "tag", "author", "series", "lang", "unsorted", "list", "listPath"] as const

export function hasFilters(s: LibrarySearch) {
  return FILTER_KEYS.some((k) => (Array.isArray(s[k]) ? s[k].length > 0 : !!s[k]))
}

// A list's page, or a level of the list tree
export const inListView = (s: Pick<LibrarySearch, "list" | "listPath">) => s.list != null || !!s.listPath

// The sorts offered: inside a list only those a list knows
export const sortsFor = (s: LibrarySearch): readonly Sort[] => (inListView(s) ? LIST_SORTS : SORTS)

// Effective sort: explicit choice, otherwise series order inside a series,
// otherwise newest first (in a list: most recently added to it).
export function effectiveSort(s: LibrarySearch): Pick<BookQuery, "sort" | "order"> {
  if (s.sort && sortsFor(s).includes(s.sort)) return { sort: s.sort, order: s.order ?? defaultOrder(s.sort) }
  if (inListView(s)) return { sort: "listAdded", order: s.sort === "listAdded" ? (s.order ?? "desc") : "desc" }
  if (s.series) return { sort: "series", order: "asc" }
  return { sort: "added", order: "desc" }
}

export function defaultOrder(sort: BookQuery["sort"]): "asc" | "desc" {
  return sort === "added" || sort === "listAdded" || sort === "modified" || sort === "published" || sort === "rating" ? "desc" : "asc"
}

const quote = (v: string) => v.replace(/\\/g, "\\\\").replace(/"/g, '\\"')

// calibre search for books with an empty category column
export const unsortedQuery = (categoryColumn: string) => `#${categoryColumn}:false`

// "All matches" for the bulk API: the filters only, no paging, sorting or
// open book; count: the number of matches shown, which the hub checks. A
// search without filters is the whole library, said so with all: true.
export function bulkTarget(search: LibrarySearch, categoryColumn: string | null, count: number): QueryTarget {
  const { page: _p, book: _b, edit: _e, ...filters } = search
  const { offset: _o, limit: _l, sort: _s, order: _r, ...query } = toBookQuery(filters, categoryColumn)
  const empty = Object.values(query).every((v) => v == null || v === "" || (Array.isArray(v) && v.length === 0))
  return { query, expect: count, ...(empty ? { all: true as const } : {}) }
}

export function toBookQuery(s: LibrarySearch, categoryColumn: string | null = null): BookQuery {
  const q = [
    s.q?.trim() && `(${s.q.trim()})`,
    s.lang && `languages:"=${quote(s.lang)}"`,
    s.unsorted && categoryColumn && unsortedQuery(categoryColumn),
  ]
    .filter(Boolean)
    .join(" and ")
  return {
    q: q || undefined,
    kategorie: s.kategorie,
    tag: s.tag,
    author: s.author,
    series: s.series,
    list: s.list,
    listPath: s.list != null ? undefined : s.listPath,
    listOwner: s.list != null || !s.listPath ? undefined : s.listOwner,
    direct: inListView(s) && s.direct ? true : undefined,

    ...effectiveSort(s),
    offset: ((s.page ?? 1) - 1) * PAGE_SIZE,
    limit: PAGE_SIZE,
  }
}

// Filter changes start again at page 1 and close the detail.
export function withFilter(s: LibrarySearch, patch: Partial<LibrarySearch>): LibrarySearch {
  return { ...s, ...patch, page: undefined, book: undefined, edit: undefined }
}

export function toggleTag(s: LibrarySearch, tag: string): LibrarySearch {
  const tags = s.tag ?? []
  const next = tags.includes(tag) ? tags.filter((t) => t !== tag) : [...tags, tag]
  return withFilter(s, { tag: next.length ? next : undefined })
}
