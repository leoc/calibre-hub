import { expect, type Page } from "@playwright/test"
import { createBdd } from "playwright-bdd"
import fs from "node:fs"
import path from "node:path"

const { Given, When, Then } = createBdd()

// Labels as in src/i18n/de.ts. The mock state (positions) lives in the
// page, so the steps navigate inside the app after the first page load.
const READER_FORMATS = ["EPUB", "KEPUB", "AZW3", "MOBI", "AZW", "FB2", "CBZ", "PDF"]

const books = new WeakMap<Page, number>()
const saved = new WeakMap<Page, number>()
const bookOf = (page: Page) => {
  const id = books.get(page)
  if (id == null) throw new Error("no book chosen")
  return id
}

const progressbar = (page: Page) => page.locator("[data-reader]").getByRole("progressbar", { name: "Lesefortschritt" })
const shownPercent = async (page: Page) => Number(await progressbar(page).getAttribute("aria-valuenow"))

// the first book the reader opens in this format
async function openDetail(page: Page, format: string) {
  const all = await page.evaluate(() => fetch("/api/books?limit=500&sort=title").then((r) => r.json()))
  const book = all.books.find((b: { formats: string[] }) => READER_FORMATS.find((f) => b.formats.includes(f)) === format)
  if (!book) throw new Error(`no book read as ${format}`)
  books.set(page, book.id)
  await page.goto(`/?book=${book.id}`)
  await expect(page.getByRole("heading", { level: 1, name: book.title })).toBeVisible()
}

// remembers where the book opened (foliate-js counts the first page in)
const opened = new WeakMap<Page, number>()
async function waitForReader(page: Page) {
  await expect(page.locator('[data-reader="ready"]')).toBeVisible({ timeout: 15_000 })
  opened.set(page, await shownPercent(page))
}

// --- Given ------------------------------------------------------------------

Given("the detail of a book with the format {string} is open", async ({ page }, format: string) => {
  await openDetail(page, format)
})

Given("the reader is open for a book with the format {string}", async ({ page }, format: string) => {
  await openDetail(page, format)
  await page.getByRole("link", { name: /^(Lesen|Weiterlesen)/ }).click()
  await waitForReader(page)
})

Given("the book's file stops coming after its first bytes", async ({ page }) => {
  await page.evaluate(() => localStorage.setItem("hub.mock.stall", "1"))
})

// what WebKit did to every book frame under `frame-ancestors 'none'`: the load
// event comes, the document can't be reached, foliate-js throws in the handler
Given("the book's frames can't be reached", async ({ page }) => {
  await page.evaluate(() => {
    const own = Object.getOwnPropertyDescriptor(HTMLIFrameElement.prototype, "contentDocument")!
    const w = window as unknown as { __noFrames: boolean }
    w.__noFrames = true
    Object.defineProperty(HTMLIFrameElement.prototype, "contentDocument", { configurable: true, get() { return w.__noFrames ? null : own.get!.call(this) } })
  })
})

Given("the device {string} saved the position {int} % for the book", async ({ page }, name: string, pct: number) => {
  const status = await page.evaluate(
    ([id, name, fraction]) =>
      fetch(`/api/books/${id}/progress`, {
        method: "PUT",
        headers: { "Content-Type": "application/json", "X-Calibre-Hub": "1" },
        body: JSON.stringify({ format: "epub", position: "", fraction, device: `other-${name}`, deviceName: name }),
      }).then((r) => r.status),
    [bookOf(page), name, pct / 100] as const,
  )
  expect(status).toBe(200)
})

// A book without formats gets the fixture file (e2e/fixtures) as its only
// format (the mocks keep uploaded files); then the reader opens inside the
// app, since a page load would reset the mocks. Requests to /api/pwned are
// what the scripts in script.epub would send.
const pwned = new WeakMap<Page, string[]>()
Given("the reader is open for the book file {string} as {string}", async ({ page }, file: string, format: string) => {
  const hits: string[] = []
  pwned.set(page, hits)
  page.on("request", (r) => {
    if (r.url().includes("/api/pwned")) hits.push(r.url())
  })
  const data = fs.readFileSync(path.join(import.meta.dirname, "../fixtures", file)).toString("base64")
  const id = await page.evaluate(
    async ([data, ext]) => {
      const all = await fetch("/api/books?limit=500&sort=title").then((r) => r.json())
      const book = all.books.find((b: { formats: string[] }) => b.formats.length === 0)
      const form = new FormData()
      form.append("file", new File([Uint8Array.from(atob(data), (c) => c.charCodeAt(0))], `book.${ext}`))
      form.append("addFormatTo", String(book.id))
      const res = await fetch("/api/books", { method: "POST", headers: { "X-Calibre-Hub": "1" }, body: form })
      if (!res.ok) throw new Error(`upload ${res.status}`)
      return book.id as number
    },
    [data, format.toLowerCase()] as const,
  )
  books.set(page, id)
  await page.evaluate((id) => {
    history.pushState({}, "", `/read/${id}`)
    dispatchEvent(new PopStateEvent("popstate"))
  }, id)
  await waitForReader(page)
})

