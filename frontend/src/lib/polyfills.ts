// What the reader needs and the browsers of the devices may lack: EPUBs are
// read with Object.groupBy and Map.groupBy (foliate-js), Chrome 117 and Safari
// 17.4 on, and older Boox WebViews are at 112; EPUBs and comics are unzipped
// with DecompressionStream (zip.js), Safari 16.4 on. The pdf.js build brings
// its own.
type Key = string | symbol

const objectGroupBy = <T>(items: Iterable<T>, key: (item: T, index: number) => Key) => {
  const groups: Record<Key, T[]> = Object.create(null)
  let i = 0
  for (const item of items) (groups[key(item, i++)] ??= []).push(item)
  return groups
}

const mapGroupBy = <T, K>(items: Iterable<T>, key: (item: T, index: number) => K) => {
  const groups = new Map<K, T[]>()
  let i = 0
  for (const item of items) {
    const k = key(item, i++)
    const group = groups.get(k)
    if (group) group.push(item)
    else groups.set(k, [item])
  }
  return groups
}

// Only what zip.js asks for: raw deflate, one zip entry, inflated when all of
// it is there. fflate's unzlibSync skips a zlib header and trailer unchecked.
class RawInflate {
  readable: ReadableStream<Uint8Array>
  writable: WritableStream<Uint8Array>

  constructor(format: string) {
    if (format !== "deflate-raw") throw new TypeError(`Unsupported format: ${format}`)
    const chunks: Uint8Array[] = []
    const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>({
      transform: (chunk) => void chunks.push(chunk),
      flush: async (out) => {
        const { unzlibSync } = await import("foliate-js/vendor/fflate.js")
        const size = chunks.reduce((n, c) => n + c.length, 0)
        const zlib = new Uint8Array(size + 6)
        zlib.set([0x78, 0x9c])
        let at = 2
        for (const c of chunks) {
          zlib.set(c, at)
          at += c.length
        }
        out.enqueue(unzlibSync(zlib))
      },
    })
    this.readable = readable
    this.writable = writable
  }
}

export function installPolyfills() {
  if (!("groupBy" in Object)) Object.defineProperty(Object, "groupBy", { value: objectGroupBy, writable: true, configurable: true })
  if (!("groupBy" in Map)) Object.defineProperty(Map, "groupBy", { value: mapGroupBy, writable: true, configurable: true })
  if (!("DecompressionStream" in globalThis)) Object.defineProperty(globalThis, "DecompressionStream", { value: RawInflate, writable: true, configurable: true })
}

installPolyfills()
