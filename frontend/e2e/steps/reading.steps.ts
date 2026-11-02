import { expect, type Page } from "@playwright/test"
import { createBdd } from "playwright-bdd"

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

// --- Then -------------------------------------------------------------------

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

Then("the reader's toolbar is hidden", async ({ page }) => {
  await expect(page.getByRole("button", { name: "Zurück zum Buch" })).toHaveCount(0)
})

Then("the reader's toolbar is shown", async ({ page }) => {
  await expect(page.getByRole("button", { name: "Zurück zum Buch" })).toBeVisible()
})
