import { describe, expect, it } from "vitest"
import type { ImportRun } from "./api"
import { activeRuns, followupQueues, formatDuration, percent, runProgress } from "./import"

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
