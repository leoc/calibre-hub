// What the reader needs and the browsers of the devices may lack: EPUBs are
// read with Object.groupBy and Map.groupBy (foliate-js), Chrome 117 and Safari
// 17.4 on, and older Boox WebViews are at 112. The pdf.js build brings its own.
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

export function installPolyfills() {
  if (!("groupBy" in Object)) Object.defineProperty(Object, "groupBy", { value: objectGroupBy, writable: true, configurable: true })
  if (!("groupBy" in Map)) Object.defineProperty(Map, "groupBy", { value: mapGroupBy, writable: true, configurable: true })
}

installPolyfills()
