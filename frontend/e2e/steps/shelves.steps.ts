import { expect, type Page } from "@playwright/test"
import { createBdd } from "playwright-bdd"

const { Given, When, Then } = createBdd()

// Labels as in src/i18n/de.ts. The mock state lives in the page: after the
// first page load the steps stay inside the app.
const newShelf = (page: Page) => page.getByRole("dialog", { name: "Neues magisches Regal" })
const editShelf = (page: Page) => page.getByRole("dialog", { name: "Regal bearbeiten" })
const results = (page: Page) => page.locator("main").getByText(/^\d+ Bücher$|^1 Buch$/).last()
const resultCount = (n: number) => (n === 1 ? "1 Buch" : `${n} Bücher`)
const seriesTotal = (page: Page, series: string): Promise<number> =>
  page.evaluate((s) => fetch(`/api/books?series=${encodeURIComponent(s)}&limit=1`).then((r) => r.json()).then((p) => p.total), series)
const listByName = (page: Page, name: string): Promise<{ count: number; rule: unknown } | undefined> =>
  page.evaluate((n) => fetch("/api/lists").then((r) => r.json()).then((ls) => ls.find((l: { name: string }) => l.name === n)), name)

async function filterBySeries(page: Page, series: string) {
  await page.goto(`/?series=${encodeURIComponent(series)}`)
  await expect(results(page)).toBeVisible()
}

async function createFromToolbar(page: Page, name: string) {
  await page.getByRole("button", { name: "Als Regal speichern" }).click()
  await newShelf(page).getByRole("textbox", { name: "Name des Regals" }).fill(name)
  await newShelf(page).getByRole("button", { name: "Anlegen" }).click()
  await expect(newShelf(page)).toBeHidden()
  await expect(page.getByRole("heading", { level: 1, name, exact: true })).toBeVisible()
}

// --- Given ------------------------------------------------------------------

Given("the library is filtered by the series {string}", async ({ page }, series: string) => {
  await filterBySeries(page, series)
})

Given("the shelf {string} for the series {string}", async ({ page }, name: string, series: string) => {
  await filterBySeries(page, series)
  await createFromToolbar(page, name)
})

// --- When -------------------------------------------------------------------

When("I click {string} in the toolbar", async ({ page }, label: string) => {
  await page.getByRole("main").getByRole("button", { name: label }).click()
})

When("I name the shelf {string} and create it", async ({ page }, name: string) => {
  const dialog = newShelf(page)
  await dialog.getByRole("textbox", { name: "Name des Regals" }).fill(name)
  await dialog.getByRole("button", { name: "Anlegen" }).click()
  await expect(dialog).toBeHidden()
})

When("I click {string} on the shelf's page", async ({ page }, label: string) => {
  await page.getByRole("main").getByRole("button", { name: label }).click()
  await expect(editShelf(page)).toBeVisible()
})

When("I add the rule {string} {string} {string}", async ({ page }, field: string, op: string, value: string) => {
  const dialog = editShelf(page)
  await dialog.getByRole("button", { name: "Regel hinzufügen" }).click()
  const rule = dialog.getByRole("group", { name: /^Regel \d+$/ }).last()
  await rule.getByRole("combobox", { name: "Feld" }).selectOption({ label: field })
  await rule.getByRole("combobox", { name: "Bedingung" }).selectOption({ label: op })
  await rule.getByRole("combobox", { name: "Wert" }).fill(value)
})

When("I choose {string}", async ({ page }, label: string) => {
  await editShelf(page).getByRole("combobox", { name: "Verknüpfung" }).selectOption({ label })
})

When("I save the shelf", async ({ page }) => {
  await editShelf(page).getByRole("button", { name: "Speichern" }).click()
  await expect(editShelf(page)).toBeHidden()
})

When("I create the shelf {string} for the tag {string} in the overview", async ({ page }, name: string, tag: string) => {
  await page.getByRole("navigation").getByRole("link", { name: "Alle Listen" }).click()
  await page.getByRole("button", { name: "Neues Regal" }).click()
  const dialog = newShelf(page)
  await dialog.getByRole("textbox", { name: "Name des Regals" }).fill(name)
  // a new rule starts as "Tag ist …"
  await expect(dialog.getByRole("combobox", { name: "Feld" })).toHaveValue("tag")
  await dialog.getByRole("combobox", { name: "Wert" }).fill(tag)
  await dialog.getByRole("button", { name: "Anlegen" }).click()
  await expect(page.getByRole("heading", { level: 1, name, exact: true })).toBeVisible()
})

When("I add the tag {string} to the selection", async ({ page }, tag: string) => {
  await page.getByRole("button", { name: "Tags hinzufügen", exact: true }).click()
  await page.getByRole("combobox", { name: "Tags" }).fill(tag)
  await page.keyboard.press("Enter")
  await page.getByRole("button", { name: "Anwenden" }).click()
  await expect(page.getByText(/geändert, 0 Fehler/)).toBeVisible({ timeout: 10_000 })
})

When("I open the first book of the page", async ({ page }) => {
  await page.locator("main li.group a").first().click()
  await expect(page.getByRole("button", { name: "Speichern", exact: true })).toBeVisible()
})

// --- Then -------------------------------------------------------------------

Then("the dialog {string} has the rule {string} {string} {string}", async ({ page }, title: string, field: string, op: string, value: string) => {
  const rule = page.getByRole("dialog", { name: title }).getByRole("group", { name: "Regel 1" })
  await expect(rule.getByRole("combobox", { name: "Feld" }).locator("option:checked")).toHaveText(field)
  await expect(rule.getByRole("combobox", { name: "Bedingung" }).locator("option:checked")).toHaveText(op)
  await expect(rule.getByRole("combobox", { name: "Wert" })).toHaveValue(value)
})

Then("the shelf shows the books of the series {string}", async ({ page }, series: string) => {
  const n = await seriesTotal(page, series)
  expect(n).toBeGreaterThan(0)
  await expect(results(page)).toHaveText(resultCount(n))
  await expect(page.locator("main li.group")).toHaveCount(Math.min(n, 60))
})

Then("the shelf shows the books of the series {string} and {string}", async ({ page }, a: string, b: string) => {
  const n = (await seriesTotal(page, a)) + (await seriesTotal(page, b))
  await expect(results(page)).toHaveText(resultCount(n))
})

Then("the sidebar shows the shelf {string} with the count {int}", async ({ page }, name: string, n: number) => {
  await expect(page.getByRole("navigation").getByRole("link", { name })).toHaveText(new RegExp(`^\\s*${name}\\s*${n}$`))
})

Then("the overview shows the shelf {string} without sync and default list", async ({ page }, name: string) => {
  const row = page.getByRole("main").getByRole("list", { name: "Listen" }).getByRole("listitem", { name, exact: true })
  await expect(row.locator("[data-slot=badge]", { hasText: "Magisches Regal" })).toBeVisible()
  await expect(row.getByText("Serie ist")).toBeVisible()
  await expect(row.getByRole("button", { name: "Synchronisieren" })).toHaveCount(0)
  await expect(row.getByRole("button", { name: "Standardliste" })).toHaveCount(0)
  expect((await listByName(page, name))?.rule).toBeTruthy()
})

Then("the dialog {string} doesn't offer {string}", async ({ page }, title: string, name: string) => {
  const dialog = page.getByRole("dialog", { name: title })
  await expect(dialog.getByRole("checkbox", { name: "Leseliste" })).toBeVisible()
  await expect(dialog.getByRole("checkbox", { name })).toHaveCount(0)
})
