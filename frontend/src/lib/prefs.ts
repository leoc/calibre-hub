import { useSyncExternalStore } from "react"
import { load, save } from "./storage"

export const VIEWS = ["grid", "list"] as const
export type View = (typeof VIEWS)[number]

// Grid or list is a per-device preference, not part of the URL; shared
// between the toolbar and the command palette.
let view: View = load("hub.view", VIEWS, "grid")
const listeners = new Set<() => void>()

export function setView(v: View) {
  view = v
  save("hub.view", v)
  listeners.forEach((l) => l())
}

export function useView(): View {
  return useSyncExternalStore(
    (l) => {
      listeners.add(l)
      return () => listeners.delete(l)
    },
    () => view,
  )
}
