import { useQuery, useQueryClient, type QueryClient } from "@tanstack/react-query"
import { useRouterState } from "@tanstack/react-router"
import { DEFAULT_CONFIG, type Book, type BookPage } from "./api"
import type { ActionTarget } from "./book-actions"
import { useKeyboard } from "./keyboard"
import { booksQuery, configQuery } from "./queries"
import { bulkTarget, toBookQuery } from "./search"
import { useSelection } from "./selection"
import { useLibrarySearch } from "./use-library"

// A book as the library or the detail has it loaded
export function cachedBook(qc: QueryClient, id: number): Book | undefined {
  return (
    qc.getQueryData<Book>(["book", id]) ??
    qc
      .getQueriesData<BookPage>({ queryKey: ["books"] })
      .flatMap(([, p]) => p?.books ?? [])
      .find((b) => b.id === id)
  )
}

// What the commands on books act on: the selection (ids in the order they
// were selected, or all matches as in the bulk bar), else the active book
// (focus ring), else the book open in the detail; null without any.
export function useActionTarget(enabled = true): ActionTarget | null {
  const qc = useQueryClient()
  const search = useLibrarySearch()
  const sel = useSelection()
  const { active } = useKeyboard()
  const { data: config = DEFAULT_CONFIG } = useQuery(configQuery)
  const pathname = useRouterState({ select: (s) => s.location.pathname })
  const onLibrary = pathname === "/"
  const { data: matches } = useQuery({ ...booksQuery(toBookQuery(search, config.categoryColumn)), enabled: enabled && sel.all && onLibrary })
  // the book open in the detail (?book= or /books/:id)
  const pageBook = /^\/books\/(\d+)/.exec(pathname)?.[1]
  const openId = search.book ?? (pageBook ? Number(pageBook) : null)

  if (onLibrary && sel.active && (sel.all || sel.ids.size)) {
    // the count decides whether to ask first: none until it is known
    if (sel.all) return matches ? { bulk: bulkTarget(search, config.categoryColumn), count: matches.total, ordered: false } : null
    const ids = [...sel.ids]
    const book = ids.length === 1 ? cachedBook(qc, ids[0]) : undefined
    return { bulk: { ids }, count: ids.length, ordered: true, ...(book ? { book } : {}) }
  }
  for (const id of [onLibrary ? active : null, openId]) {
    const book = id != null ? cachedBook(qc, id) : undefined
    if (book) return { bulk: { ids: [book.id] }, count: 1, book, ordered: true }
  }
  return null
}
