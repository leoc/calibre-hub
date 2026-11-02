import { ApiError, write, type ProgressEntry, type ProgressSave } from "./api"
import { flushProgress, queuedCount, queuedProgress, saveProgress, withAge, withQueued } from "./progress-sync"
import { formatBytes } from "./offline"
import { startPoint } from "./reader"

const save = (fraction: number, device = "me"): ProgressSave => ({ format: "epub", position: `cfi-${fraction}`, fraction, device, deviceName: "Firefox auf Linux" })
const entry = (bookId: number, s: ProgressSave, updatedAt = new Date().toISOString()): ProgressEntry => ({
  bookId,
  device: s.device,
  deviceName: s.deviceName ?? s.device,
  format: s.format,
  position: s.position,
  fraction: s.fraction,
  source: "web",
  updatedAt,
})

const setOnline = (on: boolean) => Object.defineProperty(navigator, "onLine", { configurable: true, get: () => on })

describe("progress sync", () => {
  beforeEach(() => {
    localStorage.clear()
    setOnline(true)
    vi.restoreAllMocks()
  })

  it("keeps a position read offline and sends it later with its age", async () => {
    const sent = vi.spyOn(write, "saveProgress").mockImplementation(async (id, p) => entry(id, p))
    setOnline(false)
    vi.spyOn(Date, "now").mockReturnValue(1_000_000)
    expect(await saveProgress(7, save(0.4))).toBeNull()
    expect(sent).not.toHaveBeenCalled()
    expect(queuedProgress(7)?.save.fraction).toBe(0.4)

    // a later page turn replaces it: the newest per book
    expect(await saveProgress(7, save(0.45))).toBeNull()
    expect(queuedCount()).toBe(1)

    setOnline(true)
    vi.spyOn(Date, "now").mockReturnValue(1_000_000 + 3_600_000)
    expect(await flushProgress()).toBe(1)
    expect(sent).toHaveBeenCalledWith(7, { ...save(0.45), age: 3_600_000 }, false)
    expect(queuedCount()).toBe(0)
  })

  it("sends right away when online, without an age", async () => {
    const sent = vi.spyOn(write, "saveProgress").mockImplementation(async (id, p) => entry(id, p))
    const e = await saveProgress(3, save(0.2), true)
    expect(e?.fraction).toBe(0.2)
    expect(sent).toHaveBeenCalledWith(3, save(0.2), true)
    expect(queuedProgress(3)).toBeNull()
  })

  it("keeps positions the hub can't take now, drops those it refuses", async () => {
    vi.spyOn(write, "saveProgress").mockRejectedValueOnce(new TypeError("Failed to fetch"))
    expect(await saveProgress(1, save(0.1))).toBeNull()
    expect(queuedProgress(1)).not.toBeNull()

    vi.spyOn(write, "saveProgress").mockRejectedValueOnce(new ApiError(502, "Bad Gateway"))
    expect(await flushProgress()).toBe(0)
    expect(queuedProgress(1)).not.toBeNull()

    vi.spyOn(write, "saveProgress").mockRejectedValueOnce(new ApiError(404, "Not Found"))
    expect(await flushProgress()).toBe(0)
    expect(queuedProgress(1)).toBeNull()
  })

  it("opens where this device stopped offline, ahead of the hub's copy", () => {
    const hub = [entry(1, save(0.6, "boox"), "2026-11-02T11:00:00Z"), entry(1, save(0.2), "2026-11-02T09:00:00Z")]
    const devices = withQueued(hub, { bookId: 1, save: save(0.4), at: Date.parse("2026-11-02T10:00:00Z") })
    expect(devices.map((d) => [d.device, d.fraction])).toEqual([
      ["me", 0.4],
      ["boox", 0.6],
    ])
    // the Boox read later: asked about, as online
    const start = startPoint(devices, "me")
    expect(start.mine?.fraction).toBe(0.4)
    expect(start.elsewhere?.device).toBe("boox")
    expect(withQueued(hub, null)).toBe(hub)
  })

  it("says how long ago only for positions sent late", () => {
    expect(withAge(save(0.1), 1000, 1500)).toEqual(save(0.1))
    expect(withAge(save(0.1), 1000, 61_000)).toEqual({ ...save(0.1), age: 60_000 })
  })

  it("shows sizes", () => {
    expect(formatBytes(512)).toBe("512 B")
    expect(formatBytes(1_234_567)).toBe("1,2 MB")
    expect(formatBytes(345_000)).toBe("345 KB")
  })
})
