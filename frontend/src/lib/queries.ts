import { keepPreviousData, queryOptions } from "@tanstack/react-query"
import { api, ApiError, type BookQuery, type MetadataChangesQuery, type SuggestionStatus } from "./api"
import { DEFAULT_READER_SETTINGS, normalize } from "./reader-settings"

export const sessionQuery = queryOptions({
  queryKey: ["session"],
  queryFn: api.session,
  staleTime: Infinity,
  retry: false,
})

export const configQuery = queryOptions({
  queryKey: ["config"],
  queryFn: api.config,
  staleTime: Infinity,
})

export const categoriesQuery = queryOptions({
  queryKey: ["categories"],
  queryFn: api.categories,
  staleTime: 5 * 60_000,
})

export const booksQuery = (query: BookQuery) =>
  queryOptions({
    queryKey: ["books", query],
    queryFn: () => api.books(query),
    placeholderData: keepPreviousData,
    staleTime: 30_000,
  })

export const bookQuery = (id: number) =>
  queryOptions({
    queryKey: ["book", id],
    queryFn: () => api.book(id),
    staleTime: 60_000,
  })

export const trashQuery = queryOptions({
  queryKey: ["trash"],
  queryFn: api.trash,
  staleTime: 0,
})

export const suggestionsQuery = (status: SuggestionStatus = "pending") =>
  queryOptions({
    queryKey: ["suggestions", status],
    queryFn: () => api.suggestions(status),
    staleTime: 0,
  })

export const suggestionQuery = (bookId: number) =>
  queryOptions({
    queryKey: ["suggestion", bookId],
    queryFn: () => api.suggestion(bookId),
    staleTime: 60_000,
  })

// polls while a run is going
export const classifyStatusQuery = queryOptions({
  queryKey: ["classify-status"],
  queryFn: api.classifyStatus,
  staleTime: 30_000,
  refetchInterval: (q) => (q.state.data?.running ? 1500 : false),
})

// polls while a run is going
export const metadataStatusQuery = queryOptions({
  queryKey: ["metadata-status"],
  queryFn: api.metadataStatus,
  staleTime: 30_000,
  refetchInterval: (q) => (q.state.data?.running ? 1500 : false),
})

// backlog import runs and cleanups; polls while one runs
export const importStatusQuery = queryOptions({
  queryKey: ["import-status"],
  queryFn: api.importStatus,
  staleTime: 30_000,
  refetchInterval: (q) =>
    q.state.data?.running || q.state.data?.cleanups.some((c) => c.job?.status === "running" || c.undoJob?.status === "running") ? 2000 : false,
})

export const metadataChangesQuery =(query: MetadataChangesQuery = {}) =>
  queryOptions({
    queryKey: ["metadata-changes", query],
    queryFn: () => api.metadataChanges(query),
    staleTime: 0,
  })

// reading positions of a book on every device; always fresh when the reader opens
export const progressQuery = (bookId: number) =>
  queryOptions({
    queryKey: ["progress", bookId],
    queryFn: () => api.progress(bookId),
    staleTime: 0,
  })

// the reader's settings, per account; an older hub without them: defaults
export const readerSettingsQuery = queryOptions({
  queryKey: ["reader-settings"],
  queryFn: () =>
    api.readerSettings().then(normalize, (e) => {
      if (e instanceof ApiError && e.status === 404) return DEFAULT_READER_SETTINGS
      throw e
    }),
  staleTime: 5 * 60_000,
})

// newest position per book, for the bars on the covers
export const allProgressQuery = queryOptions({
  queryKey: ["progress"],
  queryFn: api.allProgress,
  staleTime: 60_000,
  select: (rows) => new Map(rows.map((r) => [r.bookId, r.fraction])),
})

// asks Open Library and the DNB: slow, kept until the dialog asks again
export const metadataCandidatesQuery = (bookId: number, q: string) =>
  queryOptions({
    queryKey: ["metadata-candidates", bookId, q],
    queryFn: () => api.metadataCandidates(bookId, q || undefined),
    staleTime: 5 * 60_000,
    retry: false,
  })
