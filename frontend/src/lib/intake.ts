import { infiniteQueryOptions, queryOptions } from "@tanstack/react-query"
import { api, type ConfidenceBand, type IntakeDetail, type IntakeEntry, type IntakeKind, type IntakeProgress } from "./api"
import { sourceLabel } from "./metadata"
import { t } from "@/i18n"
import type { MessageKey } from "@/i18n/de"

// entries per request: the list has about 2000
export const INTAKE_PAGE = 100

export type IntakeBand = ConfidenceBand | "none" | "all"

const params = (band: IntakeBand, kind: IntakeKind, offset: number, limit: number) => ({
  band: band === "all" ? undefined : band,
  duplicates: kind === "all" ? undefined : kind === "duplicates",
  offset,
  limit,
})

// Progress and counts, polled without touching the list: it stays where it
// is while the analysis works (on E-Ink nothing else repaints either)
export const intakeStatusQuery = (kind: IntakeKind = "all") =>
  queryOptions({
    queryKey: ["intake-status", kind],
    queryFn: () => api.intake(params("all", kind, 0, 1)),
    staleTime: 5_000,
    refetchInterval: (q) => {
      const state = q.state.data?.progress?.state
      if (!state) return false
      return state === "analysing" || state === "scanning" ? 5_000 : 60_000
    },
  })

export const intakeListQuery = (band: IntakeBand, kind: IntakeKind) =>
  infiniteQueryOptions({
    queryKey: ["intake-list", band, kind],
    queryFn: ({ pageParam }) => api.intake(params(band, kind, pageParam, INTAKE_PAGE)),
    initialPageParam: 0,
    getNextPageParam: (last, _, offset) => (offset + (last.entries?.length ?? 0) < (last.total ?? 0) ? offset + INTAKE_PAGE : undefined),
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

const authorName = (name: string) => (name === "Unknown" ? t("intake.unknownAuthor") : name)

export const authorsText = (authors: string[] | null | undefined) =>
  authors?.length ? authors.map(authorName).join(", ") : t("intake.unknownAuthor")

const BAND_TAG: Record<ConfidenceBand, MessageKey> = { bulk: "intake.tag.bulk", review: "intake.tag.review", unsure: "intake.tag.unsure" }

// sure, to check or unsure, or in the list a book that may be there already
export function badgeText(e: IntakeEntry, marked = true): string {
  if (e.confidence == null || e.band == null) return t("intake.tag.failed")
  const tag = marked && e.action !== "add" ? t("intake.tag.duplicate") : t(BAND_TAG[e.band])
  return t("intake.badge", { value: e.confidence, tag })
}

// why the confidence is what it is, from who decided
export function reasonText(e: IntakeEntry): string | null {
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
