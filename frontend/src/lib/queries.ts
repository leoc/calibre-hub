import { keepPreviousData, queryOptions } from "@tanstack/react-query"
import { api, type BookQuery, type SuggestionStatus } from "./api"

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
