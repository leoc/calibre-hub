import { expect, type Page } from "@playwright/test"
import { createBdd } from "playwright-bdd"

const { When, Then } = createBdd()

// Labels as in src/i18n/de.ts. The mock state lives in the page: the page
// is opened once per scenario, then the steps stay inside the app.

interface Book {
  id: number
  title: string
  formats: string[]
  publisher: string | null
}
// the books of the merge in a scenario
const merged = new WeakMap<Page, { keep: Book; other: Book }>()
const mergeOf = (page: Page) => {
  const m = merged.get(page)
  if (!m) throw new Error("nothing merged")
  return m
}

const group = (page: Page, title: string) => page.getByRole("main").getByRole("listitem", { name: new RegExp(`^Mögliche Duplikate: ${title.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`) })
const apiGet = <T>(page: Page, path: string): Promise<T> => page.evaluate((p) => fetch(p).then((r) => r.json()), path)

When("I open the duplicates page", async ({ page }) => {
  await page.goto("/duplicates")
  await expect(page.getByRole("heading", { level: 1, name: "Duplikate" })).toBeVisible()
})

Then("I see the group {string} with the reasons {string} and {string}", async ({ page }, title: string, a: string, b: string) => {
  const g = group(page, title)
  await expect(g).toBeVisible()
  await expect(g.locator("[data-slot=badge]", { hasText: a })).toBeVisible()
  await expect(g.locator("[data-slot=badge]", { hasText: b })).toBeVisible()
})

Then("the group {string} suggests keeping {string}", async ({ page }, title: string, keep: string) => {
  const g = group(page, title)
  const column = g.getByRole("columnheader").filter({ has: page.locator("[data-slot=badge]", { hasText: "Vorschlag" }) })
  await expect(column.getByRole("radio", { name: new RegExp(`^Behalten: #\\d+ ${keep.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}$`) })).toBeChecked()
})

Then("the leftover in the group {string} is marked {string}", async ({ page }, title: string, badge: string) => {
  const g = group(page, title)
  await expect(g.getByRole("columnheader").locator("[data-slot=badge]", { hasText: badge })).toHaveCount(1)
  await expect(g.getByRole("cell", { name: /80 B \(defekt\)/ })).toBeVisible()
})

Then("the group {string} compares {int} books", async ({ page }, title: string, n: number) => {
  await expect(group(page, title).getByRole("radio")).toHaveCount(n)
})

When("I start merging the group {string}", async ({ page }, title: string) => {
  const g = group(page, title)
  await expect(g.getByRole("radio", { checked: true })).toHaveCount(1)
  const ids = await g.getByRole("radio").evaluateAll((els) => els.map((e) => ({ label: e.getAttribute("aria-label") ?? "", checked: (e as HTMLInputElement).checked })))
  const id = (label: string) => Number(/#(\d+)/.exec(label)![1])
  const keepId = id(ids.find((x) => x.checked)!.label)
  const otherId = id(ids.find((x) => !x.checked)!.label)
  merged.set(page, { keep: await apiGet<Book>(page, `/api/books/${keepId}`), other: await apiGet<Book>(page, `/api/books/${otherId}`) })
  await g.getByRole("button", { name: "Zusammenführen" }).click()
})

Then("the merge dialog says that {string} comes along and the other book goes to the trash", async ({ page }, format: string) => {
  const { keep, other } = mergeOf(page)
  const dialog = page.getByRole("dialog", { name: `Zusammenführen in #${keep.id}` })
  await expect(dialog).toBeVisible()
  await expect(dialog.getByRole("listitem").filter({ hasText: `${format} von #${other.id} kommt dazu` })).toBeVisible()
  await expect(dialog.getByRole("listitem").filter({ hasText: `#${other.id} „${other.title}“ kommt in den Papierkorb` })).toBeVisible()
})

Then("the page says the books were merged", async ({ page }) => {
  await expect(page.getByRole("main").getByRole("status").filter({ hasText: "zusammengeführt, 1 in den Papierkorb" })).toBeVisible()
  await expect(page.getByRole("dialog")).toBeHidden()
})

Then("the kept book has the formats {string} and the publisher {string}", async ({ page }, formats: string, publisher: string) => {
  const { keep } = mergeOf(page)
  await expect.poll(async () => (await apiGet<Book>(page, `/api/books/${keep.id}`)).formats.join(", ")).toBe(formats)
  expect((await apiGet<Book>(page, `/api/books/${keep.id}`)).publisher).toBe(publisher)
})

Then("the kept book has the formats {string} and no publisher", async ({ page }, formats: string) => {
  const { keep } = mergeOf(page)
  await expect.poll(async () => (await apiGet<Book>(page, `/api/books/${keep.id}`)).formats.join(", ")).toBe(formats)
  expect((await apiGet<Book>(page, `/api/books/${keep.id}`)).publisher).toBeNull()
})

Then("the other book is in the trash", async ({ page }) => {
  const { other } = mergeOf(page)
  const trash = await apiGet<{ id: number }[]>(page, "/api/trash")
  expect(trash.map((e) => e.id)).toContain(other.id)
})

Then("the group {string} is no longer shown", async ({ page }, title: string) => {
  await expect(group(page, title)).toHaveCount(0)
})

When("I undo the merge", async ({ page }) => {
  await page.getByRole("main").getByRole("status").getByRole("button", { name: "Rückgängig" }).click()
})

Then("the other book is back in the library with a new id", async ({ page }) => {
  const { other } = mergeOf(page)
  await expect.poll(async () => (await apiGet<{ id: number }[]>(page, "/api/trash")).map((e) => e.id)).not.toContain(other.id)
  const back = await apiGet<{ books: Book[] }>(page, `/api/books?limit=500`)
  const again = back.books.filter((b) => b.title === other.title)
  expect(again.map((b) => b.id)).not.toContain(other.id)
  expect(again).toHaveLength(1)
  // and the merge is listed as undone
  await expect(page.getByRole("region", { name: "Zuletzt zusammengeführt" }).getByText("rückgängig gemacht")).toBeVisible()
})

When("I click {string} in the group {string}", async ({ page }, label: string, title: string) => {
  await group(page, title).getByRole("button", { name: label, exact: true }).click()
})

Then("the duplicates page is shown", async ({ page }) => {
  await expect(page).toHaveURL(/\/duplicates$/)
  await expect(page.getByRole("heading", { level: 1, name: "Duplikate" })).toBeVisible()
})
