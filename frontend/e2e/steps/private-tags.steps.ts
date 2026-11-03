import { expect, type Page } from "@playwright/test"
import { createBdd } from "playwright-bdd"

const { When, Then } = createBdd()

// private-tags.feature. Labels as in src/i18n/de.ts.
const selected = (page: Page) => page.locator('main [data-book-id][aria-checked="true"]')
const selectedIds = (page: Page) => selected(page).evaluateAll((els) => els.map((e) => Number(e.getAttribute("data-book-id"))))
const palette = (page: Page) => page.getByRole("dialog", { name: "Suchen und Befehle" })
const detail = (page: Page) => page.locator("article").filter({ has: page.getByRole("heading", { level: 1 }) })
// the sidebar's section of the user's own tags
const mySection = (page: Page) => page.getByRole("navigation").locator("section").filter({ has: page.getByRole("heading", { name: "Meine Tags" }) })
// the selection bar: the row with "n ausgewählt"
const bar = (page: Page) => page.locator("div.sticky").filter({ has: page.getByRole("button", { name: "Auswahl beenden" }) })

interface MockBook {
  id: number
  tags: string[]
  privateTags?: string[]
}
const fetchBook = (page: Page, id: number): Promise<MockBook | null> =>
  page.evaluate((id) => fetch(`/api/books/${id}`).then((r) => (r.ok ? r.json() : null)), id)

// the open book's id: ?book= on wide screens, /books/:id on narrow ones
const openBookId = (page: Page) => {
  const url = new URL(page.url())
  return Number(url.searchParams.get("book") ?? /\/books\/(\d+)/.exec(url.pathname)?.[1])
}

// --- When -------------------------------------------------------------------

When("I add my tag {string} to the selection", async ({ page }, tag: string) => {
  await bar(page).getByRole("button", { name: "Meine Tags hinzufügen" }).click()
  const dialog = page.getByRole("dialog")
  await dialog.getByRole("combobox", { name: "Meine Tags" }).fill(tag)
  await page.keyboard.press("Enter")
  await dialog.getByRole("button", { name: "Anwenden" }).click()
  await expect(dialog).toBeHidden()
})

When("I click my tag {string} in the sidebar", async ({ page }, tag: string) => {
  await mySection(page).getByRole("link", { name: new RegExp(`^${tag}\\s*\\d+$`) }).click()
})

When("I set my tags in the detail to {string}", async ({ page }, tag: string) => {
  await detail(page).getByRole("button", { name: "Meine Tags ändern" }).click()
  await detail(page).getByRole("combobox", { name: "Meine Tags" }).fill(tag)
  await page.keyboard.press("Enter")
  await detail(page).locator("dl").getByRole("button", { name: "Speichern", exact: true }).click()
})

// --- Then -------------------------------------------------------------------

Then("a message in the selection bar says {string}", async ({ page }, text: string) => {
  await expect(bar(page).getByRole("status")).toContainText(text)
})

Then("the {int} selected books have my tag {string}", async ({ page }, n: number, tag: string) => {
  const ids = await selectedIds(page)
  expect(ids).toHaveLength(n)
  for (const id of ids) await expect.poll(async () => (await fetchBook(page, id))?.privateTags).toContain(tag)
})

Then("the sidebar lists my tag {string} with {int} books", async ({ page }, tag: string, n: number) => {
  await expect(mySection(page).getByRole("link", { name: new RegExp(`^${tag}\\s*${n}$`) })).toBeVisible()
})

Then("there is the filter chip {string}", async ({ page }, label: string) => {
  const [name, value] = label.split(": ")
  await expect(page.getByRole("link", { name: `Filter ${name} ${value} entfernen` })).toBeVisible()
})

Then("the selection bar offers {string}", async ({ page }, name: string) => {
  await expect(bar(page).getByRole("button", { name, exact: true })).toBeVisible()
})

Then("the selection bar doesn't offer {string}", async ({ page }, name: string) => {
  await expect(bar(page).getByRole("button", { name, exact: true })).toHaveCount(0)
})

Then("the palette shows my tag {string} under {string}", async ({ page }, tag: string, heading: string) => {
  const group = palette(page).getByRole("group", { name: heading })
  await expect(group.getByRole("option", { name: new RegExp(`^${tag}`) })).toBeVisible()
  await expect(palette(page).getByRole("option").first()).toContainText(tag)
})

Then("the detail shows my tag {string}", async ({ page }, tag: string) => {
  await expect(detail(page).getByRole("link", { name: tag })).toBeVisible()
})

Then("the book has my tag {string} but not as a tag of the library", async ({ page }, tag: string) => {
  const id = openBookId(page)
  await expect.poll(async () => (await fetchBook(page, id))?.privateTags).toContain(tag)
  expect((await fetchBook(page, id))?.tags).not.toContain(tag)
})
