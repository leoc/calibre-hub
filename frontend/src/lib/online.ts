import { useSyncExternalStore } from "react"

// navigator.onLine as state; false is sure (no network), true only means
// there may be one
const subscribe = (cb: () => void) => {
  window.addEventListener("online", cb)
  window.addEventListener("offline", cb)
  return () => {
    window.removeEventListener("online", cb)
    window.removeEventListener("offline", cb)
  }
}

export const isOnline = () => (typeof navigator === "undefined" ? true : navigator.onLine !== false)

export const useOnline = () => useSyncExternalStore(subscribe, isOnline, () => true)

// Thrown when a page needs the hub while there is no network
export class OfflineError extends Error {
  constructor() {
    super("offline")
    this.name = "OfflineError"
  }
}

// fetch() failing without a response: no network, DNS, the hub unreachable
// (Chrome "Failed to fetch", Firefox "NetworkError …", Safari "Load failed")
export const isNetworkError = (e: unknown) =>
  e instanceof OfflineError || (e instanceof TypeError && /fetch|network|load failed/i.test(e.message))
