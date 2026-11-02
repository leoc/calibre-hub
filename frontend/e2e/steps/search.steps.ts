import { expect, type Page } from "@playwright/test"
import { createBdd } from "playwright-bdd"

const { Given, When, Then } = createBdd()

// Labels as in src/i18n/de.ts
const palette = (page: Page) => page.getByRole("dialog", { name: "Suchen und Befehle" })
const paletteInput = (page: Page) => palette(page).getByRole("combobox")
// wide: a text field; narrow: a button that looks like one
const searchBar = (page: Page) => page.getByRole("banner").getByLabel("Suchen …", { exact: true })
const isWide = (page: Page) => page.viewportSize()!.width >= 640
const results = (page: Page) => page.getByText(/^\d+ Bücher$|^1 Buch$|^Keine Bücher gefunden\.$/)

async function openPalette(page: Page) {
  if (isWide(page)) await page.getByRole("button", { name: "Command-Palette öffnen" }).click()
  else await searchBar(page).click()
  await expect(palette(page)).toBeVisible()
}

async function clearSearchBar(page: Page) {
  await searchBar(page).click()
  await page.keyboard.press("Control+a")
  await page.keyboard.press("Backspace")
}

// --- Given ------------------------------------------------------------------

Given("I am logged in", async ({ page }) => {
  await page.goto("/")
  await expect(results(page)).toBeVisible()
})

Given("the library contains books by {string} in the series {string}", async ({ page }, author: string, series: string) => {
  const cats = await page.evaluate(() => fetch("/api/categories").then((r) => r.json()))
  expect(cats.authors.map((a: { name: string }) => a.name)).toContain(author)
  expect(cats.series.map((s: { name: string }) => s.name)).toContain(series)
})

Given("I use a narrow device", async ({ page }) => {
  expect(isWide(page)).toBe(false)
})

Given("I use a wide device", async ({ page }) => {
  expect(isWide(page)).toBe(true)
})

Given("the library is filtered by {string}", async ({ page }, q: string) => {
  await page.goto(`/?q=${encodeURIComponent(q)}`)
  await expect(results(page)).toBeVisible()
})

Given("the command palette is open", async ({ page }) => {
  await openPalette(page)
})

Given("the focus is not in an input", async ({ page }) => {
  await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur())
})

Given("E-Ink mode is on", async ({ page }) => {
  await page.evaluate(() => localStorage.setItem("hub.theme", "eink"))
  await page.reload()
  await expect(results(page)).toBeVisible()
})

Given("I opened the palette by typing {string} in the empty search bar", async ({ page }, text: string) => {
  await clearSearchBar(page)
  await page.keyboard.type(text)
  await expect(palette(page)).toBeVisible()
})

// --- When -------------------------------------------------------------------

When("I tap the search bar", async ({ page }) => {
  await searchBar(page).click()
})

When("I type {string} in the palette", async ({ page }, text: string) => {
  await paletteInput(page).fill("")
  await paletteInput(page).pressSequentially(text)
})

When("I type {string} in the search bar", async ({ page }, text: string) => {
  await clearSearchBar(page)
  await page.keyboard.type(text)
})

When("I type {string} in the empty search bar", async ({ page }, text: string) => {
  await clearSearchBar(page)
  await page.keyboard.type(text)
})

// Gherkin trims table cells, so the space after a letter prefix is added here
const prefixText = (prefix: string) => (prefix === ">" ? ">" : `${prefix} `)

When("I type the prefix {string} in the empty search bar", async ({ page }, prefix: string) => {
  await clearSearchBar(page)
  await page.keyboard.type(prefixText(prefix))
})

Then("the palette input contains the prefix {string}", async ({ page }, prefix: string) => {
  await expect(paletteInput(page)).toHaveValue(prefixText(prefix))
})

When("I paste {string} into the empty search bar", async ({ page }, text: string) => {
  await clearSearchBar(page)
  // one input event with the whole text, like a paste
  await page.keyboard.insertText(text)
})

When("I click the command button in the search bar", async ({ page }) => {
  await page.getByRole("button", { name: "Command-Palette öffnen" }).click()
})

When("I tap the chip {string}", async ({ page }, label: string) => {
  await palette(page).getByRole("button", { name: new RegExp(`^${label}`) }).click()
})

When("I close the palette", async ({ page }) => {
  await palette(page).getByRole("button", { name: "Schließen" }).click()
})

When("I press Enter", async ({ page }) => {
  await page.keyboard.press("Enter")
})

