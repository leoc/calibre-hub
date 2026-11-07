import { afterEach, describe, expect, it } from "vitest"
import fs from "node:fs"
import path from "node:path"
import { deflateRawSync } from "node:zlib"
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

describe("DecompressionStream on a browser without it", () => {
  const own = globalThis.DecompressionStream
  afterEach(() => Object.defineProperty(globalThis, "DecompressionStream", { value: own, writable: true, configurable: true }))

  const inflate = (data: Uint8Array) => {
    Reflect.deleteProperty(globalThis, "DecompressionStream")
    installPolyfills()
    expect(globalThis.DecompressionStream).not.toBe(own)
    const half = data.length >> 1
    const input = new ReadableStream<Uint8Array>({
      start(c) {
        c.enqueue(data.slice(0, half))
        c.enqueue(data.slice(half))
        c.close()
      },
    })
    return new Response(input.pipeThrough(new DecompressionStream("deflate-raw") as ReadableWritablePair<Uint8Array, Uint8Array>)).text()
  }

  it("inflates a zip entry's raw deflate, as it comes in pieces", async () => {
    const text = "Kapitel 1, Absatz 1. ".repeat(500)
    expect(await inflate(new Uint8Array(deflateRawSync(text)))).toBe(text)
  })

  it("says what it can't do", () => {
    Reflect.deleteProperty(globalThis, "DecompressionStream")
    installPolyfills()
    expect(() => new DecompressionStream("gzip")).toThrow("gzip")
  })
})

// a syntax error in Safari below 16.4: the module wouldn't load at all
it("foliate-js has no regex lookbehind", () => {
  const dir = path.resolve(import.meta.dirname, "../../vendor/foliate-js")
  const modules = fs.readdirSync(dir).filter((f) => f.endsWith(".js"))
  expect(modules.filter((f) => /\(\?<[=!]/.test(fs.readFileSync(path.join(dir, f), "utf8")))).toEqual([])
})
