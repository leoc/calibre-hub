// Types and fetch helpers for the calibre-hub API (see README.md).
import type { ReaderSettings } from "./reader-settings"

export interface Book {
  id: number
  title: string
  authors: string[]
  authorSort: string | null
  tags: string[]
  series: string | null
  seriesIndex: number | null
  formats: string[]
  lastModified: string
  added: string | null
  pubdate: string | null
  rating: number | null
  publisher: string | null
  identifiers: Record<string, string>
  languages: string[]
  comments?: string | null
  custom: Record<string, unknown>
  // ids of the reading lists the book is in (older hubs: missing)
  lists?: number[]
  // the user's private tags (only theirs, kept in the hub, not in calibre;
  // older hubs: missing)
  privateTags?: string[]
}

export const VISIBILITIES = ["private", "readable", "editable"] as const
export type Visibility = (typeof VISIBILITIES)[number]

// Magic shelves: a list whose books come from a rule, AND ("all") or OR
// ("any") over conditions; kategorie is stored with dots, language is
// calibre's code ("deu"), text is calibre search syntax like ?q=
export const SHELF_FIELDS = ["tag", "kategorie", "author", "series", "language", "text"] as const
export type ShelfField = (typeof SHELF_FIELDS)[number]
export interface ShelfCondition {
  field: ShelfField
  value: string
  not?: boolean
}
export interface ShelfRule {
  match: "all" | "any"
  conditions: ShelfCondition[]
}

// A reading list, like a playlist (GET /api/lists)
export interface ReadingList {
  id: number
  name: string
  description: string
  owner: string
  visibility: Visibility
  // mirrored to the reader (leseliste handler)
  sync: boolean
  // shown in the sidebar first
  favorite: boolean
  // the bookmark on the cover saves to it
  isDefault: boolean
  count: number
  // nested lists: the name is a path ("Urlaub/2026"); the path above it
  // (null at the top) and the last level
  parent: string | null
  leaf: string
  // distinct books incl. the sublists the user sees (older hubs: missing)
  totalCount?: number
  // the most recently added books, for the cover mosaic
  coverBookIds: number[]
  createdAt: string
  updatedAt: string
  // last time books were added
  lastUsedAt: string | null
  // the user may change it
  editable: boolean
  // a magic shelf: its rule and the calibre search the hub made of it; its
  // books and count come from that search (older hubs: missing)
  rule?: ShelfRule | null
  query?: string | null
  // the search failed, count is 0
  queryError?: string | null
}

// A device's last reading position in a book (GET /api/books/:id/progress).
// position depends on the format: CFI (EPUB, MOBI/AZW3, CBZ), page (PDF)
export interface ProgressEntry {
  bookId: number
  device: string
  deviceName: string
  format: string
  position: string
  fraction: number
  source: "web" | "koreader"
  updatedAt: string
}

export interface BookProgress {
  // newest over all devices, null when never opened
  latest: ProgressEntry | null
  devices: ProgressEntry[]
}

export interface ProgressSave {
  format: string
  position: string
  fraction: number
  device: string
  deviceName?: string
  // ms since it was read, for positions sent late (read offline)
  age?: number
}

export type ListPatch = Partial<Pick<ReadingList, "name" | "description" | "visibility" | "sync" | "favorite" | "isDefault">> & { rule?: ShelfRule }

export interface BookPage {
  total: number
  offset: number
  limit: number
  books: Book[]
}

export interface CategoryNode {
  name: string
  path: string
  count: number
  children: CategoryNode[]
}

export interface Named {
  name: string
  count: number
}

export interface Categories {
  kategorie: CategoryNode[]
  tags: Named[]
  authors: Named[]
  series: Named[]
  languages: Named[]
  // the user's private tags (older hubs: missing)
  privateTags?: Named[]
}

export interface HubConfig {
  // replaced by favorite lists; still sent for older web apps
  fastTags?: string[]
  categoryColumn: string | null
  // category suggestions from a local model (services.calibre-hub.classify)
  classify?: boolean
  // metadata completion and cleanup (title, authors, ISBN, cover …)
  metadata?: boolean
}

export const METADATA_FIELDS = ["title", "authors", "authorSort", "isbn", "publisher", "pubdate", "languages", "comments", "series", "seriesIndex", "cover"] as const
export type MetadataField = (typeof METADATA_FIELDS)[number]
export type MetadataSource = "rules" | "model" | "file" | "hardcover" | "openlibrary" | "dnb" | "authors"

