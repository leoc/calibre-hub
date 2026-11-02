import { useSyncExternalStore } from "react"

// Selection for bulk edits: ids across pages, or "all matches of the search".
export interface Selection {
  active: boolean
  ids: Set<number>
  all: boolean
  anchor: number | null
}

let state: Selection = { active: false, ids: new Set(), all: false, anchor: null }
const listeners = new Set<() => void>()
const set = (patch: Partial<Selection>) => {
  state = { ...state, ...patch }
  listeners.forEach((l) => l())
}

export const selection = {
  get: () => state,
  start: () => set({ active: true }),
  stop: () => set({ active: false, ids: new Set(), all: false, anchor: null }),
  clear: () => set({ ids: new Set(), all: false, anchor: null }),
  selectAll: () => set({ all: true }),
  // shift: select the range from the last clicked book within `order`
  toggle(id: number, shift: boolean, order: number[]) {
    const ids = new Set(state.ids)
    if (shift && state.anchor != null && order.includes(state.anchor)) {
      const [a, b] = [order.indexOf(state.anchor), order.indexOf(id)].sort((x, y) => x - y)
      order.slice(a, b + 1).forEach((x) => ids.add(x))
    } else if (ids.has(id)) ids.delete(id)
    else ids.add(id)
    set({ ids, all: false, anchor: id })
  },
  addPage(order: number[]) {
    set({ ids: new Set([...state.ids, ...order]), all: false })
  },
  // keyboard: Shift+movement adds the books between `from` and `to`
  addRange(from: number, to: number, order: number[]) {
    const [a, b] = [order.indexOf(from), order.indexOf(to)].sort((x, y) => x - y)
    if (a < 0) return
    set({ ids: new Set([...state.ids, ...order.slice(a, b + 1)]), all: false, anchor: state.anchor ?? from })
  },
  // visual mode: what was selected before plus the range it spans
  replace(ids: number[]) {
    set({ active: true, ids: new Set(ids), all: false })
  },
}

// Bulk commands from elsewhere (the command palette) open the bulk bar's dialog.
export type BulkAction = "addTags" | "removeTags" | "kategorie" | "series" | "delete"
const bulkListeners = new Set<(a: BulkAction) => void>()
export function requestBulk(action: BulkAction) {
  bulkListeners.forEach((l) => l(action))
}
export function onBulkRequest(listener: (a: BulkAction) => void) {
  bulkListeners.add(listener)
  return () => {
    bulkListeners.delete(listener)
  }
}

export function useSelection(): Selection {
  return useSyncExternalStore(
    (l) => {
      listeners.add(l)
      return () => listeners.delete(l)
    },
    () => state,
  )
}
