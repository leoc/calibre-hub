import { infiniteQueryOptions, queryOptions } from "@tanstack/react-query"
import { api, type ConfidenceBand, type IntakeCandidate, type IntakeDetail, type IntakeEntry, type IntakeFilter, type IntakeKind, type IntakeLeft, type IntakeProgress, type IntakeProposal } from "./api"
import { fieldLabel, sourceLabel } from "./metadata"
import { readerFormat } from "./reader"
import { formatNumber, t } from "@/i18n"
import type { MessageKey } from "@/i18n/de"

// entries per request: the list has about 2000
export const INTAKE_PAGE = 100

export type IntakeBand = ConfidenceBand | "none" | "all"

export const intakeFilter = (band: IntakeBand, kind: IntakeKind): IntakeFilter => ({
  band: band === "all" ? undefined : band,
  duplicates: kind === "all" || kind === "skipped" || kind === "library" ? undefined : kind === "duplicates",
  skipped: kind === "skipped" ? true : undefined,
  library: kind === "library" ? true : undefined,
})

// Progress and counts, polled without touching the list: it stays where it
// is while the analysis works (on E-Ink nothing else repaints either)
export const intakeStatusQuery = (band: IntakeBand = "all", kind: IntakeKind = "all") =>
  queryOptions({
    queryKey: ["intake-status", band, kind],
    queryFn: () => api.intake({ ...intakeFilter(band, kind), limit: 1 }),
    staleTime: 5_000,
    refetchInterval: (q) => {
      const state = q.state.data?.progress?.state
      if (!state) return false
      return q.state.data?.pending || q.state.data?.recheck || state === "analysing" || state === "scanning" ? 5_000 : 60_000
    },
  })

export const intakeListQuery = (band: IntakeBand, kind: IntakeKind) =>
  infiniteQueryOptions({
    queryKey: ["intake-list", band, kind],
    queryFn: ({ pageParam }) => api.intake({ ...intakeFilter(band, kind), after: pageParam, limit: INTAKE_PAGE }),
    initialPageParam: undefined as string | undefined,
    getNextPageParam: (last) => last.next ?? undefined,
    staleTime: 30_000,
  })

export const intakeEntryQuery = (id: number) =>
  queryOptions({ queryKey: ["intake-entry", id], queryFn: () => api.intakeEntry(id), staleTime: 60_000 })

// a page boundary moves while files are added: no entry twice
export function uniqueEntries(pages: { entries?: IntakeEntry[] }[]): IntakeEntry[] {
  const byId = new Map<number, IntakeEntry>()
  for (const page of pages) for (const e of page.entries ?? []) if (!byId.has(e.id)) byId.set(e.id, e)
  return [...byId.values()]
}

export const entryTitle = (e: IntakeEntry) => e.proposal?.title ?? e.name

// the row's first line: the file, for a library book without one its title
export const entryName = (e: IntakeEntry) => e.name || e.bookTitle || `#${e.bookId}`

// a book of the library: it has other exits than a file
export const isLibrary = (e: IntakeEntry) => e.kind === "library"

// a proposal to accept: a failed library entry needs a new plan first
export const acceptable = (e: IntakeEntry) => e.proposal !== null && e.status === "analysed" && !e.unchanged

// what a bulk decision of this filter takes: it leaves failed files and what
// looks like a book of the library to Arthur, and what he skipped
export const takeable = (e: IntakeEntry, kind: IntakeKind) => e.status === "analysed" && !e.unchanged && e.action !== "duplicate" && (kind === "skipped" || !e.skipped)

// what stays behind a bulk, in one line; null when it takes all of the filter
export function leftText(left: IntakeLeft | undefined): string | null {
  if (!left) return null
  const parts = [
    left.duplicates && t(left.duplicates === 1 ? "intake.left.duplicate" : "intake.left.duplicates", { count: formatNumber(left.duplicates) }),
    left.failed && t("intake.left.failed", { count: formatNumber(left.failed) }),
    left.skipped && t("intake.left.skipped", { count: formatNumber(left.skipped) }),
    left.unchanged && t("intake.left.unchanged", { count: formatNumber(left.unchanged) }),
  ].filter((p): p is string => !!p)
  if (parts.length === 0) return null
  const list = parts.length > 1 ? `${parts.slice(0, -1).join(", ")} ${t("intake.left.and")} ${parts.at(-1)}` : parts[0]
  const one = left.duplicates + left.failed + left.skipped + left.unchanged === 1
  return t(one ? "intake.left.one" : "intake.left.many", { list })
}

// the entry's format for the reader, null when it has none
export const readableFormat = (e: IntakeEntry) => readerFormat({ formats: e.files.map((f) => f.format) })

// the formats the line about reading in names
export const unreadable = (e: IntakeEntry) => readableFormat(e) === null && e.files.some((f) => ["DJVU", "DJV", "CHM"].includes(f.format))

// why a decision came back; the hub's reason for a field changed since the plan
export function errorText(e: IntakeEntry): string | null {
  const changed = e.error && /^(\w+) changed since the plan/.exec(e.error)
  return changed ? t("intake.changedSince", { field: fieldLabel(changed[1]) }) : e.error
}