// One logged field change of the metadata cleanup; revertable while the
// field still has the new value
export interface MetadataChange {
  id: number
  bookId: number
  field: MetadataField
  old: unknown
  new: unknown
  source: MetadataSource
  jobId: string | null
  at: string
  revertedAt: string | null
}

export type MetadataTarget = "incomplete" | "all" | "authors" | BulkTarget

// How sure a decision is: bulk from 90, review from 60, unsure below
export type ConfidenceBand = "bulk" | "review" | "unsure"

// the Eingang: new files of the backlog, the inbox and uploads, analysed, not
// in the library
export type IntakeKind = "all" | "new" | "sure" | "duplicates" | "skipped" | "library"
export type IntakeOrigin = "backlog" | "inbox" | "upload"

export type IntakeDecision = "accept" | "file" | "format" | "skip" | "unskip" | "trash" | "reject"
export interface IntakeFilter {
  band?: string
  // true: those that stay for a person; "sure": what a bulk may trash
  duplicates?: boolean | "sure"
  skipped?: boolean
  origin?: IntakeOrigin
  // the proposals for books of the library, instead of the files
  library?: boolean
}

export interface IntakeProgress {
  state: "idle" | "scanning" | "analysing" | "paused" | "off"
  // of the whole list, whatever the filters: every book in the Eingang,
  // those looked at, those with a proposal
  total: number
  done: number
  analysed: number
  current: string | null
}

export interface IntakeProposal {
  title: string
  authors: string[]
  publisher: string | null
  pubdate: string | null
  series: string | null
  seriesIndex: number | null
  isbn: string | null
  languages: string[]
}

export interface IntakeEntry {
  // a book of the library: minus its book id
  id: number
  path: string
  // a book of the library without a file an import read: empty
  name: string
  // below its root, null in the root
  folder: string | null
  kind: "file" | "calibre" | "library"
  // a book of the library has none
  origin?: IntakeOrigin
  files: { path: string; format: string; size: number }[]
  status: "analysed" | "failed"
  detail: string | null
  proposal: IntakeProposal | null
  confidence: number | null
  band: ConfidenceBand | null
  titleConfidence: number | null
  authorsConfidence: number | null
  level: 1 | 2 | 3 | null
  source: string | null
  decided: string | null
  isbnSource: string | null
  notes: RepairNote[]
  action: "add" | "addFormats" | "duplicate" | "update"
  bookId: number | null
  match: string | null
  sameAs: string | null
  addFormats: string[]
  cover: string | null
  analysedAt: string
  // not asked again until taken back
  skipped: boolean
  // why the last decision came back
  error: string | null
  // the library's book it looks like; a library entry's title now
  bookTitle: string | null
  // a sure duplicate: a bulk may trash it
  sure?: boolean
}

export interface IntakeCandidate {
  source: string
  confidence: number
  fields: {
    title?: string | null
    authors?: string[] | null
    publisher?: string | null
    pubdate?: string | null
    series?: string | null
    seriesIndex?: number | null
    isbn?: string | null
    languages?: string[] | null
    coverUrl?: string | null
  }
  url: string | null
}

export interface IntakeDetail extends IntakeEntry {
  changes: { field: string; old: unknown; new: unknown; source: string }[]
  candidates: IntakeCandidate[]
  // a library entry: the tag of unsure books
  unsureTag?: string
}

// what a bulk leaves in the list
export interface IntakeLeft {
  duplicates: number
  failed: number
  skipped: number
}

// how many of a kind there are per band; none: no confidence, a failed file
export type IntakeBands = { bulk: number; review: number; unsure: number; none: number }

// Every number of the bar and the filters, whatever the filters are. The kinds
// of files follow the source; library, waiting and books have none.
export interface IntakeShares {
  kinds: Record<"new" | "sure" | "duplicates" | "skipped" | "library", IntakeBands>
  // found, not analysed yet
  waiting: number
  // of the library, null until calibre has answered
  books: number | null
}

