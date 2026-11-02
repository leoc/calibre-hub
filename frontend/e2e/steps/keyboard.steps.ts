import { expect, type Page } from "@playwright/test"
import { createBdd } from "playwright-bdd"

const { Given, When, Then } = createBdd()

// Labels as in src/i18n/de.ts
const books = (page: Page) => page.locator("main [data-book-id]")
const activeBook = (page: Page) => page.locator("main [data-book-id][data-active]")
const searchBar = (page: Page) => page.getByRole("banner").getByLabel("Suchen …", { exact: true })
const palette = (page: Page) => page.getByRole("dialog", { name: "Suchen und Befehle" })
const results = (page: Page) => page.getByText(/^\d+ Bücher$|^1 Buch$|^Keine Bücher gefunden\.$/)
const keyStatus = (page: Page) => page.getByRole("status", { name: "Tastaturbefehl" })
const selected = (page: Page) => page.locator('main [data-book-id][aria-checked="true"]')

const ORDINALS: Record<string, number> = { first: 0, second: 1, third: 2, fourth: 3 }
const ordinal = (word: string) => {
  expect(Object.keys(ORDINALS)).toContain(word)
  return ORDINALS[word]
}

async function bookIds(page: Page): Promise<number[]> {
  await expect(books(page).first()).toBeVisible()
  return books(page).evaluateAll((els) => els.map((e) => Number(e.getAttribute("data-book-id"))))
}

// books on the first row of the grid
async function columns(page: Page): Promise<number> {
  await expect(books(page).first()).toBeVisible()
  return books(page).evaluateAll((els) => {
    const top = els[0].getBoundingClientRect().top
    return els.filter((e) => Math.abs(e.getBoundingClientRect().top - top) < 4).length
  })
}

async function expectActiveAt(page: Page, index: number) {
  const ids = await bookIds(page)
  await expect(activeBook(page)).toHaveAttribute("data-book-id", String(ids[index]))
}

const activeBefore = new WeakMap<Page, string | null>()

// --- Given ------------------------------------------------------------------

Given("the library shows the grid with at least {int} rows of books", async ({ page }, rows: number) => {
  await expect(page.getByRole("radio", { name: "Raster" })).toHaveAttribute("aria-checked", "true")
  const cols = await columns(page)
  expect(await books(page).count()).toBeGreaterThanOrEqual(cols * rows)
})

Given("keyboard mode is {string}", async ({ page }, mode: string) => {
  await page.evaluate((m) => localStorage.setItem("hub.keys", m), mode)
  await page.reload()
  await expect(results(page)).toBeVisible()
})

// the app keys work in both modes
Given("the {word} book is the active book", async ({ page }, word: string) => {
  const n = ordinal(word)
  await page.keyboard.press("Home")
  for (let i = 0; i < n; i++) await page.keyboard.press("ArrowRight")
  await expectActiveAt(page, n)
})

Given("I selected {int} books", async ({ page }, n: number) => {
  await page.getByRole("button", { name: "Auswählen", exact: true }).click()
  for (let i = 0; i < n; i++) await books(page).nth(i).click()
  await expect(selected(page)).toHaveCount(n)
})

Given("nothing is selected", async ({ page }) => {
  await expect(selected(page)).toHaveCount(0)
})

Given("I am typing in the search bar", async ({ page }) => {
  activeBefore.set(page, await activeBook(page).getAttribute("data-book-id", { timeout: 500 }).catch(() => null))
  await searchBar(page).click()
})

// --- When -------------------------------------------------------------------

When("I type {string}", async ({ page }, text: string) => {
  await page.keyboard.type(text)
})

When("I run the command {string} in the command palette", async ({ page }, command: string) => {
  await page.keyboard.press("Control+k")
  await expect(palette(page)).toBeVisible()
  await palette(page).getByRole("combobox").fill(`>${command}`)
  await expect(palette(page).getByRole("option", { name: command })).toBeVisible()
  await page.keyboard.press("Enter")
  await expect(palette(page)).toBeHidden()
})

// --- Then -------------------------------------------------------------------

Then("the active book is the {word} book", async ({ page }, word: string) => {
  await expectActiveAt(page, ordinal(word))
})

Then("the active book has a visible focus ring", async ({ page }) => {
  await expect(activeBook(page)).toBeFocused()
  const outline = await activeBook(page).evaluate((el) => {
    const s = getComputedStyle(el)
    return { style: s.outlineStyle, width: parseFloat(s.outlineWidth) }
  })
  expect(outline.style).not.toBe("none")
  expect(outline.width).toBeGreaterThanOrEqual(2)
})

