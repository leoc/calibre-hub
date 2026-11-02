import { expect, type Page } from "@playwright/test"
import { createBdd } from "playwright-bdd"

const { Given, When, Then } = createBdd()

// Labels as in src/i18n/de.ts. The mock state lives in the page, so the
// steps navigate inside the app instead of reloading.
const isWide = (page: Page) => page.viewportSize()!.width >= 640
const palette = (page: Page) => page.getByRole("dialog", { name: "Suchen und Befehle" })
const saveDialog = (page: Page) => page.getByRole("dialog", { name: "In Listen speichern" })

interface ListInfo {
  id: number
  name: string
}
// the book a scenario works with
const books = new WeakMap<Page, number>()
const bookOf = (page: Page) => {
  const id = books.get(page)
  if (id == null) throw new Error("no book chosen")
  return id
}

const lists = (page: Page): Promise<ListInfo[]> => page.evaluate(() => fetch("/api/lists").then((r) => r.json()))
async function listId(page: Page, name: string) {
  const l = (await lists(page)).find((x) => x.name === name)
  if (!l) throw new Error(`no list ${name}`)
  return l.id
}
const bookLists = (page: Page, id: number): Promise<number[]> =>
  page.evaluate((id) => fetch(`/api/books/${id}`).then((r) => r.json()).then((b) => b.lists), id)

const cover = (page: Page) => page.locator(`main li:has(a[href$="book=${bookOf(page)}"])`)
const bookmark = (page: Page) => cover(page).getByRole("button", { name: /Leseliste/ })

async function openPalette(page: Page) {
  if (isWide(page)) await page.getByRole("button", { name: "Command-Palette öffnen" }).click()
  else await page.getByRole("banner").getByLabel("Suchen …", { exact: true }).click()
  await expect(palette(page)).toBeVisible()
}

const resultCount = (n: number) => (n === 1 ? "1 Buch" : `${n} Bücher`)

// --- Given ------------------------------------------------------------------

Given("a book on the first page that is not in {string}", async ({ page }, name: string) => {
  const id = await listId(page, name)
  const page1 = await page.evaluate(() => fetch("/api/books?sort=added&order=desc&limit=60").then((r) => r.json()))
  const book = page1.books.find((b: { lists: number[] }) => !b.lists.includes(id))
  books.set(page, book.id)
  await expect(cover(page)).toBeVisible()
})

Given("the detail of a book is open", async ({ page }) => {
  books.set(page, 7)
  await page.goto("/?book=7")
  await expect(page.getByRole("heading", { level: 1 })).toBeVisible()
})

Given("I select the first {int} books", async ({ page }, n: number) => {
  const start = page.getByRole("button", { name: "Auswählen", exact: true })
  if ((await start.getAttribute("aria-pressed")) !== "true") await start.click()
  const boxes = page.locator("main [role=checkbox]")
  for (let i = 0; i < n; i++) await boxes.nth(i).click()
  await expect(page.getByText(`${n} ausgewählt`)).toBeVisible()
})

// --- When -------------------------------------------------------------------

When("I tap the bookmark on its cover", async ({ page }) => {
  await bookmark(page).click()
})

When("I right-click the bookmark on its cover", async ({ page }) => {
  await bookmark(page).click({ button: "right" })
})

When("I long-press the bookmark on its cover", async ({ page }) => {
  // a handle: once the dialog is open the page behind it is aria-hidden
  const b = (await bookmark(page).elementHandle())!
  await b.dispatchEvent("pointerdown", { button: 0, pointerType: "touch", isPrimary: true })
  await page.waitForTimeout(700)
  await b.dispatchEvent("pointerup", { button: 0, pointerType: "touch", isPrimary: true })
})

When("I check {string} in the dialog", async ({ page }, name: string) => {
  await saveDialog(page).getByRole("checkbox", { name: new RegExp(`^${name}`) }).check()
})

When("I click {string} in the detail", async ({ page }, label: string) => {
  await page.getByRole("button", { name: label, exact: true }).click()
})