export interface IntakeList {
  enabled: boolean
  progress?: IntakeProgress
  total?: number
  counts?: IntakeBands
  // what „Alle N übernehmen“ takes of the filter, how many of them unsure
  takeable?: number
  unsure?: number
  // the sure duplicates of the band and source, what „Alle N in den Papierkorb“ takes
  trashable?: number
  left?: IntakeLeft
  skipped?: number
  // the newest entry: a bulk decision stops there
  last?: number
  // decided, waiting for their job
  pending?: number
  // the sources there are: from this confidence on their books go by themselves
  thresholds?: Partial<Record<IntakeOrigin, number | null>>
  // how many of each are in the list, whatever the filters
  origins?: Partial<Record<IntakeOrigin, number>>
  shares?: IntakeShares
  // the next page is behind this place in the list
  next?: string | null
  entries?: IntakeEntry[]
  // the library filter: the recheck under way, waiting: for the analysis
  recheck?: { done: number; total: number; waiting: boolean } | null
}

// a conflict for the review: the same ISBN on other books, or another ISBN
// in the book than the one it has
export interface RepairNote {
  kind: "duplicateIsbn" | "isbnConflict"
  isbn: string
  books: number[]
}

// A proposal for a book of the library: the fields to change, who decided, how
// sure it is and on which level (1 ISBN in the book, 2 the file's metadata, 3
// the file name). Older plans have no confidence.
export interface ImportRepairEntry {
  bookId: number
  file: string
  // name, folder, file, calibre, hardcover, dnb, openlibrary, model, unsure
  decided: string | null
  status: "pending" | "applied" | "rejected" | "failed"
  at: string
  confidence: number | null
  band: ConfidenceBand | null
  level: 1 | 2 | 3 | null
  source: string | null
  titleConfidence: number | null
  authorsConfidence: number | null
  notes: RepairNote[]
  // field "candidate": what the catalogs suggest but couldn't confirm
  // ({title, authors, source}), shown for the review and never applied
  changes: { field: string; old: unknown; new: unknown }[]
}

export interface MetadataStatus {
  enabled: boolean
  sources?: string[]
  // model that cleans names, null without one
  model?: string | null
  // "HH:MM"
  nightly?: string | null
  running?: boolean
  // books with at least one change not reverted
  changedBooks?: number
  lastRun?: (Job & { id: string; startedAt: string; target: string }) | null
}

// What one source knows about a book; only the fields it has
export interface MetadataCandidate {
  source: "rules" | "file" | "hardcover" | "openlibrary" | "dnb"
  score: number
  // ISBN matched exactly
  sure: boolean
  url: string | null
  fields: {
    title?: string
    authors?: string[]
    isbn?: string
    publisher?: string
    pubdate?: string
    languages?: string[]
    comments?: string
    series?: string
    seriesIndex?: number
    coverUrl?: string
  }
}

export interface MetadataChangesQuery {
  bookId?: number
  since?: string
  reverted?: boolean
  limit?: number
}

export type SuggestionStatus = "pending" | "auto" | "applied" | "rejected" | "none"

// The latest category suggestion for a book; category is stored dotted, null
// when no category of the tree fits
export interface Suggestion {
  bookId: number
  category: string | null
  confidence: number
  reason: string
  model: string
  at: string
  status: SuggestionStatus
}

export interface ClassifyStatus {
  enabled: boolean
  model?: string
  threshold?: number
  // nodes in the category tree; below minCategories nothing is suggested
  categories?: number
  minCategories?: number
  pending?: number
  running?: boolean
  lastRun?: (Job & { id: string; startedAt: string }) | null
}

export type ClassifyTarget = "unsorted" | BulkTarget

export const SORTS = ["title", "author", "added", "modified", "published", "series", "rating"] as const
// inside a list: the time a book was added to it first, no manual order
export const LIST_SORTS = ["listAdded", "title", "author", "series"] as const
export const ALL_SORTS = [...SORTS, "listAdded"] as const
export type Sort = (typeof ALL_SORTS)[number]

export interface BookQuery {
  q?: string
  kategorie?: string
  tag?: string[]
  // the user's private tags (all of them)
  ptag?: string[]
  author?: string
  series?: string
  // books of a reading list (and its sublists unless direct)
  list?: number
  // a level of the list tree that may have no list of its own
  listPath?: string
  listOwner?: string
  direct?: boolean

  sort?: Sort
  order?: "asc" | "desc"
  offset?: number
  limit?: number
}

export class ApiError extends Error {
  constructor(
    public status: number,
    message: string,
    public body: Record<string, unknown> | null = null,
  ) {
    super(message)
  }
}

