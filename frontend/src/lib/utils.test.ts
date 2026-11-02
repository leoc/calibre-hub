import { describe, expect, it } from "vitest"
import { isApple } from "./utils"

describe("isApple", () => {
  it("prefers userAgentData", () => {
    expect(isApple({ platform: "MacIntel", userAgentData: { platform: "Linux" } })).toBe(false)
    expect(isApple({ userAgentData: { platform: "macOS" } })).toBe(true)
  })
  it("falls back to navigator.platform", () => {
    expect(isApple({ platform: "MacIntel" })).toBe(true)
    expect(isApple({ platform: "iPhone" })).toBe(true)
    expect(isApple({ platform: "Linux x86_64" })).toBe(false)
    expect(isApple({ platform: "Win32" })).toBe(false)
    expect(isApple({})).toBe(false)
  })
})