// --- When -------------------------------------------------------------------

When("I click the link {string} in the detail", async ({ page }, label: string) => {
  await page.getByRole("link", { name: label, exact: true }).click()
  await waitForReader(page)
})

When("I click the continue button in the detail", async ({ page }) => {
  await page.getByRole("link", { name: /^Weiterlesen \(\d+ %\)$/ }).click()
  await waitForReader(page)
})

When("I press {string} in the reader {int} times", async ({ page }, key: string, n: number) => {
  for (let i = 0; i < n; i++) {
    const before = await shownPercent(page)
    await page.keyboard.press(key)
    // one page turn at a time (the slide animation)
    await expect.poll(() => shownPercent(page), { timeout: 3000 }).not.toBe(before).catch(() => {})
    await page.waitForTimeout(150)
  }
})

When("I press {string} in the reader", async ({ page }, key: string) => {
  await page.keyboard.press(key)
})

When("I click {string} in the reader", async ({ page }, label: string) => {
  await page.getByRole("button", { name: label, exact: true }).click()
})

const tapAt = async (page: Page, x: number) => {
  const box = (await page.locator("[data-reader] main").boundingBox())!
  await page.mouse.click(box.x + box.width * x, box.y + box.height / 2)
  // without the slide animation foliate-js ignores turns for 100 ms after one
  await page.waitForTimeout(300)
}

When("I tap the right third of the page", async ({ page }) => tapAt(page, 0.85))
When("I tap the left third of the page", async ({ page }) => tapAt(page, 0.15))
When("I tap the middle of the page", async ({ page }) => tapAt(page, 0.5))

When("I start reading from the detail", async ({ page }) => {
  await page.getByRole("link", { name: /^(Lesen|Weiterlesen)/ }).click()
})

When("I open the reader from the detail", async ({ page }) => {
  await page.getByRole("link", { name: /^(Lesen|Weiterlesen)/ }).click()
  await waitForReader(page)
})

When("the book's file comes again", async ({ page }) => {
  await page.evaluate(() => localStorage.removeItem("hub.mock.stall"))
})

When("the book's frames can be reached again", async ({ page }) => {
  await page.evaluate(() => ((window as unknown as { __noFrames: boolean }).__noFrames = false))
})

When("I make the book available offline", async ({ page }) => {
  await page.getByRole("button", { name: "Offline verfügbar machen", exact: true }).click()
  await expect(page.locator("[data-offline-size]")).toBeVisible()
})

// navigator.onLine false and no network; the mocks fail /api/ then too
When("the connection is lost", async ({ context }) => {
  await context.setOffline(true)
})

When("the connection is back", async ({ context }) => {
  await context.setOffline(false)
})

// --- Then -------------------------------------------------------------------

Then("the detail shows the book as available offline with its size", async ({ page }) => {
  await expect(page.locator("[data-offline-size]")).toHaveText(/Offline verfügbar · [\d,]+ (B|KB|MB)/)
  const stored = await page.evaluate(async (id) => {
    const res = await caches.match(`/api/books/${id}/download/epub`, { cacheName: "hub-books" })
    return res ? (await res.blob()).size : 0
  }, bookOf(page))
  expect(stored).toBeGreaterThan(0)
})

Then("the detail offers to make the book available offline", async ({ page }) => {
  await expect(page.getByRole("button", { name: "Offline verfügbar machen", exact: true })).toBeVisible()
  const stored = await page.evaluate((id) => caches.match(`/api/books/${id}/download/epub`, { cacheName: "hub-books" }).then((r) => !!r), bookOf(page))
  expect(stored).toBe(false)
})

Then("the app shows that it is offline", async ({ page }) => {
  // wide: behind the detail's dialog, so not in the accessibility tree
  await expect(page.locator('body > div header [role="status"]', { hasText: "Offline" })).toBeAttached()
})

Then("the reader shows that it is offline", async ({ page }) => {
  await expect(page.locator("[data-reader] header").getByRole("status").filter({ hasText: "Offline" })).toBeAttached()
})

Then("this device's position waits for the connection", async ({ page }) => {
  const pct = await shownPercent(page)
  expect(pct).toBeGreaterThan(0)
  await expect
    .poll(
      () =>
        page.evaluate((id) => {
          const q = JSON.parse(localStorage.getItem("hub.progressQueue") ?? "{}")
          return q[id] ? Math.floor(q[id].save.fraction * 100) : null
        }, bookOf(page)),
      { timeout: 10_000 },
    )
    .toBe(pct)
  saved.set(page, pct)
})

