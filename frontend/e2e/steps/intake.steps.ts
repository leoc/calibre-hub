import { expect, type Page } from "@playwright/test"
import { createBdd } from "playwright-bdd"

const { Given, When, Then } = createBdd()

// Labels as in src/i18n/de.ts; the mock Eingang in src/mocks/intake.ts

const list = (page: Page) => page.getByRole("list", { name: "Eingang", exact: true })
const rows = (page: Page) => list(page).getByRole("listitem")
// by the recognised title; with the drawer open the list is hidden from roles
const row = (page: Page, title: string) => page.locator("[data-entry]").filter({ hasText: title }).first()
const drawer = (page: Page) => page.getByRole("dialog")

When("I open the Eingang", async ({ page }) => {
  await page.goto("/eingang")
  await expect(page.getByRole("heading", { level: 1, name: "Eingang" })).toBeVisible()
  await expect(rows(page).first()).toBeVisible()
})

Given("I open the library", async ({ page }) => {
  await page.goto("/")
  await expect(page.getByText(/^\d+ Bücher$/)).toBeVisible()
})

const menuLink = async (page: Page) => {
  const menu = page.getByRole("button", { name: "Menü" })
  if (await menu.isVisible()) await menu.click()
  return page.getByRole("link", { name: /^Eingang/ })
}

When("I open the Eingang from the menu", async ({ page }) => {
  await (await menuLink(page)).click()
  await expect(page).toHaveURL(/\/eingang$/)
  await expect(page.getByRole("heading", { level: 1, name: "Eingang" })).toBeVisible()
})

Then("the menu shows {string} next to the Eingang", async ({ page }, count: string) => {
  await expect(await menuLink(page)).toContainText(count)
})

Then("the numbers are {string} and {string}", async ({ page }, a: string, b: string) => {
  for (const text of [a, b]) await expect(page.getByRole("main").getByText(text, { exact: true })).toBeVisible()
})

Then("the analysis bar stands at {int} percent", async ({ page }, percent: number) => {
  const bar = page.getByRole("progressbar", { name: "Analyse" })
  await expect(bar).toHaveAttribute("aria-valuenow", String(percent))
  await expect(bar).toHaveCSS("height", "6px")
  await expect(page.getByText(/^Analysiert gerade/)).toHaveCount(0)
})

Then("the row of {string} shows {string}, then {string} and {string}", async ({ page }, file: string, badge: string, title: string, authors: string) => {
  const r = rows(page).filter({ has: page.getByRole("button", { name: file, exact: true }) })
  await expect(r.getByText(badge, { exact: true })).toBeVisible()
  await expect(r.getByRole("button", { name: file, exact: true })).toHaveClass(/font-medium/)
  const lines = await r.locator("div > div").allInnerTexts()
  expect(lines.slice(-2)).toEqual([title, authors])
})

Then("nothing can be decided yet", async ({ page }) => {
  await expect(page.getByRole("button", { name: /Übernehmen|Papierkorb/ })).toHaveCount(0)
  await expect(list(page).getByRole("checkbox")).toHaveCount(0)
})

Then("the filter {string} offers {string}", async ({ page }, label: string, option: string) => {
  await expect(page.getByLabel(label).getByRole("option", { name: option, exact: true })).toHaveCount(1)
})

When("I choose {string} in {string}", async ({ page }, option: string, label: string) => {
  await page.getByLabel(label).selectOption({ label: option })
})

Then("the list has {int} rows", async ({ page }, n: number) => {
  await expect(rows(page)).toHaveCount(n)
})

When("I press the button {string}", async ({ page }, name: string) => {
  await page.getByRole("button", { name, exact: true }).click()
})

When("I open the row {string}", async ({ page }, title: string) => {
  await row(page, title).getByRole("button").first().click()
  await expect(drawer(page)).toBeVisible()
})

Then("the drawer's header reads {string}", async ({ page }, name: string) => {
  await expect(drawer(page).getByRole("heading", { name, exact: true })).toBeVisible()
})

Then("the drawer shows the folder {string}", async ({ page }, folder: string) => {
  await expect(drawer(page).getByText(folder, { exact: true })).toBeVisible()
})

Then("the drawer shows no folder", async ({ page }) => {
  await expect(drawer(page).getByText("/srv/media")).toHaveCount(0)
  await expect(drawer(page).getByText("Defaults", { exact: true })).toHaveCount(0)
})

Then("the drawer shows {string} and {string}", async ({ page }, a: string, b: string) => {
  await expect(drawer(page).getByText(a, { exact: true })).toBeVisible()
  await expect(drawer(page).getByText(b, { exact: true })).toBeVisible()
})

Then("the drawer shows {string}", async ({ page }, text: string) => {
  await expect(drawer(page).getByText(text, { exact: true })).toBeVisible()
})

const candidates = (page: Page) => drawer(page).getByRole("list", { name: "Kandidaten" }).getByRole("listitem")

Then("the candidates are {string} from {string} at {string} and {string} from {string} at {string}", async ({ page }, t1: string, s1: string, c1: string, t2: string, s2: string, c2: string) => {
  await expect(candidates(page)).toHaveCount(2)
  for (const [i, parts] of [[t1, s1, c1], [t2, s2, c2]].entries()) {
    for (const part of parts) await expect(candidates(page).nth(i)).toContainText(part)
  }
})

Then("each candidate has its digit", async ({ page }) => {
  await expect(candidates(page).first().locator("kbd")).toHaveText("1")
})

Then("the row {string} is marked as the current one", async ({ page }, title: string) => {
  await expect(row(page, title)).toHaveAttribute("aria-current", "true")
  await expect(page.locator("[data-entry][aria-current]")).toHaveCount(1)
})

When("I press {string} {int} times", async ({ page }, key: string, times: number) => {
  for (let i = 0; i < times; i++) await page.keyboard.press(key)
})

Then("the row {string} is in view", async ({ page }, title: string) => {
  await expect(row(page, title)).toBeInViewport()
})

Then("no drawer is open", async ({ page }) => {
  await expect(drawer(page)).toHaveCount(0)
})

Then("the list behind the drawer isn't dimmed", async ({ page }) => {
  const overlay = page.locator("[data-slot=sheet-overlay], .fixed.inset-0.z-50").first()
  await expect(overlay).toHaveCSS("background-color", "rgba(0, 0, 0, 0)")
})

When("I click beside the drawer", async ({ page }) => {
  await page.mouse.click(40, 450)
})

Then("there is no link {string}", async ({ page }, name: string) => {
  await expect(page.getByRole("link", { name: new RegExp(`^${name}`) })).toHaveCount(0)
})
