import { expect, it } from "vitest"
import { hintLabels } from "./keyboard-panels"

it("gives hints labels of one length, none the start of another", () => {
  expect(hintLabels(3)).toEqual(["a", "s", "d"])
  const many = hintLabels(100)
  expect(new Set(many).size).toBe(100)
  expect(many.every((l) => l.length === 2)).toBe(true)
})
