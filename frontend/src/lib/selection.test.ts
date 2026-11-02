import { beforeEach, expect, it } from "vitest"
import { selection } from "./selection"
import { renderHook } from "@testing-library/react"
import { useSelection } from "./selection"

const current = () => renderHook(() => useSelection()).result.current

beforeEach(() => selection.stop())

it("toggles single books and selects ranges with shift", () => {
  const order = [5, 6, 7, 8, 9]
  selection.toggle(6, false, order)
  selection.toggle(9, true, order)
  expect([...current().ids].sort()).toEqual([6, 7, 8, 9])
  selection.toggle(7, false, order)
  expect([...current().ids].sort()).toEqual([6, 8, 9])
})

it("switches between all matches and explicit ids", () => {
  selection.selectAll()
  expect(current().all).toBe(true)
  selection.toggle(1, false, [1])
  expect(current().all).toBe(false)
  expect([...current().ids]).toEqual([1])
})

// numbering a series counts along the selection
it("keeps the selection order: clicks as clicked, ranges and pages as shown", () => {
  const order = [5, 6, 7, 8, 9]
  selection.toggle(8, false, order)
  selection.toggle(6, false, order)
  selection.toggle(9, false, order)
  selection.toggle(7, true, order)
  expect([...current().ids]).toEqual([8, 6, 9, 7])
  selection.clear()
  selection.toggle(9, false, order)
  selection.toggle(6, true, order)
  selection.addPage(order)
  expect([...current().ids]).toEqual([9, 6, 7, 8, 5])
})
