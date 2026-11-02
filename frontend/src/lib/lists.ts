import { useMemo, useRef, useSyncExternalStore, type MouseEvent, type PointerEvent } from "react"
import { queryOptions, useMutation, useQuery, useQueryClient, type Query, type QueryClient } from "@tanstack/react-query"
import { formatNumber, t } from "@/i18n"
import { toast } from "./toast"
import { sessionQuery } from "./queries"
import { api, ApiError, write, type Book, type BookPage, type BookQuery, type BulkTarget, type ListChange, type ListPatch, type ReadingList } from "./api"
import { isShelf } from "./shelves"

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

// Lists books can be saved to: editable, no magic shelf (its rule finds its books)
export const savable = (l: ReadingList) => l.editable && !isShelf(l)
export const savableLists = (lists: ReadingList[] | undefined) => lists?.filter(savable) ?? []

// The list the bookmark on the cover saves to
export const defaultList = (lists: ReadingList[] | undefined) => lists?.find((l) => l.isDefault && savable(l))

// The list books were added to last ("in zuletzt benutzte Liste")
export function lastUsedList(lists: ReadingList[] | undefined): ReadingList | undefined {
  return lists
    ?.filter((l) => savable(l) && l.lastUsedAt)
    .sort((a, b) => b.lastUsedAt!.localeCompare(a.lastUsedAt!))[0]
}

export const inList = (book: Pick<Book, "lists">, listId: number) => !!book.lists?.includes(listId)

// Favorites first, then by name (the API's order for own lists)
export const sortLists = (lists: ReadingList[]) =>
  [...lists].sort((a, b) => Number(b.favorite) - Number(a.favorite) || a.name.localeCompare(b.name, "de", { sensitivity: "base" }))

// --- nested lists -------------------------------------------------------------
// A list's name is its path, "Urlaub/2026" is the sublist 2026 of Urlaub (per
// owner). A level without a list of that name is just a folder in the tree.
// Shown as a path wherever a list stands alone (palette, badges, toasts) and
// as the last level inside the tree.

export const listLevels = (name: string) =>
  name
    .split("/")
    .map((s) => s.trim())
    .filter(Boolean)
export const listLabel = (l: Pick<ReadingList, "name"> | string) => listLevels(typeof l === "string" ? l : l.name).join("/")
export const listLeaf = (l: Pick<ReadingList, "name"> | string) => listLevels(typeof l === "string" ? l : l.name).at(-1) ?? ""
// the path above it, "" at the top
export const listParent = (name: string) => listLevels(name).slice(0, -1).join("/")
const fold = (path: string) => listLabel(path).toLowerCase()
// name lies below path ("Urlaub/2026" below "Urlaub")
export const isBelow = (path: string, name: string) => fold(name).startsWith(`${fold(path)}/`)

export interface ListNode {
  // owner + path, unique in the tree
  key: string
  path: string
  // the last level
  name: string
  owner: string
  depth: number
  // null: a level without a list of its own
  list: ReadingList | null
  children: ListNode[]
}

const byFavoriteThenName = (a: ListNode, b: ListNode) =>
  Number(!!b.list?.favorite) - Number(!!a.list?.favorite) || a.name.localeCompare(b.name, "de", { sensitivity: "base", numeric: true })

// The lists as a tree per owner, the user's own first (others' lists keep
// their own tree); siblings favorites first, then by name
export function buildListTree(lists: ReadingList[], user?: string): ListNode[] {
  const roots: ListNode[] = []
  const nodes = new Map<string, ListNode>()
  const owners = [...new Set(lists.map((l) => l.owner))].sort((a, b) => Number(b === user) - Number(a === user))
  for (const owner of owners) {
    const own = lists.filter((l) => l.owner === owner).sort((a, b) => listLevels(a.name).length - listLevels(b.name).length)
    for (const l of own) {
      const levels = listLevels(l.name)
      let siblings = roots
      levels.forEach((level, i) => {
        const path = levels.slice(0, i + 1).join("/")
        const key = `${owner}\u0000${path.toLowerCase()}`
        let node = nodes.get(key)
        if (!node) {
          node = { key, path, name: level, owner, depth: i, list: null, children: [] }
          nodes.set(key, node)
          siblings.push(node)
        }
        if (i === levels.length - 1) node.list = l
        siblings = node.children
      })
    }
  }
  const sort = (ns: ListNode[]): ListNode[] => {
    ns.sort(byFavoriteThenName)
    ns.forEach((n) => sort(n.children))
    return ns
  }
  // owners stay in their order, each one's roots sorted
  return owners.flatMap((o) => sort(roots.filter((r) => r.owner === o)))
}

export const flattenListTree = (nodes: ListNode[]): ListNode[] => nodes.flatMap((n) => [n, ...flattenListTree(n.children)])

// Favorites as they show in the sidebar: a favorite with its sublists; a
// favorite below another one only inside it
export function favoriteTree(nodes: ListNode[]): ListNode[] {
  return nodes.flatMap((n) => (n.list?.favorite ? [n] : favoriteTree(n.children)))
}

// Books of a node: incl. its sublists; a level without a list of its own
// has none itself
export const nodeCount = (n: ListNode): number | undefined => (n.list ? (n.list.totalCount ?? n.list.count) : undefined)

