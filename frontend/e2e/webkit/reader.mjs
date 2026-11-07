// Run by run.sh. Plain Playwright core, not the test runner: the WebKit that
// runs here goes with an older Playwright than the npm package.
import assert from "node:assert/strict"
import { createRequire } from "node:module"

const { PLAYWRIGHT_CORE, WEBKIT, BASE_URL } = process.env
const { webkit, devices } = createRequire(import.meta.url)(PLAYWRIGHT_CORE)

// what iOS below 16.4 lacks (and all that came later) and the reader could
// reach. Syntax can't be taken away: polyfills.test.ts looks for that.
const older = () => {
  const gone = (o, ...names) => names.forEach((n) => delete o[n])
  gone(Object, "groupBy")
  gone(Map, "groupBy")
  gone(Promise, "try")
  gone(Math, "sumPrecise")
  gone(URL, "parse")
  gone(Map.prototype, "getOrInsert", "getOrInsertComputed")
  gone(Uint8Array, "fromBase64", "fromHex")
  gone(Uint8Array.prototype, "toBase64", "toHex")
  gone(AbortSignal, "any")
  gone(Array, "fromAsync")
  gone(Set.prototype, "union", "intersection", "difference", "isSubsetOf", "isSupersetOf", "isDisjointFrom")
  gone(window, "DecompressionStream", "CompressionStream")
  const own = CSSStyleSheet
  window.CSSStyleSheet = function () {
    throw new TypeError("Illegal constructor")
  }
  window.CSSStyleSheet.prototype = own.prototype
}

const browser = await webkit.launch({ executablePath: WEBKIT })

async function check(name, setup, formats, run) {
  const context = await browser.newContext({ ...devices["iPhone 13"] })
  const page = await context.newPage()
  const errors = []
  page.on("pageerror", (e) => errors.push(e.message))
  await setup(page)
  await page.goto(BASE_URL)
  await page.getByRole("link", { name: /./ }).first().waitFor()
  const { books } = await page.evaluate(() => fetch("/api/books?limit=500&sort=title").then((r) => r.json()))
  for (const format of formats) {
    const book = books.find((b) => b.formats.includes(format) && (format === "EPUB" || !b.formats.includes("EPUB")))
    await page.goto(`${BASE_URL}/read/${book.id}?format=${format}`)
    await run(page, format, errors)
    console.log(`ok: ${name}, ${format}`)
  }
  await context.close()
}

const opens = async (page, format, errors) => {
  await page.locator('[data-reader="ready"], [data-reader="failed"]').first().waitFor({ timeout: 30_000 })
  const text = await page.locator("[data-reader]").innerText()
  assert.equal(await page.locator("[data-reader]").getAttribute("data-reader"), "ready", `${format}: ${text}`)
  assert.deepEqual(errors, [])
}

try {
  await check("the hub's policy", () => {}, ["EPUB", "PDF"], opens)
  await check("without what iOS below 16.4 lacks", (page) => page.addInitScript(older), ["EPUB", "PDF"], opens)
  await check("frames out of reach", (page) => page.addInitScript(() => {
    Object.defineProperty(HTMLIFrameElement.prototype, "contentDocument", { get: () => null })
  }), ["EPUB", "PDF"], async (page, format, errors) => {
    await page.locator('[data-reader="failed"]').waitFor({ timeout: 10_000 })
    await page.getByRole("button", { name: "Erneut versuchen" }).waitFor()
    assert.ok(errors.length > 0, format)
    errors.length = 0
  })
} finally {
  await browser.close()
}
