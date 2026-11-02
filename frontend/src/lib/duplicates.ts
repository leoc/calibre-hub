import { queryOptions, useMutation, useQueryClient, type QueryClient } from "@tanstack/react-query"
import { request, type Book } from "./api"
import { invalidateLibrary } from "./mutations"
import { formatDate, formatNumber, languageName, t } from "@/i18n"
import type { MessageKey } from "@/i18n/de"

// Duplicates (GET /api/duplicates): groups of books that look like the same
// book, the one the hub would keep, and merging them (README "Duplicates").

export type ReasonKind = "isbn" | "file" | "title" | "broken"

export interface DuplicateReason {
  kind: ReasonKind
  bookIds: [number, number]
  // isbn: the ISBN, file: the format, title: the similarity (0..1), broken: the broken book's id
  detail: string | null
}

export interface DuplicateFile {
  format: string
  size: number
  // below 2 KiB: a broken leftover
  tiny: boolean
}

export interface DuplicateBook {
  book: Book
  hasCover: boolean
  // no files, or only tiny ones
  broken: boolean
  // null when the hub doesn't know the sizes (no library path)
  files: DuplicateFile[] | null
}

export interface DuplicateGroup {
  id: string
  bookIds: number[]
  // the most complete good copy
  keepId: number
  // a shared ISBN, the same file or the same title and author
  sure: boolean
  score: number
  reasons: DuplicateReason[]
  books: DuplicateBook[]
}

export interface Duplicates {
  threshold: number
  groups: DuplicateGroup[]
}

export interface FieldChange {
  field: string
  old: unknown
  new: unknown
}

export interface FormatMove {
  format: string
  from: number
  // replaces a tiny file of the same format
  replace: boolean
}

// What a merge would do (dry run)
export interface MergePlan {
  keepId: number
  otherIds: number[]
  fields: FieldChange[]
  formats: FormatMove[]
  coverFrom: number | null
  // list memberships and reading positions that move
  lists: number
  progress: number
  trash: number[]
}

export interface Merge {
  id: number
  keepId: number
  otherIds: number[]
  status: "running" | "done" | "failed" | "undone"
  at: string
  undoneAt: string | null
  error: string | null
  fields: FieldChange[]
  formats: FormatMove[]
  coverFrom: number | null
  listItems: { listId: number; addedAt: number }[]
  trashed: number[]
  // old id → new id of the books the undo brought back
  restored: Record<string, number>
  // what the undo left as it was
  errors: string[]
}

const json = (body: unknown): RequestInit => ({ method: "POST", body: JSON.stringify(body) })

export const duplicatesApi = {
  list: (threshold?: number) => request<Duplicates>(`/api/duplicates${threshold ? `?threshold=${threshold}` : ""}`),
  merges: () => request<Merge[]>("/api/duplicates/merges"),
  plan: (keepId: number, bookIds: number[]) => request<{ plan: MergePlan }>("/api/duplicates/merge", json({ keepId, bookIds, dryRun: true })),
  // lastModified: the keeper as shown; 409 when it changed since
  merge: (keepId: number, bookIds: number[], lastModified?: string) =>
    request<{ merge: Merge; book: Book }>("/api/duplicates/merge", json({ keepId, bookIds, lastModified })),
  undo: (id: number) => request<{ merge: Merge; books: Book[] }>(`/api/duplicates/merges/${id}/undo`, { method: "POST" }),
  ignore: (bookIds: number[]) => request<{ ignored: number }>("/api/duplicates/ignore", json({ bookIds })),
  unignore: (bookIds: number[]) => request<{ removed: number }>("/api/duplicates/ignore/remove", json({ bookIds })),
}

export const duplicatesQuery = (threshold?: number) =>
  queryOptions({
    queryKey: ["duplicates", threshold ?? null],
    queryFn: () => duplicatesApi.list(threshold),
    staleTime: 0,
  })

export const mergesQuery = queryOptions({
  queryKey: ["duplicate-merges"],
  queryFn: duplicatesApi.merges,
  staleTime: 0,
})

export const planQuery = (keepId: number, bookIds: number[]) =>
  queryOptions({
    queryKey: ["duplicate-plan", keepId, bookIds],
    queryFn: () => duplicatesApi.plan(keepId, bookIds).then((r) => r.plan),
    staleTime: 0,
    retry: false,
  })

function invalidate(qc: QueryClient) {
  qc.invalidateQueries({ queryKey: ["duplicates"] })
  qc.invalidateQueries({ queryKey: ["duplicate-merges"] })
  qc.invalidateQueries({ queryKey: ["lists"] })
  qc.invalidateQueries({ queryKey: ["progress"] })
  invalidateLibrary(qc)
}

export function useMerge() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ keepId, bookIds, lastModified }: { keepId: number; bookIds: number[]; lastModified?: string }) =>
      duplicatesApi.merge(keepId, bookIds, lastModified),
    onSuccess: ({ book }, { bookIds }) => {
      bookIds.forEach((id) => qc.removeQueries({ queryKey: ["book", id] }))
      qc.invalidateQueries({ queryKey: ["book", book.id] })
      invalidate(qc)
    },
  })
}

export function useUndoMerge() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: number) => duplicatesApi.undo(id),
    onSuccess: ({ books }) => {
      books.forEach((b) => qc.invalidateQueries({ queryKey: ["book", b.id] }))
      invalidate(qc)
    },
  })
}

export function useIgnore() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({ bookIds, undo = false }: { bookIds: number[]; undo?: boolean }): Promise<unknown> => (undo ? duplicatesApi.unignore(bookIds) : duplicatesApi.ignore(bookIds)),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["duplicates"] }),
  })
}

