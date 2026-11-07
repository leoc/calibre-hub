import { describe, expect, it } from "vitest"
import { readBody } from "./offline"
import { loadingText } from "./reader"

const stream = (...chunks: number[]) =>
  new ReadableStream<Uint8Array>({
    start(c) {
      for (const n of chunks) c.enqueue(new Uint8Array(n))
      c.close()
    },
  })

describe("readBody", () => {
  it("says how far it got, of what Content-Length says", async () => {
    const seen: [number, number | null][] = []
    const blob = await readBody(new Response(stream(3, 4), { headers: { "Content-Length": "7" } }), (r, t) => seen.push([r, t]))
    expect(blob.size).toBe(7)
    expect(seen).toEqual([[3, 7], [7, 7]])
  })

  it("has no total without Content-Length", async () => {
    const seen: (number | null)[] = []
    await readBody(new Response(stream(2)), (_, t) => seen.push(t))
    expect(seen).toEqual([null])
  })

  it("takes a response without a stream as it is", async () => {
    const blob = await readBody(new Response(null), () => expect.unreachable())
    expect(blob.size).toBe(0)
  })
})

describe("loadingText", () => {
  it("counts whole MB of what is to come", () => {
    expect(loadingText(12_400_000, 117_600_000)).toBe("Lade 12 von 118 MB …")
    expect(loadingText(1000, 2000)).toBe("Lade 0 von 1 MB …")
  })

  it("says all of it when the last byte is there", () => {
    expect(loadingText(3_600_000, 3_600_000)).toBe("Lade 4 von 4 MB …")
  })

  it("says what it has when the total isn't known", () => {
    expect(loadingText(12_400_000, null)).toBe("Lade 12 MB …")
  })
})
