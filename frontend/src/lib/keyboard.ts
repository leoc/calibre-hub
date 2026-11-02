import { useSyncExternalStore } from "react"
import { load, save } from "./storage"
import { defaultBindings, diffOverrides, MODES, parseOverrides, withOverrides, type Bindings, type KeyMode } from "./keymap"

// Keyboard state shared by the key handler, the library and the settings:
// the mode (per device), the active book, visual mode and what has been
// typed towards the next command (status line).

export interface KeyState {
  mode: KeyMode
  // the book with the focus ring; null until the first key press
  active: number | null
  // visual mode: the book it started on and the selection before it
  visual: { anchor: number; base: number[] } | null
  // count or sequence typed so far ("3", "g")
  pending: string
  // own bindings per mode (settings), on top of the defaults
  overrides: Record<KeyMode, Bindings>
  // help overlay or the bindings settings
  panel: "help" | "settings" | null
  // a short message in the status line ("Link kopiert")
  flash: string | null
}

const MODE_KEY = "hub.keys"
// own bindings: hub.keymap.app, hub.keymap.vim (JSON, see README)
const mapKey = (mode: KeyMode) => `hub.keymap.${mode}`
const loadOverrides = (mode: KeyMode) => {
  try {
    return parseOverrides(localStorage.getItem(mapKey(mode)))
  } catch {
    return {}
  }
}

let state: KeyState = {
  mode: load(MODE_KEY, MODES, "app"),
  active: null,
  visual: null,
  pending: "",
  overrides: { app: loadOverrides("app"), vim: loadOverrides("vim") },
  panel: null,
  flash: null,
}
let flashTimer: ReturnType<typeof setTimeout> | undefined
const listeners = new Set<() => void>()
const set = (patch: Partial<KeyState>) => {
  state = { ...state, ...patch }
  listeners.forEach((l) => l())
}

const subscribe = (l: () => void) => {
  listeners.add(l)
  return () => {
    listeners.delete(l)
  }
}

export const keyboard = {
  get: () => state,
  subscribe,
  setMode(mode: KeyMode) {
    save(MODE_KEY, mode)
    set({ mode, visual: null, pending: "" })
  },
  setActive: (active: number | null) => state.active !== active && set({ active }),
  setVisual: (visual: KeyState["visual"]) => set({ visual }),
  setPending: (pending: string) => state.pending !== pending && set({ pending }),
  setPanel: (panel: KeyState["panel"]) => set({ panel }),
  // what the keys of a mode do now: defaults plus own bindings
  bindings: (mode: KeyMode = state.mode) => withOverrides(defaultBindings(mode), state.overrides[mode]),
  setBindings(mode: KeyMode, wanted: Bindings) {
    const overrides = diffOverrides(defaultBindings(mode), wanted)
    save(mapKey(mode), JSON.stringify(overrides))
    set({ overrides: { ...state.overrides, [mode]: overrides } })
  },
  flash(message: string) {
    clearTimeout(flashTimer)
    set({ flash: message })
    flashTimer = setTimeout(() => set({ flash: null }), 2500)
  },
}

export function useKeyboard(): KeyState {
  return useSyncExternalStore(subscribe, () => state)
}

// --- the library's part -------------------------------------------------------

// What the key handler hands to the library page; the page answers whether
// it used the action.
export type ListHandler = (action: string, count: number | null, e: KeyboardEvent) => boolean
let list: ListHandler | null = null
export function registerList(handler: ListHandler) {
  list = handler
  return () => {
    if (list === handler) list = null
  }
}
export const runListAction: ListHandler = (action, count, e) => list?.(action, count, e) ?? false

// After a search or a page change: which book becomes active once the new
// results are there (`when` tells them apart from the old ones).
export interface PendingActivation {
  at: "first"
  focus: boolean
  when: (search: { q?: string; page?: number }) => boolean
}
let activation: PendingActivation | null = null
const activationListeners = new Set<() => void>()
export function activateWhenLoaded(p: PendingActivation | null) {
  activation = p
  activationListeners.forEach((l) => l())
}
export function usePendingActivation(): PendingActivation | null {
  return useSyncExternalStore(
    (l) => {
      activationListeners.add(l)
      return () => activationListeners.delete(l)
    },
    () => activation,
  )
}

// The book's element in the grid or list
export const bookElement = (id: number) => document.querySelector<HTMLElement>(`[data-book-id="${id}"]`)

// Give the active book the real focus (screen readers announce it).
export function focusActive(): boolean {
  const id = state.active
  const el = id != null ? bookElement(id) : null
  if (!el) return false
  el.focus()
  return true
}

// The wide header search registers itself, "/" puts the focus there.
let searchFocus: (() => void) | null = null
export function registerSearchFocus(fn: () => void) {
  searchFocus = fn
  return () => {
    if (searchFocus === fn) searchFocus = null
  }
}
export const focusSearch = (): boolean => (searchFocus ? (searchFocus(), true) : false)
