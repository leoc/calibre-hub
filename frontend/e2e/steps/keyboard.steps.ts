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

// polls both: after a page change the grid may still show the previous page
async function expectActiveAt(page: Page, index: number) {
  await expect
    .poll(async () => {
      const ids = await bookIds(page)
      return (await activeBook(page).getAttribute("data-book-id")) === String(ids[index])
    })
    .toBe(true)
}

const activeBefore = new WeakMap<Page, string | null>()
// set up by "the … book is the active book": its index and reading list toggle
const given = new WeakMap<Page, { index: number; listOn: string | null }>()
const listToggle = (page: Page, index: number) => books(page).nth(index).locator("xpath=..").locator("button[aria-pressed]").first()

// --- Given ------------------------------------------------------------------

Given("the library shows the grid with at least {int} rows of books", async ({ page }, rows: number) => {
  await expect(page.getByRole("radio", { name: "Raster" })).toHaveAttribute("aria-checked", "true")
  const cols = await columns(page)
  expect(await books(page).count()).toBeGreaterThanOrEqual(cols * rows)
})

Given("keyboard mode is {string}", async ({ page, context }, mode: string) => {
  // "y" copies a link
  await context.grantPermissions(["clipboard-read", "clipboard-write"])
  await page.evaluate((m) => localStorage.setItem("hub.keys", m), mode)
  await page.reload()
  await expect(results(page)).toBeVisible()
  // after the app's own listener: was the last key taken from the browser?
  await page.evaluate(() => window.addEventListener("keydown", (e) => (document.body.dataset.keyPrevented = String(e.defaultPrevented))))
})

// the app keys work in both modes
Given("the {word} book is the active book", async ({ page }, word: string) => {
  const n = ordinal(word)
  await page.keyboard.press("Home")
  for (let i = 0; i < n; i++) await page.keyboard.press("ArrowRight")
  await expectActiveAt(page, n)
  given.set(page, { index: n, listOn: await listToggle(page, n).getAttribute("aria-pressed") })
})

Given("I opened the trash page from the library", async ({ page }) => {
  await page.getByRole("link", { name: "Papierkorb" }).click()
  await expect(page).toHaveURL(/\/trash$/)
})

// action labels in the settings (src/i18n/de.ts, keys.a.*)
const ACTION_LABELS: Record<string, string> = { "next book": "Nach unten (im Detail: nächstes Buch)" }