export async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  const method = (init.method ?? "GET").toUpperCase()
  const headers = new Headers(init.headers)
  if (method !== "GET" && method !== "HEAD") headers.set("X-Calibre-Hub", "1")
  if (init.body && !headers.has("Content-Type")) headers.set("Content-Type", "application/json")
  const res = await fetch(path, { ...init, headers, credentials: "same-origin" })
  if (!res.ok) {
    const body = await res.json().catch(() => null)
    throw new ApiError(res.status, body?.error ?? res.statusText, body)
  }
  return res.status === 204 ? (undefined as T) : ((await res.json()) as T)
}

export function bookSearchParams(query: BookQuery): URLSearchParams {
  const p = new URLSearchParams()
  for (const [k, v] of Object.entries(query)) {
    if (v === undefined || v === "") continue
    if (Array.isArray(v)) v.forEach((x) => p.append(k, x))
    else p.set(k, String(v))
  }
  return p
}

// role: admin edits the library, reader only reads (and keeps own lists)
export interface Session {
  user: string
  role?: "admin" | "reader"
  // may sync lists to a reader folder (admins; readers with their own)
  sync?: boolean
}

export const api = {
  session: () => request<Session>("/api/session"),
  login: (user: string, password: string) =>
    request<Session>("/api/session", { method: "POST", body: JSON.stringify({ user, password }) }),
  logout: () => request<void>("/api/session", { method: "DELETE" }),
  books: (query: BookQuery) => request<BookPage>(`/api/books?${bookSearchParams(query)}`),
  book: (id: number) => request<Book>(`/api/books/${id}`),
  categories: () => request<Categories>("/api/categories"),
  trash: () => request<TrashEntry[]>("/api/trash"),
  suggestions: (status?: SuggestionStatus) =>
    request<(Suggestion & { book: Book })[]>(`/api/suggestions${status ? `?status=${status}` : ""}`),
  // null when the book has none
  suggestion: (bookId: number) =>
    request<Suggestion>(`/api/suggestions/${bookId}`).catch((e) => {
      if (e instanceof ApiError && e.status === 404) return null
      throw e
    }),
  classifyStatus: () => request<ClassifyStatus>("/api/classify/status"),
  metadataStatus: () => request<MetadataStatus>("/api/metadata/status"),
  intake: (p: IntakeFilter & { after?: string; limit: number }) => {
    const q = new URLSearchParams({ limit: String(p.limit) })
    if (p.band) q.set("band", p.band)
    if (p.duplicates !== undefined) q.set("duplicates", String(p.duplicates))
    if (p.skipped) q.set("skipped", "true")
    if (p.origin) q.set("origin", p.origin)
    if (p.library) q.set("library", "true")
    if (p.after) q.set("after", p.after)
    return request<IntakeList>(`/api/intake?${q}`)
  },
  intakeEntry: (id: number) => request<IntakeDetail>(`/api/intake/${id}`),
  uploadState: (id: string) => request<UploadState>(`/api/intake/uploads/${id}`),
  metadataChanges: (query: MetadataChangesQuery = {}) =>
    request<{ changes: MetadataChange[]; books: Book[] }>(`/api/metadata/changes?${new URLSearchParams(Object.entries(query).flatMap(([k, v]) => (v === undefined ? [] : [[k, String(v)]])))}`),
  // q: own search text instead of the book's title and author
  metadataCandidates: (bookId: number, q?: string) =>
    request<{ candidates: MetadataCandidate[] }>(`/api/books/${bookId}/metadata/candidates${q ? `?${new URLSearchParams({ q })}` : ""}`),
  progress: (bookId: number) => request<BookProgress>(`/api/books/${bookId}/progress`),
  // the reader's settings (lib/reader-settings.ts checks them)
  readerSettings: () => request<unknown>("/api/reader/settings"),
  // the newest position per book (bars on the covers); older hubs: none
  allProgress: () =>
    request<Pick<ProgressEntry, "bookId" | "fraction" | "format" | "updatedAt">[]>("/api/progress").catch((e) => {
      if (e instanceof ApiError && e.status === 404) return []
      throw e
    }),
  lists: () => request<ReadingList[]>("/api/lists"),
  list: (id: number) => request<ReadingList>(`/api/lists/${id}`),
  // not every hub has /api/config yet (#8391); fall back to the defaults
  config: () =>
    request<HubConfig>("/api/config").catch((e) => {
      if (e instanceof ApiError && e.status === 404) return DEFAULT_CONFIG
      throw e
    }),
}

