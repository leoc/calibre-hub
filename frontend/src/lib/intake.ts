import { infiniteQueryOptions, queryOptions } from "@tanstack/react-query"
import { api, type ConfidenceBand, type IntakeCandidate, type IntakeDetail, type IntakeEntry, type IntakeBands, type IntakeFilter, type IntakeKind, type IntakeList, type IntakeOrigin, type IntakeProgress, type IntakeProposal, type IntakeShares, type IntakeUnwritable } from "./api"
import { fieldLabel, sourceLabel } from "./metadata"
import { readerFormat } from "./reader"
import { formatNumber, t } from "@/i18n"
import type { MessageKey } from "@/i18n/de"

// entries per request: the list has about 2000, the surest first
export const INTAKE_PAGE = 100

export type IntakeBand = ConfidenceBand | "none" | "all"
export type IntakeSource = IntakeOrigin | "all"

export const ORIGINS: IntakeOrigin[] = ["inbox", "upload"]

export const originName = (o: IntakeOrigin) => t(`intake.from.${o}`)

// the books of the library come from no source
export const intakeFilter = (band: IntakeBand, kind: IntakeKind, source: IntakeSource = "all"): IntakeFilter => ({
  band: band === "all" ? undefined : band,
  duplicates: kind === "sure" ? "sure" : kind === "all" || kind === "skipped" || kind === "library" ? undefined : kind === "duplicates",
  skipped: kind === "skipped" ? true : undefined,
  library: kind === "library" ? true : undefined,
  origin: source === "all" || kind === "library" ? undefined : source,
})

// a source to name: a row older than the sources may have another word in origin
export const knownOrigin = (o: string | undefined) => ORIGINS.find((x) => x === o)

// the sources with entries, only with more than one there is a choice
export const originsInList = (list: Pick<IntakeList, "origins"> | undefined) => ORIGINS.filter((o) => (list?.origins?.[o] ?? 0) > 0)

// the button's line: every source there is, the order of ORIGINS
export const autoText = (thresholds: IntakeList["thresholds"]) =>
  t("intake.auto.button", {
    list: ORIGINS.filter((o) => thresholds?.[o] !== undefined)
      .map((o) => {
        const value = thresholds?.[o]
        return value == null ? t("intake.auto.sourceOff", { name: originName(o) }) : t("intake.auto.sourceOn", { name: originName(o), value })
      })
      .join(", "),
  })

// Progress and counts, polled without touching the list: it stays where it
// is while the analysis works (on E-Ink nothing else repaints either)
export const intakeStatusQuery = (band: IntakeBand = "all", kind: IntakeKind = "all", source: IntakeSource = "all") =>
  queryOptions({
    queryKey: ["intake-status", band, kind, source],
    queryFn: () => api.intake({ ...intakeFilter(band, kind, source), limit: 1 }),
    staleTime: 5_000,
    refetchInterval: (q) => {
      const state = q.state.data?.progress?.state
      if (!state) return false
      return q.state.data?.pending || q.state.data?.recheck || state === "analysing" || state === "scanning" ? 5_000 : 60_000
    },
  })

export const intakeListQuery = (band: IntakeBand, kind: IntakeKind, source: IntakeSource = "all") =>
  infiniteQueryOptions({
    queryKey: ["intake-list", band, kind, source],
    queryFn: ({ pageParam }) => api.intake({ ...intakeFilter(band, kind, source), after: pageParam, limit: INTAKE_PAGE }),
    initialPageParam: undefined as string | undefined,
    getNextPageParam: (last) => last.next ?? undefined,
    staleTime: 30_000,
  })

// A decided entry on its way out. While its job waits the hub leaves it out of
// every list, so a row that comes back needs no error to say so: a list younger
// than the hub's answer has it because it is back. sent: no answer yet.
export type Leaving = "sent" | number

export const leaving = (mark: Leaving | undefined, listedAt: number) => mark === "sent" || (mark !== undefined && mark >= listedAt)

export const hubTook = (marks: Map<number, Leaving>, ids: number[], now: number) => {
  const next = new Map(marks)
  ids.forEach((id) => next.set(id, now))
  return next
}

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
export const acceptable = (e: IntakeEntry) => e.proposal !== null && e.status === "analysed"

// what „Alle N übernehmen“ takes: it leaves failed files and what looks like a
// book of the library to Arthur, and what he skipped
export const takeable = (e: IntakeEntry) => e.status === "analysed" && e.action !== "duplicate" && !e.skipped

// what „Alle N in den Papierkorb“ takes: the hub says what is sure
export const trashable = (e: IntakeEntry) => e.status === "analysed" && e.action === "duplicate" && e.sure === true && !e.skipped

// the question before it; the filter is what it takes, nothing of it stays
export const trashAllText = (count: number) => (count === 1 ? t("intake.trashAll.one") : t("intake.trashAll.many", { count: formatNumber(count) }))

const FILE_KINDS = ["new", "sure", "duplicates", "skipped"] as const
const bandsSum = (b: IntakeBands) => b.bulk + b.review + b.unsure + b.none

// A filter's number: exactly what the list then shows. Alle is every file, the
// library's books have their own kind.
export const kindCount = (s: IntakeShares, kind: IntakeKind) =>
  kind === "all" ? FILE_KINDS.reduce((n, k) => n + bandsSum(s.kinds[k]), 0) : bandsSum(s.kinds[kind])

export function bandCount(s: IntakeShares, kind: IntakeKind, band: IntakeBand) {
  if (band === "all") return kindCount(s, kind)
  return kind === "all" ? FILE_KINDS.reduce((n, k) => n + s.kinds[k][band], 0) : s.kinds[kind][band]
}

