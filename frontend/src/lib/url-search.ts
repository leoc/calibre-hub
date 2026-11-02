// Plain query strings (?tag=a&tag=b&page=2) instead of the router's JSON
// encoding; the route schemas coerce the strings back.
export function parseSearch(searchStr: string): Record<string, unknown> {
  const out: Record<string, string | string[]> = {}
  for (const [k, v] of new URLSearchParams(searchStr)) {
    const prev = out[k]
    out[k] = prev === undefined ? v : Array.isArray(prev) ? [...prev, v] : [prev, v]
  }
  return out
}

export function stringifySearch(search: Record<string, unknown>): string {
  const p = new URLSearchParams()
  for (const [k, v] of Object.entries(search)) {
    if (v === undefined || v === null || v === "") continue
    for (const x of Array.isArray(v) ? v : [v]) p.append(k, String(x))
  }
  const s = p.toString()
  return s ? `?${s}` : ""
}
