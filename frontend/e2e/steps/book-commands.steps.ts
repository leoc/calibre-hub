import { expect, type Page } from "@playwright/test"
import { createBdd } from "playwright-bdd"

const { Given, Then } = createBdd()

// Commands on the selection and the active book in the palette
// (keyboard.feature, Phase 3). Labels as in src/i18n/de.ts.
const palette = (page: Page) => page.getByRole("dialog", { name: "Suchen und Befehle" })
const selectedOption = (page: Page) => palette(page).locator('[role="option"][aria-selected="true"]')
const toast = (page: Page) => page.getByRole("status", { name: "Meldung" })
const selected = (page: Page) => page.locator('main [data-book-id][aria-checked="true"]')
const activeBook = (page: Page) => page.locator("main [data-book-id][data-active]")

interface MockBook {
  id: number
  title: string
  tags: string[]
}
const fetchBook = (page: Page, id: number): Promise<MockBook | null> =>
  page.evaluate((id) => fetch(`/api/books/${id}`).then((r) => (r.ok ? r.json() : null)), id)
const selectedIds = (page: Page) => selected(page).evaluateAll((els) => els.map((e) => Number(e.getAttribute("data-book-id"))))
const activeId = async (page: Page) => Number(await activeBook(page).getAttribute("data-book-id"))
// the active book of a scenario, also once it is gone from the grid
const remembered = new WeakMap<Page, number>()

Given("I selected all matches", async ({ page }) => {
  await page.getByRole("button", { name: "Auswählen", exact: true }).click()
  const all = page.getByRole("button", { name: /^Alle .* Treffer$/ })
  await all.click()
  await expect(all).toHaveAttribute("aria-pressed", "true")
})

Then("the {int} selected books have the tag {string}", async ({ page }, n: number, tag: string) => {
  const ids = await selectedIds(page)
  expect(ids).toHaveLength(n)
  for (const id of ids) await expect.poll(async () => (await fetchBook(page, id))?.tags).toContain(tag)
})

Then("no selected book has the tag {string}", async ({ page }, tag: string) => {
  for (const id of await selectedIds(page)) await expect.poll(async () => (await fetchBook(page, id))?.tags).not.toContain(tag)
})

Then("a message says {string}", async ({ page }, text: string) => {
  await expect(toast(page)).toContainText(text)
})

Then("the selected entry is {string} for the active book", async ({ page }, label: string) => {
  const book = await fetchBook(page, await activeId(page))
  await expect(selectedOption(page)).toHaveText(`${label}: ${book!.title}`)
})

Then("the palette asks for a value of {string}", async ({ page }, label: string) => {
  await expect(palette(page).getByRole("combobox")).toHaveAttribute("placeholder", new RegExp(`^Wert für „${label}`))
  await expect(palette(page).getByRole("option").first()).toBeVisible()
  // a way back to the commands, large enough to tap
  const back = palette(page).getByRole("button", { name: "Zurück zu den Befehlen" })
  await expect(back).toBeVisible()
})

Then("the active book has the tag {string}", async ({ page }, tag: string) => {
  const id = await activeId(page)
  await expect.poll(async () => (await fetchBook(page, id))?.tags).toContain(tag)
})

Then("the palette asks to delete the active book", async ({ page }) => {
  const id = await activeId(page)
  remembered.set(page, id)
  const book = await fetchBook(page, id)
  await expect(selectedOption(page)).toHaveText(`Ja, „${book!.title}“ löschen`)
})

Then("the active book is gone from the library", async ({ page }) => {
  const id = remembered.get(page)!
  await expect.poll(() => fetchBook(page, id)).toBeNull()
  await expect(page.locator(`main [data-book-id="${id}"]`)).toHaveCount(0)
})

Then("the palette asks to change all matches", async ({ page }) => {
  await expect(selectedOption(page)).toHaveText(/^Ja, auf [\d.]+ Bücher anwenden$/)
})

Then("{string} is offered for all matches again", async ({ page }, label: string) => {
  await expect(selectedOption(page)).toHaveText(new RegExp(`^${label} \\([\\d.]+\\)$`))
})