export interface BookPatch {
  title?: string
  authors?: string[]
  series?: string | null
  seriesIndex?: number | null
  tags?: string[]
  addTags?: string[]
  removeTags?: string[]
  kategorie?: string | null
  comments?: string | null
  publisher?: string | null
  pubdate?: string | null // YYYY-MM-DD
  languages?: string[]
  rating?: number | null
  identifiers?: Record<string, string>
  // optimistic concurrency: 409 when the book changed since
  lastModified?: string
}

export interface BulkChanges {
  addTags?: string[]
  removeTags?: string[]
  kategorie?: string | null
  series?: string | null
  // with series and an ids target: volumes 1..n in the order of the ids
  numberSeries?: boolean
  authors?: string[]
  publisher?: string | null
  languages?: string[]
  // 0..10 (half stars), null: none
  rating?: number | null
  pubdate?: string | null
  // the year of the publication date, month and day stay
  pubYear?: number | null
  // moves the books to the trash; only on its own
  delete?: true
}

// A book in calibre's trash. id is the id it had; a restored book gets a new one.
export interface TrashEntry {
  id: number
  title: string
  authors: string[]
  formats: string[]
  deletedAt: string
}

// A query names "all matches" of a search: expect is the count the user was
// shown (the hub refuses with 409 when it matches another number, and a
// delete needs it), all: true says that a query without filters really means
// the whole library (the hub refuses it otherwise).
export type QueryTarget = { query: Omit<BookQuery, "offset" | "limit" | "sort" | "order">; expect?: number; all?: true }
export type BulkTarget = { ids: number[] } | QueryTarget

export interface Job {
  status: "running" | "done" | "failed"
  done: number
  total: number
  errors: { bookId: number; error: string }[]
  // why a job stopped early (e.g. the model is unavailable)
  error?: string
}

export interface EpubFixFinding {
  code: string
  file: string | null
  detail: string
}

// one run of the EPUB fixer with what it found per book
export interface EpubFixRun extends Job {
  id: string
  dryRun: boolean
  booksWithFixes: number
  booksWithProblems: number
  booksFixed: number
  fixes: Record<string, number>
  problems: Record<string, number>
  results: { bookId: number; title: string; applied: boolean; fixes: EpubFixFinding[]; problems: EpubFixFinding[] }[]
}

export interface CoverHit {
  url: string
  source: string
  width: number | null
  height: number | null
}

export interface UploadOptions {
  tags?: string[]
  kategorie?: string
  force?: boolean
  addFormatTo?: number
}

// What came of an upload. checking: the analysis or a decision is at it;
// waiting: in the Eingang, below the threshold; duplicate: in the Eingang,
// looks like a book of the library; copy: the same file is in the library;
// possibleDuplicates: books the hub's own detection pairs with the new one
export interface UploadState {
  id: string
  name: string
  status: "checking" | "waiting" | "duplicate" | "copy" | "imported" | "formatAdded" | "trashed" | "gone"
  entryId?: number
  confidence?: number | null
  threshold?: number | null
  error?: string | null
  book?: Book | null
  duplicates?: Book[]
  titles?: string[]
  possibleDuplicates?: Book[]
}

// a format goes straight to its book, a new book into the Eingang
export type UploadResult = { status: "added"; book: Book } | { status: "staged"; upload: UploadState }

const json = (body: unknown): RequestInit => ({ body: JSON.stringify(body) })

// books to add to or remove from a list
export type ListBooks = { bookIds: number[] } | { target: BulkTarget }
// the list afterwards and the books that were new in it, or left it
export interface ListChange {
  list: ReadingList
  added?: number[]
  removed?: number[]
}

// a change of private tags: the books it changed
export interface PrivateTagsChange {
  total: number
  changed: number[]
}