// The library search that opens a node
export const nodeSearch = (n: Pick<ListNode, "list" | "path" | "owner">, user?: string) =>
  n.list ? { list: n.list.id } : { listPath: n.path, listOwner: user && n.owner !== user ? n.owner : undefined }

// The node a list page shows (search.list or search.listPath)
export function findNode(nodes: ListNode[], search: { list?: number; listPath?: string; listOwner?: string }, user?: string): ListNode | undefined {
  const all = flattenListTree(nodes)
  if (search.list != null) return all.find((n) => n.list?.id === search.list)
  if (!search.listPath) return undefined
  const owner = search.listOwner ?? user
  return all.find((n) => fold(n.path) === fold(search.listPath!) && (!owner || n.owner === owner))
}

// The lists as a tree (listsQuery), with the user for others' trees
export function useListTree(enabled = true) {
  const { data: lists, ...rest } = useQuery({ ...listsQuery, enabled })
  const { data: session } = useQuery(sessionQuery)
  const user = session?.user
  const tree = useMemo(() => (lists ? buildListTree(lists, user) : undefined), [lists, user])
  return { lists, tree, user, ...rest }
}

// The levels above a node and the node itself, for the breadcrumb
export function nodeTrail(nodes: ListNode[], node: ListNode): ListNode[] {
  const all = flattenListTree(nodes).filter((n) => n.owner === node.owner)
  const levels = listLevels(node.path)
  return levels.map((_, i) => all.find((n) => fold(n.path) === fold(levels.slice(0, i + 1).join("/")))!).filter(Boolean)
}

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
  // the levels above count its books too
  if (list.parent) qc.invalidateQueries({ queryKey: ["lists"], exact: true })
}

// The pages of a list change when books come or go, and so do those of
// the levels above it
const listPages = (_listId: number) => ({
  queryKey: ["books"],
  predicate: (q: Query) => {
    const k = q.queryKey[1] as BookQuery | undefined
    return k?.list != null || !!k?.listPath
  },
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
    // a fetch of the book still running at the click answers without it
    onSettled: (_r, _e, { bookIds }) => bookIds.forEach((id) => qc.invalidateQueries({ queryKey: ["book", id], exact: true })),
  })
}

// After books came into a list or left it: the list, the books' badges and
// the pages that show it
export function afterListChange(qc: QueryClient, listId: number, r: ListChange) {
  storeList(qc, r.list)
  const changed = new Set(r.added ?? r.removed ?? [])
  patchBookLists(qc, changed, listId, !!r.added)
  qc.invalidateQueries(listPages(listId))
}

// Adds or removes books (ids or all matches of a search), outside of a hook
// (the command palette closes before the answer)
export async function changeList(qc: QueryClient, listId: number, target: BulkTarget, remove = false): Promise<ListChange> {
  const books = "ids" in target ? { bookIds: target.ids } : { target }
  const r = await (remove ? write.removeFromList(listId, books) : write.addToList(listId, books))
  afterListChange(qc, listId, r)
  return r
}

// Bulk: the selected books (ids or all matches of the search)
export function useBulkList() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ listId, target, remove }: { listId: number; target: BulkTarget; remove?: boolean }) =>
      remove ? write.removeFromList(listId, { target }) : write.addToList(listId, { target }),
    onSuccess: (r, { listId }) => afterListChange(qc, listId, r),
  })
}

// "3 zu Urlaub hinzugefügt · Rückgängig": takes exactly the added books out again
export function offerUndoAdd(qc: QueryClient, list: Pick<ReadingList, "id" | "name">, added: number[]) {
  const name = listLabel(list)
  const text = t("actions.listAdded", { count: formatNumber(added.length), name })
  if (!added.length) return void toast.show(text)
  toast.show(text, {
    label: t("toast.undo"),
    run: () =>
      void changeList(qc, list.id, { ids: added }, true).catch((e: unknown) => toast.show(t("list.undoFailed", { error: e instanceof ApiError ? e.message : String(e) }))),
  })
}

// The undo of a removal: puts exactly these books back. Outside of a hook,
// since the toast that offers it outlives the component that removed them.
export async function restoreToList(qc: QueryClient, listId: number, bookIds: number[]) {
  const r = await write.addToList(listId, { bookIds })
  storeList(qc, r.list)
  patchBookLists(qc, new Set(r.added ?? []), listId, true)
  qc.invalidateQueries(listPages(listId))
  return r
}

// "2 Bücher aus Urlaub entfernt · Rückgängig"
export function offerUndoRemove(qc: QueryClient, list: Pick<ReadingList, "id" | "name">, removed: number[]) {
  if (!removed.length) return
  const name = listLabel(list)
  const text = removed.length === 1 ? t("list.removedOne", { name }) : t("list.removedMany", { count: formatNumber(removed.length), name })
  toast.show(text, {
    label: t("toast.undo"),
    run: () =>
      void restoreToList(qc, list.id, removed).catch((e: unknown) => toast.show(t("list.undoFailed", { error: e instanceof ApiError ? e.message : String(e) }))),
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
    onSuccess: (list, { patch }) => {
      storeList(qc, list)
      // a new name renames the sublists too
      qc.invalidateQueries({ queryKey: ["lists"] })
      qc.invalidateQueries({ queryKey: ["list"] })
      // a shelf's new rule finds other books
      if (patch.rule) qc.invalidateQueries(listPages(list.id))
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
