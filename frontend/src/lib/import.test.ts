import { describe, expect, it } from "vitest"
import type { ImportBacklog, ImportRun } from "./api"
import { activeRuns, backlogDone, followupQueues, formatDuration, percent, portionBlock, portionLimit, portionRun, runProgress } from "./import"

const run = (extra: Partial<ImportRun>): ImportRun => ({
  id: "r",
  path: "/srv",
  dryRun: false,
  createdAt: "2026-11-03T08:00:00Z",
  jobId: "j",
  status: "done",
  done: 0,
  total: 0,
  error: null,
  summary: null,
  results: {},
  ...extra,
})

describe("formatDuration", () => {
  it("shows hours with minutes, minutes with seconds, or seconds", () => {
    expect(formatDuration(3725)).toBe("1 Std. 02 Min.")
    expect(formatDuration(250)).toBe("4 Min. 10 s")
    expect(formatDuration(12.4)).toBe("12 s")
    expect(formatDuration(-3)).toBe("0 s")
  })
})

describe("percent", () => {
  it("rounds, but shows a start and never finishes early", () => {
    expect(percent(0, 0)).toBe(0)
    expect(percent(1, 17_500)).toBe(1)
    expect(percent(17_499, 17_500)).toBe(99)
    expect(percent(260, 520)).toBe(50)
    expect(percent(5, 5)).toBe(100)
  })
})

describe("runProgress", () => {
  it("has no total while the folders are walked", () => {
    expect(runProgress(run({ status: "scanning", phase: "scan", scan: { files: 10, units: 3, planned: 0 } }))).toBeNull()
  })

  it("counts checked books, then imported ones", () => {
    expect(runProgress(run({ status: "scanning", phase: "check", scan: { files: 10, units: 8, planned: 3 } }))).toEqual({ done: 3, total: 8 })
    expect(runProgress(run({ status: "running", phase: "import", done: 4, total: 9 }))).toEqual({ done: 4, total: 9 })
    expect(runProgress(run({ status: "done" }))).toBeNull()
  })
})

describe("activeRuns", () => {
  it("lists the live runs, an import before a dry run", () => {
    const runs = [run({ id: "dry", dryRun: true, status: "scanning" }), run({ id: "old" }), run({ id: "imp", status: "running" })]
    expect(activeRuns({ enabled: true, runs, cleanups: [] }).map((r) => r.id)).toEqual(["imp", "dry"])
  })
})

describe("followupQueues", () => {
  it("orders the hooks as they run, unknown ones last", () => {
    expect(followupQueues({ embed: 1, zzz: 2, metadata: 3 })).toEqual([
      ["metadata", 3],
      ["embed", 1],
      ["zzz", 2],
    ])
  })
})

describe("portionLimit", () => {
  it("takes whole numbers from 1 up, like hub import --limit", () => {
    expect(portionLimit("500")).toBe(500)
    expect(portionLimit("1")).toBe(1)
    for (const text of ["", "0", "-5", "2.5", "x", "2147483648"]) expect(portionLimit(text)).toBeNull()
  })
})

describe("portionRun", () => {
  const status = (...runs: ImportRun[]) => ({ enabled: true, roots: ["/srv"], runs, cleanups: [] })
  const dry = run({ id: "dry", dryRun: true, status: "planned", limit: 500 })

  it("is the newest run, a dry run of the first root with a limit", () => {
    expect(portionRun(status(dry, run({ id: "old" })), null)).toBe(dry)
  })

  it("is gone once another run came after it", () => {
    expect(portionRun(status(run({ id: "new" }), dry), "dry")).toBeNull()
  })

  it("needs a limit", () => {
    expect(portionRun(status(run({ dryRun: true, status: "planned" })), null)).toBeNull()
  })

  it("takes another folder only as the dry run asked for here", () => {
    const other = run({ id: "real", path: "/mnt/srv", dryRun: true, limit: 500 })
    expect(portionRun(status(other), null)).toBeNull()
    expect(portionRun(status(other), "real")).toBe(other)
  })
})

describe("portionBlock", () => {
  const idle = { enabled: true, cleanups: [] }
  const followup = (total: number) => ({ paused: false, total, queues: {} })

  it("names what is going on", () => {
    expect(portionBlock({ ...idle, running: true, scanning: true }, true)).toBe("import")
    expect(portionBlock({ ...idle, scanning: true }, false)).toBe("scan")
    expect(portionBlock({ ...idle, followup: followup(3) }, false)).toBe("followup")
    expect(portionBlock({ ...idle, followup: followup(0) }, true)).toBe("repair")
  })

  it("lets a portion begin when all is quiet", () => {
    expect(portionBlock({ ...idle, followup: followup(0) }, false)).toBeNull()
  })
})

describe("backlogDone", () => {
  const backlog = (open: Partial<ImportBacklog["open"]>, paths = ["/srv"]): ImportBacklog => ({
    imported: 5,
    formatAdded: 0,
    duplicates: 0,
    open: { books: 0, formats: 0, duplicates: 0, failed: 0, ...open },
    total: 5,
    basis: { runId: "r", paths, createdAt: "2026-11-03T08:00:00Z" },
    etaSeconds: null,
  })
  const status = (b?: ImportBacklog) => ({ enabled: true, roots: ["/srv"], backlog: b, cleanups: [] })

  it("needs a run of the whole root with nothing left", () => {
    expect(backlogDone(status(backlog({})))).toBe(true)
    expect(backlogDone(status(backlog({ books: 1 })))).toBe(false)
    expect(backlogDone(status(backlog({ duplicates: 1 })))).toBe(false)
  })

  it("knows nothing from a subfolder or before the first scan", () => {
    expect(backlogDone(status(backlog({}, ["/srv/alt"])))).toBe(false)
    expect(backlogDone(status())).toBe(false)
  })
})
