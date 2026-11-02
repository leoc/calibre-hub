import type { Book, BookPatch } from "./api"
import { categoryOf } from "./api"
import { categoryLabel, parseCategory } from "./kategorie"

// Form state: strings for inputs, normalized again in toPatch.
export interface BookForm {
  title: string
  authors: string[]
  series: string
  seriesIndex: string
  kategorie: string // as a path, "A/B"
  tags: string[]
  languages: string[]
  publisher: string
  pubdate: string // yyyy-mm-dd
  rating: number // 0-5 stars
  identifiers: [string, string][]
  comments: string
}

export function toForm(b: Book, categoryColumn: string | null): BookForm {
  return {
    title: b.title,
    authors: b.authors,
    series: b.series ?? "",
    seriesIndex: b.seriesIndex != null ? String(b.seriesIndex) : "",
    kategorie: categoryLabel(categoryOf(b, categoryColumn) ?? ""),
    tags: b.tags,
    languages: b.languages,
    publisher: b.publisher ?? "",
    pubdate: b.pubdate && new Date(b.pubdate).getUTCFullYear() > 101 ? b.pubdate.slice(0, 10) : "",
    rating: b.rating ? Math.round(b.rating / 2) : 0,
    identifiers: Object.entries(b.identifiers),
    comments: b.comments ?? "",
  }
}

const same = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b)
const orNull = (s: string) => (s.trim() ? s.trim() : null)

// Only changed fields go out, together with the lastModified we started from.
export function toPatch(original: BookForm, form: BookForm, lastModified: string): BookPatch | null {
  const p: BookPatch = {}
  if (form.title.trim() !== original.title) p.title = form.title.trim()
  if (!same(form.authors, original.authors)) p.authors = form.authors
  if (form.series.trim() !== original.series) p.series = orNull(form.series)
  if (form.seriesIndex !== original.seriesIndex || (p.series && !original.series)) {
    const n = parseFloat(form.seriesIndex.replace(",", "."))
    p.seriesIndex = Number.isFinite(n) ? n : null
  }
  // an invalid path stays out; the form shows the error and can't be saved
  const kategorie = parseCategory(form.kategorie)
  if ("value" in kategorie && !same(kategorie, parseCategory(original.kategorie))) p.kategorie = kategorie.value
  if (!same(form.tags, original.tags)) p.tags = form.tags
  if (!same(form.languages, original.languages)) p.languages = form.languages
  if (form.publisher.trim() !== original.publisher) p.publisher = orNull(form.publisher)
  if (form.pubdate !== original.pubdate) p.pubdate = form.pubdate || null
  if (form.rating !== original.rating) p.rating = form.rating ? form.rating * 2 : null
  const ids = form.identifiers.filter(([k, v]) => k.trim() && v.trim()).map(([k, v]) => [k.trim().toLowerCase(), v.trim()])
  if (!same(ids, original.identifiers)) p.identifiers = Object.fromEntries(ids)
  if (form.comments !== original.comments) p.comments = orNull(form.comments)
  return Object.keys(p).length ? { ...p, lastModified } : null
}

// Fields that differ between two versions of the book (for conflicts).
export function changedFields(a: BookForm, b: BookForm): (keyof BookForm)[] {
  return (Object.keys(a) as (keyof BookForm)[]).filter((k) => !same(a[k], b[k]))
}