// the entry as sure as the candidate chosen for it
export const asChosen = (e: IntakeEntry, c?: IntakeCandidate): IntakeEntry =>
  c ? { ...e, confidence: c.confidence, band: c.confidence >= 90 ? "bulk" : c.confidence >= 60 ? "review" : "unsure" } : e

const year = (date: string | null | undefined) => date?.slice(0, 4) ?? null
const isbnOf = (isbn: string | null | undefined) => isbn?.replace(/[^\dXx]/g, "") ?? null

// What choosing this candidate changes against the proposal, as „Verlag
// Springer“, or „ohne Verlag“ for what it doesn't have: a chosen candidate
// leaves nothing of the proposal's book but title and authors. Empty: the same.
export function candidateDiff(c: IntakeCandidate, p: IntakeProposal | null): string[] {
  if (!p) return []
  const f = c.fields
  const authors = f.authors?.length ? f.authors : p.authors
  const list: string[] = []
  const field = (name: string, value: string | null | undefined, now: string | null | undefined) => {
    if ((value || null) === (now || null)) return
    list.push(value ? `${fieldLabel(name)} ${value}` : t("intake.diff.without", { field: fieldLabel(name) }))
  }
  if (f.title && f.title !== p.title) list.push(`${fieldLabel("title")} ${f.title}`)
  if (authors.join() !== p.authors.join()) list.push(`${fieldLabel("authors")} ${authorsText(authors)}`)
  field("publisher", f.publisher, p.publisher)
  field("pubdate", year(f.pubdate), year(p.pubdate))
  field("series", f.series, p.series)
  field("isbn", isbnOf(f.isbn), isbnOf(p.isbn))
  return list
}

const authorName = (name: string) => (name === "Unknown" ? t("intake.unknownAuthor") : name)

export const authorsText = (authors: string[] | null | undefined) =>
  authors?.length ? authors.map(authorName).join(", ") : t("intake.unknownAuthor")

const BAND_TAG: Record<ConfidenceBand, MessageKey> = { bulk: "intake.tag.bulk", review: "intake.tag.review", unsure: "intake.tag.unsure" }

const badgeTag = (e: IntakeEntry, band: ConfidenceBand, marked: boolean) => {
  if (marked && isLibrary(e)) return t("intake.tag.library")
  return marked && e.action !== "add" ? t("intake.tag.duplicate") : t(BAND_TAG[band])
}

// sure, to check or unsure, or in the list a book that may be there already
export function badgeText(e: IntakeEntry, marked = true): string {
  if (e.confidence == null || e.band == null) return t(isLibrary(e) ? "intake.tag.library" : "intake.tag.failed")
  return t("intake.badge", { value: e.confidence, tag: badgeTag(e, e.band, marked) })
}

// the same for the ring on a phone, read out
export function ringLabel(e: IntakeEntry): string {
  if (e.confidence == null || e.band == null) return t(isLibrary(e) ? "intake.tag.library" : "intake.tag.failed")
  return t("intake.ring", { value: e.confidence, tag: badgeTag(e, e.band, true) })
}

// why the confidence is what it is, from who decided
export function reasonText(e: IntakeEntry): string | null {
  if (isLibrary(e)) return t("intake.why.library")
  if (e.status === "failed") return e.detail
  if (e.decided === "unsure") return t("intake.why.unsure")
  if (e.level === 1) return t(e.band === "unsure" ? "intake.why.isbnAgainst" : "intake.why.isbn")
  if (e.level === 2) return t(e.kind === "calibre" ? "intake.why.opf" : "intake.why.file")
  if (e.level === null) return t("intake.why.rules")
  if (e.decided === "folder") return t("intake.why.folder")
  if (e.decided === "file") return t("intake.why.file")
  if (e.decided === "model") return t("intake.why.model")
  return !e.decided || e.decided === "name" ? t("intake.why.name") : t("intake.why.catalog")
}

// what speaks against simply taking the proposal
export function noteTexts(e: IntakeDetail): string[] {
  const list: string[] = []
  if (isLibrary(e)) return list
  if (e.sameAs) list.push(t("intake.note.same", { name: e.sameAs.split("/").pop() ?? e.sameAs }))
  else if (e.action !== "add") {
    const title = e.bookTitle ?? `#${e.bookId}`
    list.push(e.action === "addFormats" ? t("intake.note.formats", { title, formats: e.addFormats.join(", ") }) : t("intake.note.duplicate", { title }))
  }
  for (const n of e.notes) {
    if (n.kind === "duplicateIsbn") list.push(t("repair.note.duplicateIsbn", { isbn: n.isbn, books: n.books.map((id) => `#${id}`).join(", ") }))
    else list.push(t("repair.note.isbnConflict", { isbn: n.isbn }))
  }
  return list
}

export function candidateSource(source: string): string {
  if (source === "name") return t("intake.source.name")
  if (source === "opf") return t("intake.source.opf")
  const key = sourceLabel(source)
  return key ? t(key) : source
}

// analysed of all in the Eingang, in percent
export const analysedShare = (p: IntakeProgress) => (p.total > 0 ? Math.round((p.analysed * 100) / p.total) : 0)
