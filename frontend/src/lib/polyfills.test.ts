import { afterEach, describe, expect, it } from "vitest"
import { installPolyfills } from "./polyfills"

interface Item {
  k: string
  n: number
}
type ByKey = (items: Item[], key: (i: Item) => string) => Record<string, Item[]>
type MapByKey = (items: Item[], key: (i: Item) => string) => Map<string, Item[]>

const object = Object as unknown as { groupBy?: ByKey }
const map = Map as unknown as { groupBy?: MapByKey }
const own = { object: object.groupBy!, map: map.groupBy! }

describe("groupBy on a browser without it", () => {
  afterEach(() => {
    Object.defineProperty(Object, "groupBy", { value: own.object, writable: true, configurable: true })
    Object.defineProperty(Map, "groupBy", { value: own.map, writable: true, configurable: true })
  })

  it("groups as the browser's own does", () => {
    delete object.groupBy
    delete map.groupBy
    installPolyfills()
    expect(object.groupBy).not.toBe(own.object)
    const items = [{ k: "a", n: 1 }, { k: "b", n: 2 }, { k: "a", n: 3 }]
    const byKey = (i: Item) => i.k
    const groups = object.groupBy!(items, byKey)
    expect(Object.getPrototypeOf(groups)).toBeNull()
    expect({ ...groups }).toEqual({ ...own.object(items, byKey) })
    expect([...map.groupBy!(items, byKey)]).toEqual([...own.map(items, byKey)])
  })

  it("leaves a browser's own alone", () => {
    installPolyfills()
    expect(object.groupBy).toBe(own.object)
    expect(map.groupBy).toBe(own.map)
  })
})
