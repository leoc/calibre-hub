import { useMutation, useQueryClient, type QueryClient } from "@tanstack/react-query"
import { ApiError, write, type Book, type BookPage, type BookPatch, type ClassifyTarget, type MetadataTarget } from "./api"

// Put a changed book into every cached list and its detail entry.
// Writes answer without the book's lists; those stay as cached.
export function storeBook(qc: QueryClient, book: Book) {
  qc.setQueryData<Book>(["book", book.id], (old) => ({ ...book, comments: book.comments ?? old?.comments, lists: book.lists ?? old?.lists }))
  qc.setQueriesData<BookPage>({ queryKey: ["books"] }, (page) =>
    page && { ...page, books: page.books.map((b) => (b.id === book.id ? { ...book, comments: undefined, lists: book.lists ?? b.lists } : b)) },
  )
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

// Metadata changes: reverts change books (fields, the auto-metadaten tag)
export function invalidateMetadata(qc: QueryClient, bookIds?: number[]) {
  qc.invalidateQueries({ queryKey: ["metadata-changes"] })
  qc.invalidateQueries({ queryKey: ["metadata-status"] })
  if (bookIds) bookIds.forEach((id) => qc.invalidateQueries({ queryKey: ["book", id] }))
  else qc.invalidateQueries({ queryKey: ["book"] })
  qc.invalidateQueries({ queryKey: ["books"] })
  qc.invalidateQueries({ queryKey: ["categories"] })
}

export function useStartMetadataRun() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (target: MetadataTarget) => write.metadataRun(target),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["metadata-status"] }),
  })
}

export class RevertConflictError extends Error {
  constructor(public current: Book | null) {
    super("changed in the meantime")
  }
}

export function useRevertMetadataChange() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (id: number) => {
      try {
        return await write.revertMetadataChange(id)
      } catch (e) {
        if (e instanceof ApiError && e.status === 409) throw new RevertConflictError((e.body?.book as Book | undefined) ?? null)
        throw e
      }
    },
    onSuccess: ({ book }) => {
      storeBook(qc, book)
      invalidateMetadata(qc, [book.id])
    },
    // a conflict means the book changed: show its current state
    onError: () => invalidateMetadata(qc),
  })
}

export function useRevertMetadataChanges() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (target: { bookIds?: number[]; changeIds?: number[] }) => write.revertMetadataChanges(target),
    // failed ones may have changed as well
    onSuccess: () => invalidateMetadata(qc),
  })
}
