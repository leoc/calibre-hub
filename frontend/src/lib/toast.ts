import { useSyncExternalStore } from "react"

// One short message at a time at the bottom of the screen, with an
// optional action ("Rückgängig"). A newer message replaces the older one.

export interface Toast {
  id: number
  text: string
  action?: { label: string; run: () => void }
}

export const TOAST_MS = 8000

let current: Toast | null = null
let nextId = 1
let timer: ReturnType<typeof setTimeout> | undefined
const listeners = new Set<() => void>()
const set = (t: Toast | null) => {
  current = t
  listeners.forEach((l) => l())
}

export const toast = {
  get: () => current,
  show(text: string, action?: Toast["action"], ms = TOAST_MS): number {
    clearTimeout(timer)
    const t = { id: nextId++, text, action }
    set(t)
    timer = setTimeout(() => current?.id === t.id && set(null), ms)
    return t.id
  },
  // without an id: whatever is shown
  dismiss(id?: number) {
    if (id != null && current?.id !== id) return
    clearTimeout(timer)
    set(null)
  },
}

export function useToast(): Toast | null {
  return useSyncExternalStore(
    (l) => {
      listeners.add(l)
      return () => listeners.delete(l)
    },
    () => current,
  )
}
