import { http, HttpResponse } from "msw"
import type { ProgressEntry, ProgressSave } from "@/lib/api"
import epubUrl from "./fixtures/sample.epub?url"
import pdfUrl from "./fixtures/sample.pdf?url"

// Reading progress per book and device, like the hub's state DB (one user).
// e2e tests simulate another device by PUTting with another device id.
const store = new Map<number, Map<string, ProgressEntry>>()

const devicesOf = (bookId: number) =>
  [...(store.get(bookId)?.values() ?? [])].sort((a, b) => Date.parse(b.updatedAt) - Date.parse(a.updatedAt))

// a later save always gets a later time, also within one millisecond
let lastTime = 0
const now = () => {
  lastTime = Math.max(Date.now(), lastTime + 1)
  return new Date(lastTime).toISOString()
}

// Book files: a small EPUB (three chapters) and a three-page PDF; other
// formats get the EPUB too (foliate-js tells them apart by content)
const fixture = async (url: string) => (await fetch(url)).arrayBuffer()

export const progressHandlers = [
  http.get("/api/progress", () =>
    HttpResponse.json([...store.keys()].flatMap((id) => devicesOf(id).slice(0, 1)).map(({ bookId, fraction, format, updatedAt }) => ({ bookId, fraction, format, updatedAt }))),
  ),
  http.get("/api/books/:id/progress", ({ params }) => {
    const devices = devicesOf(Number(params.id))
    return HttpResponse.json({ latest: devices[0] ?? null, devices })
  }),
  http.put("/api/books/:id/progress", async ({ params, request }) => {
    const body = (await request.json()) as ProgressSave
    if (typeof body.fraction !== "number" || body.fraction < 0 || body.fraction > 1) {
      return HttpResponse.json({ error: "number from 0 to 1 expected", field: "fraction" }, { status: 400 })
    }
    if (!body.device) return HttpResponse.json({ error: "device id expected", field: "device" }, { status: 400 })
    const bookId = Number(params.id)
    const entry: ProgressEntry = {
      bookId,
      device: body.device,
      deviceName: body.deviceName || body.device,
      format: body.format.toLowerCase(),
      position: body.position,
      fraction: body.fraction,
      source: "web",
      updatedAt: now(),
    }
    if (!store.has(bookId)) store.set(bookId, new Map())
    store.get(bookId)!.set(entry.device, entry)
    return HttpResponse.json(entry)
  }),
  http.get("/api/books/:id/download/:format", async ({ params }) => {
    const format = String(params.format).toLowerCase()
    const pdf = format === "pdf"
    return new HttpResponse(await fixture(pdf ? pdfUrl : epubUrl), {
      headers: {
        "Content-Type": pdf ? "application/pdf" : "application/epub+zip",
        "Content-Disposition": `attachment; filename="book-${params.id}.${format}"`,
        "Accept-Ranges": "bytes",
      },
    })
  }),
]