Then("the active book is the {word} book of the {word} row", async ({ page }, col: string, row: string) => {
  const cols = await columns(page)
  await expectActiveAt(page, ordinal(row) * cols + ordinal(col))
})

Then("the active book is in the {word} row", async ({ page }, row: string) => {
  const cols = await columns(page)
  const ids = await bookIds(page)
  const id = Number(await activeBook(page).getAttribute("data-book-id"))
  expect(Math.floor(ids.indexOf(id) / cols)).toBe(ordinal(row))
})

Then("the last book of the page is the active book", async ({ page }) => {
  const ids = await bookIds(page)
  await expectActiveAt(page, ids.length - 1)
})

Then("the library shows page {int}", async ({ page }, n: number) => {
  if (n === 1) await expect(page).not.toHaveURL(/[?&]page=/)
  else await expect(page).toHaveURL(new RegExp(`[?&]page=${n}(&|$)`))
  await expect(page.getByRole("navigation", { name: new RegExp(`^Seiten, Seite ${n} von`) })).toBeVisible()
})

Then("the detail of the {word} book is open", async ({ page }, word: string) => {
  const ids = await bookIds(page)
  const id = ids[ordinal(word)]
  await expect(page).toHaveURL(new RegExp(`[?&]book=${id}(&|$)`))
  const title = await books(page).nth(ordinal(word)).locator("p").first().textContent()
  await expect(page.getByRole("dialog").getByRole("heading", { level: 1 })).toHaveText(title!)
})

Then("the detail is closed", async ({ page }) => {
  await expect(page.getByRole("dialog")).toBeHidden()
  await expect(page).not.toHaveURL(/[?&]book=/)
})

Then("selection mode is on", async ({ page }) => {
  await expect(page.getByRole("button", { name: "Auswählen", exact: true })).toHaveAttribute("aria-pressed", "true")
})

Then("{int} book(s) is/are selected", async ({ page }, n: number) => {
  await expect(selected(page)).toHaveCount(n)
})

Then("{int} books are still selected", async ({ page }, n: number) => {
  await expect(selected(page)).toHaveCount(n)
})

Then("no book is selected", async ({ page }) => {
  await expect(selected(page)).toHaveCount(0)
})

Then("all books of the page are selected", async ({ page }) => {
  const n = (await bookIds(page)).length
  await expect(selected(page)).toHaveCount(n)
})

Then("visual mode is shown in the status line", async ({ page }) => {
  await expect(keyStatus(page)).toContainText("VISUELL")
})

Then("visual mode is off", async ({ page }) => {
  await expect(keyStatus(page)).toBeHidden()
})

Then("the command palette opens in command mode", async ({ page }) => {
  await expect(palette(page)).toBeVisible()
  await expect(palette(page).getByRole("combobox")).toHaveValue(">")
})

Then("it offers {string}, {string} and {string}", async ({ page }, a: string, b: string, c: string) => {
  for (const name of [a, b, c]) await expect(palette(page).getByRole("option", { name, exact: true })).toBeVisible()
})

Then("it offers the general commands", async ({ page }) => {
  for (const name of ["Alle Bücher", "Papierkorb", "Raster", "Liste", "Tastatur: Vim"]) {
    await expect(palette(page).getByRole("option", { name, exact: true })).toBeVisible()
  }
  await expect(palette(page).getByRole("option", { name: /\(\d+\)$/ })).toHaveCount(0)
})

Then("the first result is the active book", async ({ page }) => {
  await expect(books(page).first()).toHaveAttribute("data-active")
})

Then("the focus is on the book list", async ({ page }) => {
  await expect(activeBook(page)).toBeFocused()
})

Then("the search bar contains {string}", async ({ page }, text: string) => {
  await expect(searchBar(page)).toHaveValue(text)
})

Then("the active book has not changed", async ({ page }) => {
  const before = activeBefore.get(page) ?? null
  const now = await activeBook(page).getAttribute("data-book-id", { timeout: 500 }).catch(() => null)
  expect(now).toBe(before)
})

Then("the keyboard mode setting shows {string}", async ({ page }, mode: string) => {
  await expect(page.getByRole("radiogroup", { name: "Tastatur" }).getByRole("radio", { name: mode, exact: false })).toHaveAttribute("aria-checked", "true")
})

Then("it is still {string} after a reload", async ({ page }, mode: string) => {
  await page.reload()
  await expect(results(page)).toBeVisible()
  await expect(page.getByRole("radiogroup", { name: "Tastatur" }).getByRole("radio", { name: mode, exact: false })).toHaveAttribute("aria-checked", "true")
})
