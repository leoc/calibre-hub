import { keepPreviousData, queryOptions } from "@tanstack/react-query"
import { api, type BookQuery } from "./api"

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