export const write = {
  // the Eingang: entries by id (one entry's accept with a candidate or edited
  // values), or all of a filter
  intakeDecide: (body: {
    decision: IntakeDecision
    target: { ids: number[] } | { query: IntakeFilter; last: number; expect: number }
    // a format's book
    book?: number
    candidate?: number
    // a filter's accept: the candidates chosen so far, by entry
    picks?: Record<number, number>
    title?: string
    authors?: string[]
  }) => request<{ jobId?: string | null; total: number }>("/api/intake/decide", { method: "POST", ...json(body) }),
  intakeThreshold: (origin: IntakeOrigin, value: number | null) => request<{ thresholds: IntakeList["thresholds"] }>("/api/intake/threshold", { method: "POST", ...json({ origin, value }) }),
  // the books no plan got to, behind the analysis
  recheckLibrary: () => request<{ books: number }>("/api/import/repair/recheck", { method: "POST", ...json({}) }),
  // the user's private tags: add and/or remove on books
  privateTags: (target: BulkTarget, change: { add?: string[]; remove?: string[] }) =>
    request<PrivateTagsChange>("/api/private-tags", { method: "POST", ...json({ target, ...change }) }),
  // one book's private tags become these
  setPrivateTags: (bookId: number, tags: string[]) =>
    request<{ bookId: number; privateTags: string[] }>(`/api/books/${bookId}/private-tags`, { method: "PUT", ...json({ tags }) }),
  // keepalive: also when the page is closing
  saveProgress: (bookId: number, p: ProgressSave, keepalive = false) =>
    request<ProgressEntry>(`/api/books/${bookId}/progress`, { method: "PUT", keepalive, ...json(p) }),
  // only the given fields change; returns all of them
  saveReaderSettings: (patch: Partial<ReaderSettings>, keepalive = false) =>
    request<unknown>("/api/reader/settings", { method: "PUT", keepalive, ...json(patch) }),
  createList: (list: ListPatch & { name: string }) => request<ReadingList>("/api/lists", { method: "POST", ...json(list) }),
  updateList: (id: number, patch: ListPatch) => request<ReadingList>(`/api/lists/${id}`, { method: "PATCH", ...json(patch) }),
  deleteList: (id: number) => request<{ list: ReadingList }>(`/api/lists/${id}`, { method: "DELETE" }),
  addToList: (id: number, books: ListBooks) => request<ListChange>(`/api/lists/${id}/books`, { method: "POST", ...json(books) }),
  removeFromList: (id: number, books: ListBooks) => request<ListChange>(`/api/lists/${id}/books/remove`, { method: "POST", ...json(books) }),
  patchBook: (id: number, patch: BookPatch) => request<Book>(`/api/books/${id}`, { method: "PATCH", ...json(patch) }),
  // into calibre's trash; returns the book as it was
  deleteBook: (id: number) => request<{ book: Book }>(`/api/books/${id}`, { method: "DELETE" }),
  restore: (trashId: number) => request<{ book: Book; warning?: string }>(`/api/trash/${trashId}/restore`, { method: "POST" }),
  bulk: (target: BulkTarget, changes: BulkChanges) =>
    request<{ jobId: string; total: number }>("/api/books/bulk", { method: "POST", ...json({ target, changes }) }),
  job: (id: string) => request<Job>(`/api/jobs/${id}`),
  // puts back what a finished bulk field change overwrote, as a new job (once)
  undoJob: (id: string) => request<{ jobId: string; total: number }>(`/api/jobs/${id}/undo`, { method: "POST" }),
  // category: another one than suggested, path or dotted
  acceptSuggestion: (bookId: number, category?: string) =>
    request<Suggestion>(`/api/suggestions/${bookId}/accept`, { method: "POST", ...json(category ? { category } : {}) }),
  rejectSuggestion: (bookId: number) => request<Suggestion>(`/api/suggestions/${bookId}/reject`, { method: "POST" }),
  acceptSuggestions: (bookIds: number[]) =>
    request<{ accepted: Suggestion[]; errors: { bookId: number; error: string }[] }>("/api/suggestions/accept", { method: "POST", ...json({ bookIds }) }),
  // 409 with {categories, minCategories} while the tree is too small
  classify: (target: ClassifyTarget) => request<{ jobId: string; total: number }>("/api/classify", { method: "POST", ...json({ target }) }),
  // converts every book (or those of books) without the target format (default: the configured one)
  convert: (target?: string, books?: BulkTarget) =>
    request<{ jobId: string; total: number }>("/api/convert", { method: "POST", ...json({ ...(target ? { target } : {}), ...(books ? { books } : {}) }) }),
  // the EPUB fixer over the library or some books; a dry run only checks
  epubFix: (dryRun: boolean, target?: BulkTarget) =>
    request<{ jobId: string; total: number; dryRun: boolean }>("/api/epub-fix", { method: "POST", ...json(target ? { dryRun, target } : { dryRun }) }),
  epubFixRun: (jobId: string) => request<EpubFixRun>(`/api/epub-fix/jobs/${jobId}`),
  metadataRun: (target: MetadataTarget = "incomplete") =>
    request<{ jobId: string; total: number }>("/api/metadata/run", { method: "POST", ...json({ target }) }),
  // 409 {error, book} when the field was changed in the meantime
  revertMetadataChange: (id: number) => request<{ change: MetadataChange; book: Book }>(`/api/metadata/changes/${id}/revert`, { method: "POST" }),
  // by book: all active changes of those books
  revertMetadataChanges: (target: { bookIds?: number[]; changeIds?: number[] }) =>
    request<{ reverted: MetadataChange[]; errors: { changeId: number; bookId: number; error: string }[] }>("/api/metadata/changes/revert", {
      method: "POST",
      ...json(target),
    }),
  coverUpload: (id: number, image: Blob) =>
    request<Book>(`/api/books/${id}/cover`, { method: "PUT", body: image, headers: { "Content-Type": image.type || "image/jpeg" } }),
  coverFromFile: (id: number, format?: string) =>
    request<Book>(`/api/books/${id}/cover/from-file`, { method: "POST", ...json({ format }) }),
  coverFromUrl: (id: number, url: string) => request<Book>(`/api/books/${id}/cover/from-url`, { method: "POST", ...json({ url }) }),
  // q overrides the default (title, first author, ISBN)
  coverSearch: (id: number, q?: string) =>
    request<CoverHit[]>(`/api/books/${id}/cover/search${q ? `?${new URLSearchParams({ q })}` : ""}`),
}

