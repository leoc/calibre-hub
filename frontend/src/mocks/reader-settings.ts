import { http, HttpResponse } from "msw"
import { COLUMN_MODES, DEFAULT_READER_SETTINGS, FONT_FAMILIES, LIMITS, READER_FLOWS, READER_THEMES, type ReaderSettings } from "@/lib/reader-settings"

// The reader's settings of the one mock user, checked like the hub does
// (src/calibre_hub/reader_settings.cr): a PUT changes only its fields.
let settings: ReaderSettings = { ...DEFAULT_READER_SETTINGS }

const choices: Partial<Record<keyof ReaderSettings, readonly string[]>> = {
  fontFamily: FONT_FAMILIES,
  columns: COLUMN_MODES,
  flow: READER_FLOWS,
  theme: READER_THEMES,
}

function invalid(key: string, value: unknown): string | null {
  if (!(key in DEFAULT_READER_SETTINGS)) return "unknown field"
  const k = key as keyof ReaderSettings
  const allowed = choices[k]
  if (allowed) return allowed.includes(value as string) ? null : `one of ${allowed.join(", ")}`
  if (k in LIMITS) {
    const [lo, hi] = LIMITS[k as keyof typeof LIMITS]
    const whole = k !== "lineHeight"
    if (typeof value !== "number" || value < lo || value > hi || (whole && !Number.isInteger(value))) return `${whole ? "whole " : ""}number from ${lo} to ${hi} expected`
    return null
  }
  return typeof value === "boolean" ? null : "true or false expected"
}

export const readerSettingsHandlers = [
  http.get("/api/reader/settings", () => HttpResponse.json(settings)),
  http.put("/api/reader/settings", async ({ request }) => {
    const body = (await request.json().catch(() => null)) as Record<string, unknown> | null
    if (!body || typeof body !== "object" || Array.isArray(body)) return HttpResponse.json({ error: "JSON object expected", field: "" }, { status: 400 })
    for (const [k, v] of Object.entries(body)) {
      const error = invalid(k, v)
      if (error) return HttpResponse.json({ error, field: k }, { status: 400 })
    }
    settings = { ...settings, ...(body as Partial<ReaderSettings>) }
    return HttpResponse.json(settings)
  }),
]