Given("I bind {string} to {string} in the settings", async ({ page }, action: string, keys: string) => {
  await page.getByRole("button", { name: "Tastenbelegung" }).click()
  const dialog = page.getByRole("dialog", { name: /^Tastenbelegung/ })
  const field = dialog.getByLabel(ACTION_LABELS[action], { exact: true })
  await field.fill(`${await field.inputValue()} ${keys}`)
  await dialog.getByRole("button", { name: "Speichern" }).click()
  await expect(dialog).toBeHidden()
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

// --- Phase 2 ------------------------------------------------------------------

When("I type the hint of the {word} book", async ({ page }, word: string) => {
  const id = (await bookIds(page))[ordinal(word)]
  const label = await page.locator(`[data-hint-book="${id}"]`).getAttribute("data-hint")
  expect(label).toBeTruthy()
  await page.keyboard.type(label!)
})

Then("the library is shown", async ({ page }) => {
  await expect(page).toHaveURL(/^[^?]*\/(\?.*)?$/)
  await expect(results(page)).toBeVisible()
})

Then(/^the (trash|metadata|suggestions|lists) page is shown$/, async ({ page }, name: string) => {
  await expect(page).toHaveURL(new RegExp(`/${name}$`))
})

Then("the focus is in the category tree", async ({ page }) => {
  await expect(page.locator('[role="tree"] a:focus')).toHaveCount(1)
})

Then("the library is filtered by the second category", async ({ page }) => {
  await expect(page.getByRole("tree").getByRole("treeitem").nth(1)).toHaveAttribute("aria-selected", "true")
  await expect(page).toHaveURL(/[?&]kategorie=/)
})

Then("every book and link shows a short hint label", async ({ page }) => {
  const hints = page.locator("[data-hint]")
  await expect(hints.first()).toBeVisible()
  const labels = await hints.evaluateAll((els) => els.map((e) => e.getAttribute("data-hint")!))
  expect(new Set(labels).size).toBe(labels.length)
  for (const l of labels) expect(l.length).toBeLessThanOrEqual(2)
  // the books on screen and the sidebar links
  await expect(page.locator(`[data-hint-book="${(await bookIds(page))[0]}"]`)).toHaveCount(1)
  expect(labels.length).toBeGreaterThan(await page.locator("main [data-hint-book]").count())
})

Then("the {word} book is selected", async ({ page }, word: string) => {
  await expect(books(page).nth(ordinal(word))).toHaveAttribute("aria-checked", "true")
})

Then("the edit form of the {word} book is open", async ({ page }, word: string) => {
  const id = (await bookIds(page))[ordinal(word)]
  await expect(page).toHaveURL(new RegExp(`[?&]book=${id}(&|$)`))
  await expect(page).toHaveURL(/[?&]edit=/)
  await expect(page.getByRole("form", { name: "Buch bearbeiten" })).toBeVisible()
})

Then("the {word} book's reading list toggle flips", async ({ page }, word: string) => {
  const before = given.get(page)!
  expect(before.index).toBe(ordinal(word))
  await expect(listToggle(page, before.index)).toHaveAttribute("aria-pressed", before.listOn === "true" ? "false" : "true")
})

Then("a delete confirmation for the {word} book opens", async ({ page }, word: string) => {
  const title = await books(page).nth(ordinal(word)).locator("p").first().textContent()
  const dialog = page.getByRole("dialog", { name: "Buch löschen?" })
  await expect(dialog).toBeVisible()
  await expect(dialog).toContainText(title!)
})

Then("the link to the {word} book is in the clipboard", async ({ page }, word: string) => {
  const id = (await bookIds(page))[ordinal(word)]
  await expect(keyStatus(page)).toContainText("Link kopiert")
  const text = await page.evaluate(() => navigator.clipboard.readText())
  expect(text).toBe(new URL(`/books/${id}`, page.url()).href)
})

Then("an overlay lists the keys of the current mode", async ({ page }) => {
  const dialog = page.getByRole("dialog", { name: "Tastenhilfe" })
  await expect(dialog).toBeVisible()
  await expect(dialog).toContainText("Modus App")
  await expect(dialog.getByRole("row", { name: /^Nach unten/ })).toContainText("↓")
  // no Vim keys in App mode
  await expect(dialog.getByRole("row", { name: /^Erstes Buch/ })).not.toContainText("g g")
})

Then("the overlay is closed", async ({ page }) => {
  await expect(page.getByRole("dialog", { name: "Tastenhilfe" })).toBeHidden()
})

// --- reading lists ------------------------------------------------------------

const listIdOf = async (page: Page, name: string): Promise<number> => {
  const all: { id: number; name: string }[] = await page.evaluate(() => fetch("/api/lists").then((r) => r.json()))
  return all.find((l) => l.name === name)!.id
}
const listsOf = (page: Page, id: number): Promise<number[]> => page.evaluate((id) => fetch(`/api/books/${id}`).then((r) => r.json()).then((b) => b.lists), id)

Then("the browser did not handle the key itself", async ({ page }) => {
  await expect(page.locator("body")).toHaveAttribute("data-key-prevented", "true")
})

Then("the {word} book is in the list {string}", async ({ page }, word: string, name: string) => {
  const [id, list] = [(await bookIds(page))[ordinal(word)], await listIdOf(page, name)]
  await expect.poll(() => listsOf(page, id)).toContain(list)
})

Then("the {word} book is not in the list {string}", async ({ page }, word: string, name: string) => {
  const [id, list] = [(await bookIds(page))[ordinal(word)], await listIdOf(page, name)]
  await expect.poll(() => listsOf(page, id)).not.toContain(list)
})

Then("the {int} selected books are in the list {string}", async ({ page }, n: number, name: string) => {
  const ids = await selected(page).evaluateAll((els) => els.map((e) => Number(e.getAttribute("data-book-id"))))
  expect(ids).toHaveLength(n)
  const list = await listIdOf(page, name)
  for (const id of ids) await expect.poll(() => listsOf(page, id)).toContain(list)
})

Then("the dialog {string} opens for the {word} book", async ({ page }, title: string, word: string) => {
  const book = await books(page).nth(ordinal(word)).locator("p").first().textContent()
  const dialog = page.getByRole("dialog", { name: title })
  await expect(dialog).toBeVisible()
  await expect(dialog).toContainText(book!)
})

Then("the active book moves down by one row", async ({ page }) => {
  const cols = await columns(page)
  await expectActiveAt(page, given.get(page)!.index + cols)
})
