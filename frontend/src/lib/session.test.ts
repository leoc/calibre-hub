import { describe, expect, it } from "vitest"
import { isAdmin } from "./session"

describe("isAdmin", () => {
  it("follows the role", () => {
    expect(isAdmin({ user: "arthur", role: "admin" })).toBe(true)
    expect(isAdmin({ user: "lea", role: "reader" })).toBe(false)
  })

  it("takes a server without roles for an admin, no session for none", () => {
    expect(isAdmin({ user: "arthur" })).toBe(true)
    expect(isAdmin(undefined)).toBe(false)
  })
})