When("I create the list {string} in the dialog", async ({ page }, name: string) => {
  const dialog = saveDialog(page)
  await dialog.getByRole("button", { name: "Neue Liste" }).click()
  await dialog.getByRole("textbox", { name: "Name der neuen Liste" }).fill(name)
  await dialog.getByRole("button", { name: "Anlegen" }).click()
})

When("I open the list {string}", async ({ page }, name: string) => {
  await openPalette(page)
  await palette(page).getByRole("combobox").pressSequentially(`l ${name}`)
  await palette(page).getByRole("option", { name: new RegExp(`^${name}\\s*\\d`) }).click()
  await expect(page.getByRole("heading", { level: 1, name })).toBeVisible()
})

When("I add the selection to the list {string}", async ({ page }, name: string) => {
  await page.getByRole("button", { name: "Zu Liste" }).click()
  const dialog = page.getByRole("dialog")
  await dialog.getByRole("radio", { name: new RegExp(`^${name}`) }).check()
  await dialog.getByRole("button", { name: "Anwenden" }).click()
})

When("I remove the selection from this list", async ({ page }) => {
  await page.getByRole("button", { name: "Aus dieser Liste" }).click()
})

// --- Then -------------------------------------------------------------------

Then("the bookmark on its cover is set", async ({ page }) => {
  await expect(bookmark(page)).toHaveAttribute("aria-pressed", "true")
})

Then("the book is in the list {string}", async ({ page }, name: string) => {
  const id = await listId(page, name)
  await expect.poll(() => bookLists(page, bookOf(page))).toContain(id)
})

Then("the book is not in the list {string}", async ({ page }, name: string) => {
  const id = await listId(page, name)
  await expect.poll(() => bookLists(page, bookOf(page))).not.toContain(id)
})

Then("the dialog {string} opens with a checkbox per list", async ({ page }, title: string) => {
  const dialog = page.getByRole("dialog", { name: title })
  await expect(dialog).toBeVisible()
  await expect(dialog.getByRole("checkbox")).toHaveCount((await lists(page)).length)
})

Then("{string} is checked in the dialog", async ({ page }, name: string) => {
  await expect(saveDialog(page).getByRole("checkbox", { name: new RegExp(`^${name}`) })).toBeChecked()
})

Then("the detail has the button {string}", async ({ page }, label: string) => {
  await expect(page.getByRole("button", { name: label, exact: true })).toBeVisible()
})

Then("the sidebar section {string} shows {string}, {string}, {string} in this order", async ({ page }, section: string, a: string, b: string, c: string) => {
  const links = page.getByRole("navigation").getByRole("list", { name: section }).getByRole("link")
  await expect(links).toHaveText([new RegExp(`^${a}`), new RegExp(`^${b}`), new RegExp(`^${c}`)])
})

Then("I see the heading {string}", async ({ page }, name: string) => {
  await expect(page.getByRole("heading", { level: 1, name })).toBeVisible()
})

Then("I see the text {string}", async ({ page }, text: string) => {
  await expect(page.getByText(text, { exact: true }).first()).toBeVisible()
})

Then("the sort is {string}", async ({ page }, label: string) => {
  const select = page.getByRole("combobox", { name: "Sortierung" })
  await expect(select.locator("option:checked")).toHaveText(label)
})

Then("the library shows {int} books", async ({ page }, n: number) => {
  await expect(page.locator("main").getByText(resultCount(n), { exact: true }).last()).toBeVisible()
  await expect(page.locator("main li.group")).toHaveCount(n)
})

Then("the palette suggests the list {string}", async ({ page }, name: string) => {
  await expect(palette(page).getByRole("option", { name: new RegExp(`^${name}`) }).first()).toBeVisible()
})

Then("the list {string} exists", async ({ page }, name: string) => {
  expect((await lists(page)).map((l) => l.name)).toContain(name)
})

Then("the bulk bar says {string}", async ({ page }, text: string) => {
  await expect(page.getByRole("status").filter({ hasText: text })).toBeVisible()
})
