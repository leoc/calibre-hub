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