// all that is open in the Eingang, of every source: what the parts add up to
export const openCount = (list: Pick<IntakeList, "progress" | "shares">) => (list.progress?.total ?? 0) + (list.shares ? bandsSum(list.shares.kinds.library) : 0)

export type SharePartId = "bulk" | "review" | "unsure" | "none" | "sure" | "duplicates" | "skipped" | "library" | "waiting"

// A part of the bar and its row in the legend, and the filter it sets; kind null
// for what has no list yet
export interface SharePart {
  id: SharePartId
  kind: IntakeKind | null
  band: IntakeBand
  count: number
}

// Each entry in exactly one part. With a source chosen, only its files: the
// library's books and what waits for the analysis have no source.
export function shareParts(s: IntakeShares, source: IntakeSource): SharePart[] {
  const whole = source === "all"
  const of = (id: SharePartId, kind: Exclude<IntakeKind, "all">, count = bandsSum(s.kinds[kind])): SharePart => ({ id, kind, band: "all", count })
  const fresh = (id: ConfidenceBand | "none"): SharePart => ({ id, kind: "new", band: id, count: s.kinds.new[id] })
  return [
    fresh("bulk"),
    fresh("review"),
    fresh("unsure"),
    fresh("none"),
    of("sure", "sure"),
    of("duplicates", "duplicates"),
    of("skipped", "skipped"),
    of("library", "library", whole ? undefined : 0),
    { id: "waiting", kind: null, band: "all", count: whole ? s.waiting : 0 },
  ]
}

const ONLY_ABOVE_ZERO: SharePartId[] = ["none", "library", "waiting"]

export const inBar = (parts: SharePart[]) => parts.filter((p) => p.count > 0)

// the legend keeps a part at 0, it says that there are none
export const inLegend = (parts: SharePart[]) => parts.filter((p) => p.count > 0 || !ONLY_ABOVE_ZERO.includes(p.id))

export const isPicked = (p: SharePart, kind: IntakeKind, band: IntakeBand) => p.kind === kind && p.band === band

export const partLabel = (p: SharePart) => t(`intake.part.${p.id}`)

export const partTitle = (p: SharePart) => t("intake.part.title", { label: partLabel(p), count: formatNumber(p.count) })

// the line under the title
export function headlineText(waiting: number, open: number): string {
  if (waiting > 0) return t("intake.head.waiting", { waiting: formatNumber(waiting), open: formatNumber(open) })
  if (open === 0) return t("intake.head.none")
  return open === 1 ? t("intake.head.one") : t("intake.head.many", { count: formatNumber(open) })
}

// The bulk of a filter: of the new files what is sure, the sure duplicates, and
// never one with nothing to take. Its number is the filter's.
export function bulkOf(s: IntakeShares, kind: IntakeKind, band: IntakeBand): { decision: "accept" | "trash"; count: number } | null {
  const decision = kind === "sure" ? "trash" : kind === "new" && band === "bulk" ? "accept" : null
  const count = bandCount(s, kind, band)
  return decision && count > 0 ? { decision, count } : null
}

// still of this filter: an entry skipped or taken back changes its kind at once
export const inKind = (e: IntakeEntry, kind: IntakeKind) => {
  if (kind === "skipped") return e.skipped
  return kind === "all" || kind === "library" || !e.skipped
}

// the entry's format for the reader, null when it has none
// no reader for these: the hub makes a PDF of their first pages
export const isDjvu = (format: string) => format === "DJVU" || format === "DJV"

// what reading in asks for; a library's book opens its own file, a DjVu as it is
export const readableFormat = (e: IntakeEntry) =>
  readerFormat({ formats: e.files.map((f) => f.format) }) ?? (isLibrary(e) ? null : (e.files.find((f) => isDjvu(f.format))?.format ?? null))

// the format the line about reading in names
export const unreadable = (e: IntakeEntry) => readableFormat(e) === null && e.files.some((f) => f.format === "CHM")

// why a decision came back: the hub's reason for a field changed since the
// plan, or the books calibre refused it for, „Title (Author); …“, when the hub
// found none of them, or a file larger than calibre-server takes (sizes in
// MB, „0.7“ written „0,7“)
export function errorText(e: IntakeEntry): string | null {
  if (e.error && e.match === "calibre" && e.action === "duplicate" && e.bookId === null) {
    return t("intake.calibreRefused", { books: e.error.split("; ").map((b) => `„${b}“`).join(", ") })
  }
  const mb = (s: string) => s.replace(".", ",")
  const large = e.error && /^file is ([\d.]+) MB, calibre-server takes at most ([\d.]+) MB/.exec(e.error)
  if (large) return t("intake.tooLarge", { size: mb(large[1]), limit: mb(large[2]) })
  const cut = e.error && /^calibre-server closed the connection during a ([\d.]+) MB upload/.exec(e.error)
  if (cut) return t("intake.cutOff", { size: mb(cut[1]) })
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
  else if (e.action !== "add" && e.bookId !== null) {
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

// the folders of the note the hub may not move files out of: the first few,
// how many more there are
export const UNWRITABLE_SHOWN = 10

export function unwritableFolders(u: IntakeUnwritable, shown = UNWRITABLE_SHOWN) {
  return { folders: u.folders.slice(0, shown), more: Math.max(0, u.folders.length - shown) }
}

export const unwritableText = (files: number) => (files === 1 ? t("intake.unwritable.one") : t("intake.unwritable.many", { count: formatNumber(files) }))

export const filesText = (files: number) => (files === 1 ? t("intake.unwritable.file") : t("intake.unwritable.files", { count: formatNumber(files) }))

export const folderName = (path: string) => path || t("intake.unwritable.root")