// XHR instead of fetch for upload progress.
export function uploadBook(file: File, opts: UploadOptions, onProgress: (fraction: number) => void, signal?: AbortSignal): Promise<UploadResult> {
  return new Promise((resolve, reject) => {
    const form = new FormData()
    form.append("file", file)
    opts.tags?.forEach((t) => form.append("tags", t))
    if (opts.kategorie) form.append("kategorie", opts.kategorie)
    if (opts.force) form.append("force", "1")
    if (opts.addFormatTo != null) form.append("addFormatTo", String(opts.addFormatTo))
    const xhr = new XMLHttpRequest()
    xhr.open("POST", "/api/books")
    xhr.setRequestHeader("X-Calibre-Hub", "1")
    xhr.upload.onprogress = (e) => e.lengthComputable && onProgress(e.loaded / e.total)
    xhr.onerror = () => reject(new ApiError(0, "network error"))
    xhr.onabort = () => reject(new DOMException("aborted", "AbortError"))
    xhr.onload = () => {
      const body = (() => {
        try {
          return JSON.parse(xhr.responseText)
        } catch {
          return null
        }
      })()
      if (xhr.status === 202) resolve({ status: "staged", upload: body.upload })
      else if (xhr.status === 200) resolve({ status: "added", book: body.book })
      else reject(new ApiError(xhr.status, body?.error ?? xhr.statusText))
    }
    signal?.addEventListener("abort", () => xhr.abort())
    xhr.send(form)
  })
}

export const DEFAULT_CONFIG: HubConfig = { categoryColumn: "kategorie", classify: false, metadata: false }

export const coverUrl = (id: number, thumb = true, version?: string) =>
  `/api/books/${id}/cover${thumb ? "?size=thumb" : ""}${version ? `${thumb ? "&" : "?"}v=${encodeURIComponent(version)}` : ""}`

// first=1: a look is enough, the hub may send only the first pages
export const intakeFileUrl = (id: number, format: string) => `/api/intake/${id}/file?format=${format}&first=1`
// how many pages the hub sent when that isn't the whole book
export const EXCERPT_HEADER = "X-Hub-Excerpt-Pages"
export const downloadUrl = (id: number, format: string) => `/api/books/${id}/download/${format.toLowerCase()}`

export function categoryOf(book: Book, column: string | null): string | null {
  if (!column) return null
  const v = book.custom[column]
  return typeof v === "string" && v ? v : null
}
