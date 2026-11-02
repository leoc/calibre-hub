import type { QueryClient } from "@tanstack/react-query"
import { ApiError, write, type ProgressEntry, type ProgressSave } from "./api"
import { isOnline } from "./online"
import { rememberEntry } from "./offline"

// Reading positions go through a queue in localStorage ("hub.progressQueue",
// the newest per book): written first, removed once the hub has it. What
// was read offline (or while the hub was out of reach) is sent on the next
// contact with its age, so the hub dates it back to when it was read and
// the newest position still wins (README "Reader").

const KEY = "hub.progressQueue"

export interface Queued {
  bookId: number
  save: ProgressSave
  // Date.now() when it was read
  at: number
}

type Queue = Record<string, Queued>

function read(): Queue {
  try {
    const v = JSON.parse(localStorage.getItem(KEY) ?? "{}")
    return v && typeof v === "object" ? (v as Queue) : {}
  } catch {
    return {}
  }
}

function store(q: Queue) {
  try {
    if (Object.keys(q).length === 0) localStorage.removeItem(KEY)
    else localStorage.setItem(KEY, JSON.stringify(q))
  } catch {
    // ignore
  }
}

const put = (q: Queued) => store({ ...read(), [q.bookId]: q })

// removes it unless a newer position came in meanwhile
function drop(q: Queued) {
  const all = read()
  if (all[q.bookId]?.at !== q.at) return
  delete all[q.bookId]
  store(all)
}

export const queuedProgress = (bookId: number): Queued | null => read()[bookId] ?? null
export const queuedCount = () => Object.keys(read()).length
export const clearQueue = () => store({})

// The hub's positions with this device's unsent one in front (it is newer
// than what the hub has of this device)
export function withQueued(devices: ProgressEntry[], q: Queued | null): ProgressEntry[] {
  if (!q) return devices
  const mine: ProgressEntry = {
    bookId: q.bookId,
    device: q.save.device,
    deviceName: q.save.deviceName || q.save.device,
    format: q.save.format,
    position: q.save.position,
    fraction: q.save.fraction,
    source: "web",
    updatedAt: new Date(q.at).toISOString(),
  }
  return [mine, ...devices.filter((d) => d.device !== mine.device)]
}

// Positions read more than a second ago say how long ago (offline)
export const withAge = (save: ProgressSave, at: number, now = Date.now()): ProgressSave => {
  const age = Math.max(0, Math.round(now - at))
  return age >= 1000 ? { ...save, age } : save
}

// The hub's entry, null when it has to wait (offline, hub down, logged
// out); positions the hub refuses (400, 404) are dropped
async function send(q: Queued, keepalive: boolean): Promise<ProgressEntry | null> {
  try {
    const entry = await write.saveProgress(q.bookId, withAge(q.save, q.at), keepalive)
    drop(q)
    rememberEntry(entry)
    return entry
  } catch (e) {
    if (e instanceof ApiError && (e.status === 400 || e.status === 404)) drop(q)
    return null
  }
}

// Saves this device's position: queued first, then sent unless offline
export function saveProgress(bookId: number, save: ProgressSave, closing = false): Promise<ProgressEntry | null> {
  const q: Queued = { bookId, save, at: Date.now() }
  put(q)
  if (!isOnline()) return Promise.resolve(null)
  return send(q, closing)
}

// Sends what is waiting, oldest first; stops at the first that has to wait.
// Resolves to the number sent.
let flushing: Promise<number> | null = null
export function flushProgress(): Promise<number> {
  if (flushing) return flushing
  flushing = (async () => {
    let sent = 0
    if (!isOnline()) return sent
    for (const q of Object.values(read()).sort((a, b) => a.at - b.at)) {
      if (await send(q, false)) sent++
      // still queued: the hub can't take it now
      else if (queuedProgress(q.bookId)?.at === q.at) break
    }
    return sent
  })().finally(() => (flushing = null))
  return flushing
}

// On start, when the network comes back and when the app is shown again
export function startProgressSync(queryClient: QueryClient) {
  const run = () =>
    void flushProgress().then((n) => {
      if (n > 0) void queryClient.invalidateQueries({ queryKey: ["progress"] })
    })
  window.addEventListener("online", run)
  document.addEventListener("visibilitychange", () => document.visibilityState === "visible" && run())
  run()
}
