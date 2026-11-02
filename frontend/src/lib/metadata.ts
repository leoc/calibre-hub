import type { Book, MetadataCandidate, MetadataChange, MetadataField, MetadataSource } from "./api"
import type { BookForm } from "./book-form"
import { formatNumber, languageName, locale, t } from "@/i18n"
import type { MessageKey } from "@/i18n/de"

export const FIELD_LABEL: Record<MetadataField, MessageKey> = {
  title: "meta.field.title",
  authors: "meta.field.authors",
  authorSort: "meta.field.authorSort",
  isbn: "meta.field.isbn",
  publisher: "meta.field.publisher",
  pubdate: "meta.field.pubdate",
  languages: "meta.field.languages",
  comments: "meta.field.comments",
  series: "meta.field.series",
  seriesIndex: "meta.field.seriesIndex",
  cover: "meta.field.cover",
}

// Change-log fields beyond the form fields: tags (Norm, Entwurf, ersetzt) and
// identifiers ("identifier:din" for standards)
export function fieldLabel(field: string): string {
  if (field in FIELD_LABEL) return t(FIELD_LABEL[field as MetadataField])
  if (field === "tags") return t("meta.field.tags")
  const id = /^identifier:(.+)$/.exec(field)
  if (id) return t("meta.field.identifier", { scheme: id[1].toUpperCase() })
  return field
}

const SOURCE_LABEL: Record<MetadataSource, MessageKey> = {
  rules: "meta.source.rules",
  model: "meta.source.model",
  file: "meta.source.file",
  openlibrary: "meta.source.openlibrary",
  dnb: "meta.source.dnb",
  authors: "meta.source.authors",
}

// unknown sources (a newer hub) show as they come
export const sourceLabel = (source: string): MessageKey | null => SOURCE_LABEL[source as MetadataSource] ?? null

export interface BookChanges {
  bookId: number
  // null when the book was deleted since
  book: Book | null
  // newest first
  changes: MetadataChange[]
  // not reverted
  active: MetadataChange[]
}

// Changes per book, books in the order of their newest change.
export function groupChanges(changes: MetadataChange[], books: Book[]): BookChanges[] {
  const byId = new Map(books.map((b) => [b.id, b]))
  const groups = new Map<number, BookChanges>()
  const sorted = [...changes].sort((a, b) => b.at.localeCompare(a.at) || b.id - a.id)
  for (const c of sorted) {
    let g = groups.get(c.bookId)
    if (!g) {
      g = { bookId: c.bookId, book: byId.get(c.bookId) ?? null, changes: [], active: [] }
      groups.set(c.bookId, g)
    }
    g.changes.push(c)
    if (!c.revertedAt) g.active.push(c)
  }
  return [...groups.values()]
}

const ENTITIES: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " " }

export function stripHtml(html: string): string {
  return html
    .replace(/<[^>]*>/g, " ")
    .replace(/&(#\d+|#x[\da-f]+|\w+);/gi, (m, e: string) =>
      e[0] === "#" ? String.fromCodePoint(e[1].toLowerCase() === "x" ? parseInt(e.slice(2), 16) : Number(e.slice(1))) : (ENTITIES[e.toLowerCase()] ?? m),
    )
    .replace(/\s+/g, " ")
    .trim()
}

const truncate = (s: string, max: number) => (s.length > max ? `${s.slice(0, max - 1).trimEnd()}…` : s)

const empty = (v: unknown) => v == null || v === "" || (Array.isArray(v) && v.length === 0)

// "2012-05-21" as a German date, independent of the time zone
function formatDay(v: string): string {
  const d = new Date(`${v.slice(0, 10)}T00:00:00Z`)
  return Number.isNaN(d.getTime()) ? v : d.toLocaleDateString(locale, { year: "numeric", month: "long", day: "numeric", timeZone: "UTC" })
}

// A field value for display; "–" when empty. A cover is its URL.
export function formatValue(field: MetadataField, value: unknown, max = 140): string {
  if (empty(value)) return "–"
  if (Array.isArray(value)) return value.map((x) => (field === "languages" ? languageName(String(x)) : String(x))).join(", ")
  if (field === "pubdate" && typeof value === "string") return formatDay(value)
  if (field === "seriesIndex" && typeof value === "number") return formatNumber(value)
  if (field === "comments" && typeof value === "string") return truncate(stripHtml(value), max) || "–"
  if (typeof value === "object") return JSON.stringify(value)
  return String(value)
}

// Candidates of the edit form: its fields in display order
export type CandidateField = keyof MetadataCandidate["fields"]
export const CANDIDATE_FIELDS: CandidateField[] = ["title", "authors", "isbn", "publisher", "pubdate", "languages", "series", "seriesIndex", "comments", "coverUrl"]
export const candidateLabel = (f: CandidateField): MessageKey => FIELD_LABEL[f === "coverUrl" ? "cover" : f]
export const asMetadataField = (f: CandidateField): MetadataField => (f === "coverUrl" ? "cover" : f)

const isbnOf = (form: BookForm) => form.identifiers.find(([k]) => k.trim().toLowerCase() === "isbn")?.[1] ?? ""

// The form's value of a candidate field, in the candidate's shape
export function formValue(form: BookForm, field: CandidateField): unknown {
  switch (field) {
    case "isbn":
      return isbnOf(form) || null
    case "seriesIndex": {
      const n = parseFloat(form.seriesIndex.replace(",", "."))
      return Number.isFinite(n) ? n : null
    }
    case "coverUrl":
      return null
    default:
      return form[field] === "" ? null : form[field]
  }
}

const norm = (field: CandidateField, v: unknown) => {
  if (empty(v)) return null
  if (field === "isbn") return String(v).replace(/[^\dX]/gi, "").toUpperCase()
  if (field === "pubdate") return String(v).slice(0, 10)
  if (typeof v === "string") return v.trim()
  return v
}

// The form already has the candidate's value
export function sameValue(form: BookForm, field: CandidateField, value: unknown): boolean {
  if (field === "coverUrl") return false
  return JSON.stringify(norm(field, formValue(form, field))) === JSON.stringify(norm(field, value))
}

// The form with one candidate field taken over (the cover is not a form field)
export function applyField(form: BookForm, field: CandidateField, value: unknown): BookForm {
  switch (field) {
    case "coverUrl":
      return form
    case "isbn": {
      const isbn = String(value)
      const has = form.identifiers.some(([k]) => k.trim().toLowerCase() === "isbn")
      return {
        ...form,
        identifiers: has ? form.identifiers.map(([k, v]) => (k.trim().toLowerCase() === "isbn" ? [k, isbn] : [k, v])) : [...form.identifiers, ["isbn", isbn]],
      }
    }
    case "seriesIndex":
      return { ...form, seriesIndex: value == null ? "" : String(value) }
    case "pubdate":
      return { ...form, pubdate: String(value ?? "").slice(0, 10) }
    case "authors":
    case "languages":
      return { ...form, [field]: Array.isArray(value) ? value.map(String) : [] }
    default:
      return { ...form, [field]: value == null ? "" : String(value) }
  }
}
