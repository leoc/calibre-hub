import { useMutation, useQueryClient, type QueryClient } from "@tanstack/react-query"
import { ApiError, write, type Book, type BookPage, type BookPatch, type ClassifyTarget } from "./api"

// Put a changed book into every cached list and its detail entry.
export function storeBook(qc: QueryClient, book: Book) {
  qc.setQueryData<Book>(["book", book.id], (old) => ({ ...book, comments: book.comments ?? old?.comments }))
  qc.setQueriesData<BookPage>({ queryKey: ["books"] }, (page) =>
    page && { ...page, books: page.books.map((b) => (b.id === book.id ? { ...book, comments: undefined } : b)) },
  )
}

function patchCached(qc: QueryClient, id: number, fn: (b: Book) => Book) {
  qc.setQueryData<Book>(["book", id], (b) => b && fn(b))
  qc.setQueriesData<BookPage>({ queryKey: ["books"] }, (page) => page && { ...page, books: page.books.map((b) => (b.id === id ? fn(b) : b)) })
}

export class ConflictError extends Error {
  constructor(public current: Book) {
    super("conflict")
  }
}

export function useUpdateBook(id: number) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (patch: BookPatch) => {
      try {
        return await write.patchBook(id, patch)
      } catch (e) {
        if (e instanceof ApiError && e.status === 409 && e.body?.book) throw new ConflictError(e.body.book as Book)
        throw e
      }
    },
    onSuccess: (book) => {
      storeBook(qc, book)
      // lists may be sorted or filtered by what changed
      qc.invalidateQueries({ queryKey: ["books"] })
      qc.invalidateQueries({ queryKey: ["categories"] })
    },
  })
}

// Fast tags: optimistic, only add/remove so concurrent edits survive.
export function useToggleTag() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ book, tag, on }: { book: Book; tag: string; on: boolean }) =>
      write.patchBook(book.id, on ? { addTags: [tag] } : { removeTags: [tag] }),
    onMutate: async ({ book, tag, on }) => {
      await qc.cancelQueries({ queryKey: ["book", book.id] })
      const toggle = (b: Book) => ({ ...b, tags: on ? [...new Set([...b.tags, tag])] : b.tags.filter((t) => t !== tag) })
      patchCached(qc, book.id, toggle)
    },
    onError: (_e, { book, tag, on }) => {
      patchCached(qc, book.id, (b) => ({ ...b, tags: on ? b.tags.filter((t) => t !== tag) : [...b.tags, tag] }))
    },
    onSuccess: (book) => storeBook(qc, book),
    onSettled: () => {
      qc.invalidateQueries({ queryKey: ["categories"] })
    },
  })
}

// Library views that change when books come or go
export function invalidateLibrary(qc: QueryClient) {
  qc.invalidateQueries({ queryKey: ["books"] })
  qc.invalidateQueries({ queryKey: ["categories"] })
  qc.invalidateQueries({ queryKey: ["trash"] })
}

export function useDeleteBook() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: number) => write.deleteBook(id),
    onSuccess: (_r, id) => {
      qc.removeQueries({ queryKey: ["book", id] })
      invalidateLibrary(qc)
    },
  })
}

// Suggestions change books (category, tag) and the review list
function invalidateSuggestions(qc: QueryClient, bookIds: number[]) {
  qc.invalidateQueries({ queryKey: ["suggestions"] })
  qc.invalidateQueries({ queryKey: ["classify-status"] })
  bookIds.forEach((id) => {
    qc.invalidateQueries({ queryKey: ["suggestion", id] })
    qc.invalidateQueries({ queryKey: ["book", id] })
  })
  qc.invalidateQueries({ queryKey: ["books"] })
  qc.invalidateQueries({ queryKey: ["categories"] })
}

export function useAcceptSuggestion() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ bookId, category }: { bookId: number; category?: string }) => write.acceptSuggestion(bookId, category),
    onSuccess: (_s, { bookId }) => invalidateSuggestions(qc, [bookId]),
  })
}

export function useRejectSuggestion() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (bookId: number) => write.rejectSuggestion(bookId),
    onSuccess: (_s, bookId) => invalidateSuggestions(qc, [bookId]),
  })
}

export function useAcceptSuggestions() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (bookIds: number[]) => write.acceptSuggestions(bookIds),
    onSuccess: (_r, bookIds) => invalidateSuggestions(qc, bookIds),
  })
}

export function useStartClassify() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (target: ClassifyTarget) => write.classify(target),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["classify-status"] }),
  })
}

export function useRestoreBook() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (trashId: number) => write.restore(trashId),
    onSuccess: ({ book }) => {
      storeBook(qc, book)
      invalidateLibrary(qc)
    },
  })
}
