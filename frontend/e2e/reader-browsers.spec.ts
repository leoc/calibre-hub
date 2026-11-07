import { expect, test, type Page } from "@playwright/test"

// What Safari on an iPhone and older Boox WebViews lack, in Chromium; the same
// in a real WebKit: e2e/webkit/reader.mjs (README, Reader in Safari). The
// page's own scope only, a worker has its APIs: that the worker
// doesn't need them is the legacy build's word. Promise.withResolvers stays:
// the mock hub (MSW) needs it, the built app doesn't.
const older = () => {
  const gone = (o: object, ...names: string[]) => names.forEach((n) => delete (o as Record<string, unknown>)[n])
  gone(Object, "groupBy")
  gone(Map, "groupBy")
  gone(Promise, "try")
  gone(Math, "sumPrecise")
  gone(URL, "parse")
  gone(Map.prototype, "getOrInsert", "getOrInsertComputed")
  gone(Uint8Array, "fromBase64", "fromHex")
  gone(Uint8Array.prototype, "toBase64", "toHex")
  gone(AbortSignal, "any")
  // below Safari 16.4
  gone(window, "DecompressionStream", "CompressionStream")
  const own = CSSStyleSheet
  window.CSSStyleSheet = function () {
    throw new TypeError("Illegal constructor")
  } as unknown as typeof CSSStyleSheet
  window.CSSStyleSheet.prototype = own.prototype
}

// the worker itself; with ?url it is the module that names it, and without
// that module pdf.js never starts
const WORKER = /pdf\.worker\.min\.mjs$/

const READER_ORDER = ["EPUB", "KEPUB", "AZW3", "MOBI", "AZW", "FB2", "CBZ", "PDF"]

// the first book the reader opens in this format
const openBook = async (page: Page, format: string) => {
  await page.goto("/")
  await expect(page.getByRole("link", { name: /./ }).first()).toBeVisible()
  const all = await page.evaluate(() => fetch("/api/books?limit=500&sort=title").then((r) => r.json()))
  const book = all.books.find((b: { formats: string[] }) => READER_ORDER.find((f) => b.formats.includes(f)) === format)
  await page.goto(`/?book=${book.id}`)
  await page.getByRole("link", { name: /^(Lesen|Weiterlesen)/ }).click()
}

for (const format of ["PDF", "EPUB"]) {
  test(`a ${format} opens without the recent APIs`, async ({ page }) => {
    const errors: string[] = []
    page.on("pageerror", (e) => errors.push(e.message))
    await page.addInitScript(older)
    await openBook(page, format)
    await expect(page.locator('[data-reader="ready"]')).toBeVisible({ timeout: 15_000 })
    expect(errors).toEqual([])
  })
}

test("a worker that never answers ends in a message, not in loading for good", async ({ page, context }) => {
  test.setTimeout(60_000)
  await context.route(WORKER, () => {})
  await openBook(page, "PDF")
  await expect(page.locator('[data-reader="loading"]')).toBeVisible()
  await expect(page.locator('[data-reader="failed"]')).toBeVisible({ timeout: 45_000 })
  await expect(page.getByText("Der PDF-Leser antwortet nicht.")).toBeVisible()
})

// pdf.js then does the work in the page itself, slower but the book opens
test("a worker that can't be loaded still opens the book", async ({ page, context }) => {
  await context.route(WORKER, (r) => r.abort())
  await openBook(page, "PDF")
  await expect(page.locator('[data-reader="ready"]')).toBeVisible({ timeout: 15_000 })
})