// "1,2 MB"
export function formatSize(bytes: number): string {
  if (bytes < 1024) return `${formatNumber(bytes)} B`
  if (bytes < 1024 * 1024) return `${formatNumber(Math.round(bytes / 1024))} KB`
  return `${(bytes / 1024 / 1024).toLocaleString("de-DE", { maximumFractionDigits: 1 })} MB`
}

// "Gleiche ISBN 9781908984500", "Titel und Autor (92 %)"
export function reasonLabel(r: DuplicateReason): string {
  switch (r.kind) {
    case "isbn":
      return t("dup.reason.isbn", { isbn: r.detail ?? "" })
    case "file":
      return t("dup.reason.file", { format: r.detail ?? "" })
    case "title":
      return t("dup.reason.title", { percent: Math.round(Number(r.detail ?? 0) * 100) })
    case "broken":
      return t("dup.reason.broken", { id: r.detail ?? "" })
  }
}

// One reason per kind for the group's header, sure ones first
export function groupReasons(g: DuplicateGroup): DuplicateReason[] {
  const order: ReasonKind[] = ["isbn", "file", "title", "broken"]
  const seen = new Map<string, DuplicateReason>()
  for (const r of g.reasons) {
    const key = `${r.kind}:${r.kind === "title" ? "" : r.detail}`
    const had = seen.get(key)
    if (!had || (r.kind === "title" && Number(r.detail) > Number(had.detail))) seen.set(key, r)
  }
  return [...seen.values()].sort((a, b) => order.indexOf(a.kind) - order.indexOf(b.kind))
}

// The rows of the side-by-side comparison: label and one value per book;
// differs: the books don't all show the same
export interface CompareRow {
  key: string
  label: string
  values: string[]
  differs: boolean
}

const dash = "–"

export function compareRows(g: DuplicateGroup, categoryColumn: string | null): CompareRow[] {
  const v = (f: (d: DuplicateBook) => string | null | undefined) => g.books.map((d) => f(d) || dash)
  const files = (d: DuplicateBook) =>
    d.files
      ? d.files.map((f) => `${f.format} ${formatSize(f.size)}${f.tiny ? ` (${t("dup.tiny")})` : ""}`).join(", ") || t("dup.noFiles")
      : d.book.formats.join(", ") || t("dup.noFiles")
  const rows: [string, MessageKey, string[]][] = [
    ["title", "meta.field.title", v((d) => d.book.title)],
    ["authors", "meta.field.authors", v((d) => d.book.authors.join(", "))],
    ["formats", "dup.formats", v(files)],
    ["isbn", "meta.field.isbn", v((d) => d.book.identifiers.isbn)],
    ["publisher", "meta.field.publisher", v((d) => d.book.publisher)],
    ["pubdate", "meta.field.pubdate", v((d) => formatDate(d.book.pubdate))],
    ["languages", "meta.field.languages", v((d) => d.book.languages.map(languageName).join(", "))],
    ["series", "meta.field.series", v((d) => (d.book.series ? `${d.book.series} ${d.book.seriesIndex ?? ""}`.trim() : null))],
    ["tags", "meta.field.tags", v((d) => d.book.tags.join(", "))],
    ["comments", "meta.field.comments", v((d) => (d.book.comments ? t("dup.hasComments", { count: formatNumber(d.book.comments.replace(/<[^>]*>/g, "").length) }) : null))],
    ["cover", "meta.field.cover", v((d) => (d.hasCover ? t("dup.yes") : null))],
    ["lists", "dup.lists", v((d) => (d.book.lists?.length ? formatNumber(d.book.lists.length) : null))],
    ["added", "dup.added", v((d) => formatDate(d.book.added))],
  ]
  if (categoryColumn) {
    rows.splice(8, 0, ["kategorie", "dup.kategorie", v((d) => {
      const k = d.book.custom[categoryColumn]
      return typeof k === "string" ? k.split(".").join("/") : null
    })])
  }
  return rows.map(([key, label, values]) => ({ key, label: t(label), values, differs: new Set(values).size > 1 }))
}

// The plan as short lines for the confirmation
export function planLines(p: MergePlan, title: (id: number) => string): string[] {
  const lines: string[] = []
  for (const f of p.formats) lines.push(t(f.replace ? "dup.plan.formatReplace" : "dup.plan.format", { format: f.format, id: f.from }))
  const fields = p.fields.map((f) => (f.field === "identifiers" ? t("dup.identifiers") : fieldName(f.field)))
  if (fields.length) lines.push(t("dup.plan.fields", { fields: fields.join(", ") }))
  if (p.coverFrom != null) lines.push(t("dup.plan.cover", { id: p.coverFrom }))
  if (p.lists) lines.push(t("dup.plan.lists", { count: formatNumber(p.lists) }))
  if (p.progress) lines.push(t("dup.plan.progress"))
  for (const id of p.trash) lines.push(t("dup.plan.trash", { id, title: title(id) }))
  return lines
}

const FIELD_KEYS: Record<string, MessageKey> = {
  authors: "meta.field.authors",
  series: "meta.field.series",
  seriesIndex: "meta.field.seriesIndex",
  publisher: "meta.field.publisher",
  pubdate: "meta.field.pubdate",
  languages: "meta.field.languages",
  comments: "meta.field.comments",
  tags: "meta.field.tags",
  rating: "dup.rating",
  kategorie: "dup.kategorie",
}

export const fieldName = (field: string) => (FIELD_KEYS[field] ? t(FIELD_KEYS[field]) : field)
