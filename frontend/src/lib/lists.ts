import { useRef, useSyncExternalStore, type MouseEvent, type PointerEvent } from "react"
import { queryOptions, useMutation, useQueryClient, type Query, type QueryClient } from "@tanstack/react-query"
import { api, write, type Book, type BookPage, type BookQuery, type BulkTarget, type ListPatch, type ReadingList } from "./api"

// Reading lists: queries, mutations and the "Speichern" dialog store.

export const listsQuery = queryOptions({
  queryKey: ["lists"],
  queryFn: api.lists,
  staleTime: 60_000,
})

export const listQuery = (id: number) =>
  queryOptions({
    queryKey: ["list", id],
    queryFn: () => api.list(id),
    staleTime: 30_000,
  })

// The list the bookmark on the cover saves to
export const defaultList = (lists: ReadingList[] | undefined) => lists?.find((l) => l.isDefault && l.editable)

// The list books were added to last ("in zuletzt benutzte Liste")
export function lastUsedList(lists: ReadingList[] | undefined): ReadingList | undefined {
  return lists
    ?.filter((l) => l.editable && l.lastUsedAt)
    .sort((a, b) => b.lastUsedAt!.localeCompare(a.lastUsedAt!))[0]
}

export const inList = (book: Pick<Book, "lists">, listId: number) => !!book.lists?.includes(listId)

// Favorites first, then by name (the API's order for own lists)
export const sortLists = (lists: ReadingList[]) =>
  [...lists].sort((a, b) => Number(b.favorite) - Number(a.favorite) || a.name.localeCompare(b.name, "de", { sensitivity: "base" }))

function patchBookLists(qc: QueryClient, ids: Set<number>, listId: number, on: boolean) {
  const fn = (b: Book): Book => {
    if (!ids.has(b.id)) return b
    const lists = b.lists ?? []
    return { ...b, lists: on ? [...new Set([...lists, listId])] : lists.filter((l) => l !== listId) }
  }
  ids.forEach((id) => qc.setQueryData<Book>(["book", id], (b) => b && fn(b)))
  qc.setQueriesData<BookPage>({ queryKey: ["books"] }, (page) => page && { ...page, books: page.books.map(fn) })
}

export function storeList(qc: QueryClient, list: ReadingList) {
  qc.setQueryData(["list", list.id], list)
  qc.setQueryData<ReadingList[]>(["lists"], (all) => {
    if (!all) return all
    // one default list: setting it takes it from the others
    const others = all.filter((l) => l.id !== list.id).map((l) => (list.isDefault && l.isDefault && l.owner === list.owner ? { ...l, isDefault: false } : l))
    return sortLists([...others, list])
  })
}

// The pages of a list change when books come or go
const listPages = (listId: number) => ({
  queryKey: ["books"],
  predicate: (q: Query) => (q.queryKey[1] as BookQuery | undefined)?.list === listId,
})

// Adds or removes books of one list. Optimistic on the books' `lists`.
export function useListMembership() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ list, bookIds, on }: { list: ReadingList; bookIds: number[]; on: boolean }) =>
      on ? write.addToList(list.id, { bookIds }) : write.removeFromList(list.id, { bookIds }),
    onMutate: ({ list, bookIds, on }) => patchBookLists(qc, new Set(bookIds), list.id, on),
    onError: (_e, { list, bookIds, on }) => patchBookLists(qc, new Set(bookIds), list.id, !on),
    onSuccess: (r, { list }) => {
      storeList(qc, r.list)
      qc.invalidateQueries(listPages(list.id))
    },
  })
}

// Bulk: the selected books (ids or all matches of the search)
export function useBulkList() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ listId, target, remove }: { listId: number; target: BulkTarget; remove?: boolean }) =>
      remove ? write.removeFromList(listId, { target }) : write.addToList(listId, { target }),
    onSuccess: (r, { listId }) => {
      storeList(qc, r.list)
      const changed = new Set(r.added ?? r.removed ?? [])
      patchBookLists(qc, changed, listId, !!r.added)
      qc.invalidateQueries(listPages(listId))
    },
  })
}

export function useCreateList() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (list: ListPatch & { name: string }) => write.createList(list),
    onSuccess: (list) => {
      storeList(qc, list)
      qc.invalidateQueries({ queryKey: ["lists"] })
    },
  })
}

export function useUpdateList() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ id, patch }: { id: number; patch: ListPatch }) => write.updateList(id, patch),
    onSuccess: (list) => {
      storeList(qc, list)
      qc.invalidateQueries({ queryKey: ["lists"] })
    },
  })
}

export function useDeleteList() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: number) => write.deleteList(id),
    onSuccess: (_r, id) => {
      qc.setQueryData<ReadingList[]>(["lists"], (all) => all?.filter((l) => l.id !== id))
      qc.removeQueries({ queryKey: ["list", id] })
      qc.invalidateQueries({ queryKey: ["lists"] })
      qc.invalidateQueries({ queryKey: ["books"] })
      qc.invalidateQueries({ queryKey: ["book"] })
    },
  })
}

// The "Speichern" dialog, opened from covers, the detail and the palette
let saving: Book | null = null
const listeners = new Set<() => void>()
export const saveDialog = {
  open: (book: Book) => {
    saving = book
    listeners.forEach((l) => l())
  },
  close: () => {
    saving = null
    listeners.forEach((l) => l())
  },
}

export function useSaveDialog(): Book | null {
  return useSyncExternalStore(
    (l) => {
      listeners.add(l)
      return () => listeners.delete(l)
    },
    () => saving,
  )
}

// Long press (touch, pen) or right click; the click that ends a long press
// is swallowed (check consumed() in onClick)
export function useLongPress(onLong: () => void, ms = 500) {
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined)
  const fired = useRef(false)
  const cancel = () => clearTimeout(timer.current)
  return {
    handlers: {
      onPointerDown: (e: PointerEvent) => {
        if (e.button !== 0) return
        fired.current = false
        cancel()
        timer.current = setTimeout(() => {
          fired.current = true
          onLong()
        }, ms)
      },
      onPointerUp: cancel,
      onPointerLeave: cancel,
      onPointerCancel: cancel,
      onContextMenu: (e: MouseEvent) => {
        e.preventDefault()
        e.stopPropagation()
        cancel()
        if (!fired.current) onLong()
        fired.current = true
      },
    },
    // true: this click ended a long press, ignore it
    consumed: () => {
      const was = fired.current
      fired.current = false
      return was
    },
  }
}