When("I press Escape", async ({ page }) => {
  await page.keyboard.press("Escape")
})

When("I press {string}", async ({ page }, key: string) => {
  await page.keyboard.press(key)
})

When("I open the command palette", async ({ page }) => {
  await openPalette(page)
})

// --- Then -------------------------------------------------------------------

Then("the command palette opens", async ({ page }) => {
  await expect(palette(page)).toBeVisible()
})

Then("the command palette opens full screen at the top", async ({ page }) => {
  await expect(palette(page)).toBeVisible()
  const box = (await palette(page).boundingBox())!
  const vp = page.viewportSize()!
  expect(box.y).toBeLessThanOrEqual(1)
  expect(box.width).toBeGreaterThanOrEqual(vp.width - 1)
  expect(box.height).toBeGreaterThanOrEqual(vp.height - 1)
})

Then("the focus is in the palette input", async ({ page }) => {
  await expect(paletteInput(page)).toBeFocused()
})

Then("the result list uses the full height below the input", async ({ page }) => {
  const list = (await palette(page).getByRole("listbox").boundingBox())!
  expect(list.y + list.height).toBeGreaterThanOrEqual(page.viewportSize()!.height - 2)
})

Then("the palette input contains {string}", async ({ page }, text: string) => {
  await expect(paletteInput(page)).toHaveValue(text)
})

Then("the palette closes", async ({ page }) => {
  await expect(palette(page)).toBeHidden()
})

Then("the palette stays closed", async ({ page }) => {
  // give a prefix check the chance to (wrongly) open it
  await page.waitForTimeout(400)
  await expect(palette(page)).toBeHidden()
})

Then("the library shows the results for {string}", async ({ page }, q: string) => {
  await expect(page).toHaveURL(new RegExp(`[?&]q=${encodeURIComponent(q).replace(/%20/g, "(\\+|%20)")}(&|$)`))
  await expect(page.getByRole("link", { name: `Filter Suche ${q} entfernen` })).toBeVisible()
})

Then("the search bar shows {string}", async ({ page }, q: string) => {
  if (isWide(page)) await expect(searchBar(page)).toHaveValue(q)
  else await expect(searchBar(page)).toContainText(q)
})

Then("the URL contains {string}", async ({ page }, part: string) => {
  await expect(page).toHaveURL(new RegExp(part.replace(/[?]/g, "\\?")))
})

Then("the library search is unchanged", async ({ page }) => {
  await expect(page).not.toHaveURL(/[?&]q=/)
})

Then("the library is still filtered by {string}", async ({ page }, q: string) => {
  await expect(page).toHaveURL(new RegExp(`[?&]q=${encodeURIComponent(q)}(&|$)`))
})

Then("only series are suggested", async ({ page }) => {
  await expect(palette(page).locator("[cmdk-group-heading]")).toHaveText(["Serien"])
})

Then("only authors are suggested, including {string}", async ({ page }, name: string) => {
  await expect(palette(page).locator("[cmdk-group-heading]")).toHaveText(["Autoren"])
  await expect(palette(page).getByRole("option", { name })).toBeVisible()
})

Then("the focus is in the search bar", async ({ page }) => {
  await expect(searchBar(page)).toBeFocused()
})

Then("{string} is the first and selected entry", async ({ page }, label: string) => {
  const first = palette(page).getByRole("option").first()
  await expect(first).toHaveText(label)
  await expect(first).toHaveAttribute("aria-selected", "true")
})

Then("{string} is the selected entry", async ({ page }, label: string) => {
  await expect(palette(page).locator('[role="option"][aria-selected="true"]')).toContainText(label)
})

Then("the library is filtered by author {string}", async ({ page }, author: string) => {
  await expect(page).toHaveURL(new RegExp(`[?&]author=${encodeURIComponent(author).replace(/%20/g, "(\\+|%20)")}(&|$)`))
})

Then("it appears without animation", async ({ page }) => {
  await expect(palette(page)).toBeVisible()
  const animation = await palette(page).evaluate((el) => getComputedStyle(el).animationName)
  expect(animation).toBe("none")
})

Then("every entry is at least 44 px high", async ({ page }) => {
  await paletteInput(page).pressSequentially("pra")
  const options = palette(page).getByRole("option")
  await expect(options.first()).toBeVisible()
  for (const box of await options.evaluateAll((els) => els.map((e) => e.getBoundingClientRect().height))) {
    expect(box).toBeGreaterThanOrEqual(44)
  }
})
