import { useEffect, useRef } from "react"

// Android's back button (and the browser's) closes an open dialog, sheet or
// palette instead of leaving the page: while one is open it owns a history
// entry with the same URL. Back pops that entry and closes the overlay;
// closing it any other way (X, Escape, done) removes the entry again.

interface Entry {
  key: string
  close: () => void
  // its history entry is already being removed
  leaving: boolean
}

const stack: Entry[] = []
let listening = false

type OverlayState = { __overlay?: string; __TSR_index?: number } | null
const currentKey = () => (history.state as OverlayState)?.__overlay

function onPop() {
  const key = currentKey()
  // every overlay above the entry we landed on was closed by Back
  const popped = stack.splice(stack.findIndex((e) => e.key === key) + 1)
  for (const e of popped.reverse()) {
    if (e.leaving) continue
    e.leaving = true
    e.close()
  }
}

export function useBackToClose(close: () => void, enabled = true) {
  const closeRef = useRef(close)
  useEffect(() => {
    closeRef.current = close
  })
  useEffect(() => {
    if (!enabled) return
    const entry: Entry = { key: Math.random().toString(36).slice(2), close: () => closeRef.current(), leaving: false }
    // deferred: StrictMode mounts twice, and a second push before the first
    // cleanup's back() has landed would pop the wrong entry
    const timer = setTimeout(() => {
      const state = (history.state as OverlayState) ?? {}
      // a new index tells the router this is a step back, not a jump
      history.pushState({ ...state, __TSR_index: (state.__TSR_index ?? 0) + 1, __overlay: entry.key }, "")
      stack.push(entry)
      if (!listening) {
        window.addEventListener("popstate", onPop)
        listening = true
      }
    }, 0)
    return () => {
      clearTimeout(timer)
      const i = stack.indexOf(entry)
      if (i < 0) return
      stack.splice(i, 1)
      if (entry.leaving) return
      entry.leaving = true
      // after the router's (microtask) history update: when the overlay was
      // closed by a link that replaced its entry, there is nothing to undo
      setTimeout(() => currentKey() === entry.key && history.back(), 0)
    }
  }, [enabled])
}

// Call before closing an overlay that navigates afterwards (palette, delete):
// resolves once the overlays' history entries are gone, so the navigation
// starts from the page's own entry (and `replace` replaces that one).
export function leaveOverlays(): Promise<void> {
  const live = stack.filter((e) => !e.leaving)
  if (!live.length || !currentKey()) return Promise.resolve()
  live.forEach((e) => (e.leaving = true))
  return new Promise((resolve) => {
    window.addEventListener("popstate", () => resolve(), { once: true })
    history.go(-live.length)
  })
}
