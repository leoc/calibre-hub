import type { ProgressEntry } from "./api"
import { deviceLabel, peekKey, percent, positionOf, readerFormat, readerKey, startPoint, tapZone, targetOf, watchdog } from "./reader"

const entry = (device: string, fraction: number, at: string, extra: Partial<ProgressEntry> = {}): ProgressEntry => ({
  bookId: 1,
  device,
  deviceName: device,
  format: "epub",
  position: "epubcfi(/6/4!/4/2)",
  fraction,
  source: "web",
  updatedAt: at,
  ...extra,
})

describe("reader", () => {
  it("picks the format the reader opens", () => {
    expect(readerFormat({ formats: ["PDF", "EPUB"] })).toBe("EPUB")
    expect(readerFormat({ formats: ["PDF", "EPUB"] }, "pdf")).toBe("PDF")
    expect(readerFormat({ formats: ["PDF"] }, "epub")).toBe("PDF")
    expect(readerFormat({ formats: ["DJVU", "TXT"] })).toBeNull()
    expect(readerFormat({ formats: [] })).toBeNull()
  })

  it("shows whole percents, 100 only at the end", () => {
    expect(percent(0.634)).toBe(63)
    expect(percent(0.999)).toBe(99)
    expect(percent(1)).toBe(100)
    expect(percent(0)).toBe(0)
  })

  it("names devices after browser and system", () => {
    expect(deviceLabel("Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0")).toBe("Firefox auf Linux")
    expect(deviceLabel("Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Mobile Safari/537.36")).toBe("Chrome auf Android")
    expect(deviceLabel("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1")).toBe("Safari auf iPhone")
    expect(deviceLabel("Mozilla/5.0 (Linux; Android 11; BOOX Tab Ultra) AppleWebKit/537.36 Chrome/120.0 Safari/537.36")).toBe("Boox")
  })

  it("opens at this device's position and asks about a newer one", () => {
    const mine = entry("me", 0.2, "2026-11-01T10:00:00Z")
    const other = entry("boox", 0.71, "2026-11-02T10:00:00Z")
    expect(startPoint([], "me")).toEqual({ mine: null, elsewhere: null })
    expect(startPoint([other, mine], "me")).toEqual({ mine, elsewhere: other })
    // this device is the newest: nothing to ask
    expect(startPoint([entry("boox", 0.71, "2026-10-01T10:00:00Z"), mine], "me").elsewhere).toBeNull()
    // never read here: the newest position, without asking
    expect(startPoint([other], "me")).toEqual({ mine: other, elsewhere: null })
    // about the same place: not worth asking
    expect(startPoint([entry("boox", 0.205, "2026-11-02T10:00:00Z"), mine], "me").elsewhere).toBeNull()
  })

  it("goes to a position in the same format, else to the fraction", () => {
    expect(targetOf({ format: "epub", position: "epubcfi(/6/4!/4/2)", fraction: 0.3 }, "EPUB")).toBe("epubcfi(/6/4!/4/2)")
    expect(targetOf({ format: "pdf", position: "12", fraction: 0.3 }, "PDF")).toBe(11)
    expect(targetOf({ format: "pdf", position: "12", fraction: 0.3 }, "EPUB")).toEqual({ fraction: 0.3 })
    expect(targetOf({ format: "epub", position: "x", fraction: 0.3 }, "EPUB")).toEqual({ fraction: 0.3 })
    expect(positionOf("PDF", "epubcfi(/6/2)", 4)).toBe("5")
    expect(positionOf("EPUB", "epubcfi(/6/2)", 4)).toBe("epubcfi(/6/2)")
  })

  it("has its own keys, j/k only in Vim mode", () => {
    const key = (k: string, extra = {}) => ({ key: k, shiftKey: false, ctrlKey: false, metaKey: false, altKey: false, ...extra })
    expect(readerKey(key("ArrowRight"), false)).toBe("next")
    expect(readerKey(key("PageUp"), false)).toBe("prev")
    expect(readerKey(key(" "), false)).toBe("next")
    expect(readerKey(key(" ", { shiftKey: true }), false)).toBe("prev")
    expect(readerKey(key("Escape"), false)).toBe("back")
    expect(readerKey(key("j"), false)).toBeNull()
    expect(readerKey(key("j"), true)).toBe("next")
    expect(readerKey(key("k"), true)).toBe("prev")
    expect(readerKey(key("ArrowRight", { altKey: true }), false)).toBeNull()
  })

  it("splits the page into tap zones", () => {
    expect(tapZone(10, 900)).toBe("prev")
    expect(tapZone(450, 900)).toBe("menu")
    expect(tapZone(890, 900)).toBe("next")
  })
})

describe("peekKey", () => {
  const key = (k: string, extra = {}) => peekKey({ key: k, shiftKey: false, ctrlKey: false, metaKey: false, altKey: false, ...extra })
  it("turns with h and l whatever the mode, leaves j and k to the list", () => {
    expect([key("h"), key("l"), key("j"), key("k")]).toEqual(["prev", "next", null, null])
  })
  it("keeps the reader's other keys and leaves modifiers alone", () => {
    expect(key("Escape")).toBe("back")
    expect(key("ArrowRight")).toBe("next")
    expect(key("l", { ctrlKey: true })).toBeNull()
  })
})

describe("watchdog", () => {
  beforeEach(() => vi.useFakeTimers())
  afterEach(() => vi.useRealTimers())

  it("speaks up after the limit of silence", () => {
    const silent = vi.fn()
    watchdog(1000, silent)
    vi.advanceTimersByTime(999)
    expect(silent).not.toHaveBeenCalled()
    vi.advanceTimersByTime(1)
    expect(silent).toHaveBeenCalledOnce()
  })

  it("never speaks up while something keeps coming, however long it takes", () => {
    const silent = vi.fn()
    const clock = watchdog(1000, silent)
    for (let i = 0; i < 100; i++) {
      vi.advanceTimersByTime(900)
      clock.wait()
    }
    expect(silent).not.toHaveBeenCalled()
    clock.stop()
  })

  it("takes another limit", () => {
    const silent = vi.fn()
    const clock = watchdog(1000, silent)
    clock.wait(50)
    vi.advanceTimersByTime(50)
    expect(silent).toHaveBeenCalledOnce()
  })

  it("is quiet once stopped", () => {
    const silent = vi.fn()
    watchdog(1000, silent).stop()
    vi.advanceTimersByTime(5000)
    expect(silent).not.toHaveBeenCalled()
  })
})