Then("the hub has this device's position from offline", async ({ page }) => {
  const device = await page.evaluate(() => localStorage.getItem("hub.device"))
  await expect
    .poll(
      () =>
        page.evaluate(
          ([id, device]) =>
            fetch(`/api/books/${id}/progress`)
              .then((r) => r.json())
              .then((p) => {
                const d = p.devices.find((d: { device: string }) => d.device === device)
                return d ? Math.floor(d.fraction * 100) : null
              })
              .catch(() => null),
          [bookOf(page), device] as const,
        ),
      { timeout: 10_000 },
    )
    .toBe(saved.get(page))
  await expect.poll(() => page.evaluate(() => localStorage.getItem("hub.progressQueue"))).toBeNull()
})

Then("the book opens in the reader", async ({ page }) => waitForReader(page))

Then("the reader gives up with {string}", async ({ page }, text: string) => {
  const failed = page.locator('[data-reader="failed"]')
  await expect(failed).toBeVisible({ timeout: 45_000 })
  await expect(failed.getByRole("alert")).toHaveText("Das Buch ließ sich nicht öffnen.")
  await expect(failed).toContainText(text)
  await expect(failed.getByRole("button", { name: "Erneut versuchen" })).toBeVisible()
})

Then("the reader shows the book at {int} %", async ({ page }, pct: number) => {
  await expect(progressbar(page)).toHaveAttribute("aria-valuenow", String(pct))
})

Then("the reading progress is above {int} %", async ({ page }, pct: number) => {
  await expect.poll(() => shownPercent(page)).toBeGreaterThan(Math.max(pct, opened.get(page) ?? 0))
})

Then("the reader shows the first page", async ({ page }) => {
  await expect(progressbar(page)).toHaveAttribute("aria-valuenow", String(opened.get(page)))
  await expect(page.locator("[data-reader] footer")).toContainText("Kapitel 1")
})

Then("the reader shows the chapter {string}", async ({ page }, chapter: string) => {
  await expect(page.locator("[data-reader] footer")).toContainText(chapter)
})

Then("this device's position is saved", async ({ page }) => {
  const pct = await shownPercent(page)
  expect(pct).toBeGreaterThan(0)
  const device = await page.evaluate(() => localStorage.getItem("hub.device"))
  await expect
    .poll(
      () =>
        page.evaluate(
          ([id, device]) =>
            fetch(`/api/books/${id}/progress`)
              .then((r) => r.json())
              .then((p) => p.devices.find((d: { device: string }) => d.device === device)?.fraction ?? null),
          [bookOf(page), device] as const,
        ),
      { timeout: 10_000 },
    )
    .not.toBeNull()
  saved.set(page, pct)
})

Then("the detail offers to continue at the saved percentage", async ({ page }) => {
  await expect(page.getByRole("link", { name: `Weiterlesen (${saved.get(page)} %)`, exact: true })).toBeVisible()
})

Then("the reader shows the book at the saved percentage", async ({ page }) => {
  await expect(progressbar(page)).toHaveAttribute("aria-valuenow", String(saved.get(page)))
})

Then("the reader asks {string}", async ({ page }, text: string) => {
  await expect(page.getByRole("alertdialog", { name: text })).toBeVisible()
})

// what foliate-js' isWebKit() looks for besides iOS; then the app starts
// again with it
Given("the reader takes the browser for WebKit", async ({ page }) => {
  await page.addInitScript(() => Object.defineProperty(window, "GestureEvent", { value: class GestureEvent extends UIEvent {} }))
  await page.reload()
  await page.waitForFunction(() => navigator.serviceWorker?.controller != null)
})

// the book's pages: blob: frames inside foliate-js' closed shadow roots
const bookFrames = (page: Page) => page.frames().filter((f) => f !== page.mainFrame() && f.url().startsWith("blob:"))

Then("the book's pages are sandboxed with {string}", async ({ page }, sandbox: string) => {
  await expect.poll(() => bookFrames(page).length).toBeGreaterThan(0)
  for (const f of bookFrames(page)) expect(await (await f.frameElement()).getAttribute("sandbox")).toBe(sandbox)
})

Then("the book's pages carry the policy {string}", async ({ page }, policy: string) => {
  await expect.poll(() => bookFrames(page).length).toBeGreaterThan(0)
  for (const f of bookFrames(page)) {
    const csp = await f.evaluate(() => document.querySelector('meta[http-equiv="Content-Security-Policy"]')?.getAttribute("content") ?? null)
    expect(csp).toContain(policy)
  }
})

Then("no script from the book has run", async ({ page }) => {
  // the handlers would have fired on load; give late ones a moment
  await page.waitForTimeout(500)
  const marks = await page.evaluate(() => ({ storage: localStorage.getItem("pwned"), global: (window as unknown as { pwned?: string }).pwned ?? null }))
  expect(marks).toEqual({ storage: null, global: null })
  expect(pwned.get(page)).toEqual([])
})

Then("the reader's toolbar is hidden", async ({ page }) => {
  await expect(page.getByRole("button", { name: "Zurück zum Buch" })).toHaveCount(0)
})

Then("the reader's toolbar is shown", async ({ page }) => {
  await expect(page.getByRole("button", { name: "Zurück zum Buch" })).toBeVisible()
})
