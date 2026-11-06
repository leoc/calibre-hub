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
  // on a phone the ring says it
  const [value, tag] = badge.split(" · ")
  const wide = (page.viewportSize()?.width ?? 0) >= 640
  await expect(wide ? r.getByText(badge, { exact: true }) : r.getByRole("img", { name: `${value}, ${tag}` })).toBeVisible()
  await expect(r.getByRole("button", { name: file, exact: true })).toHaveClass(/font-medium/)
  const lines = await r.locator("[data-row-text] > div").allInnerTexts()
  expect(lines.slice(1, 3)).toEqual([title, authors])
})

Then("a row has no checkbox", async ({ page }) => {
  await expect(list(page).getByRole("checkbox")).toHaveCount(0)
})

type Asked = { decision: string; ids: number[]; title?: string; authors?: string[] }
const asked = (page: Page) => page.evaluate(() => (window as unknown as { __intake: Asked[] }).__intake)
const askedTo = async (page: Page, decision: string) => (await asked(page)).filter((a) => a.decision === decision).flatMap((a) => a.ids).length

for (const word of ["entry", "entries"]) {
  Then(`the hub was asked to {string} {int} ${word}`, async ({ page }, decision: string, n: number) => {
    await expect.poll(() => askedTo(page, decision)).toBe(n)
  })
}

Then("the hub wasn't asked anything", async ({ page }) => {
  expect(await asked(page)).toEqual([])
})

Then("the hub was asked to accept the title {string} by {string}", async ({ page }, title: string, author: string) => {
  await expect.poll(async () => (await asked(page)).at(-1)).toMatchObject({ decision: "accept", title, authors: [author] })
})

Then("the row {string} has the icons {string} and {string} at {int} px", async ({ page }, title: string, a: string, b: string, size: number) => {
  // touch screens get the Button's larger icon size
  const touch = (page.viewportSize()?.width ?? 0) < 640
  for (const name of [a, b]) {
    const button = row(page, title).getByRole("button", { name, exact: true })
    await expect(button).toHaveCSS("height", touch ? "44px" : `${size}px`)
    await expect(button).toHaveCSS("width", touch ? "44px" : `${size}px`)
  }
  await expect(row(page, title).getByRole("button", { name: b, exact: true })).toHaveClass(/text-destructive/)
})

When("I press {string} on the row {string}", async ({ page }, name: string, title: string) => {
  await row(page, title).getByRole("button", { name, exact: true }).click()
})

Then("the row {string} is gone", async ({ page }, title: string) => {
  await expect(row(page, title)).toHaveCount(0)
})

Then("no dialog asks anything", async ({ page }) => {
  await expect(page.getByRole("dialog").filter({ hasText: "Trotzdem" })).toHaveCount(0)
})

Then("a dialog asks {string}", async ({ page }, text: string) => {
  await expect(page.getByRole("dialog").getByText(text, { exact: true })).toBeVisible()
})

When("I press the dialog's {string}", async ({ page }, name: string) => {
  await page.getByRole("dialog").getByRole("button", { name, exact: true }).click()
})

Then("the dialog's {string} is disabled", async ({ page }, name: string) => {
  await expect(page.getByRole("dialog").getByRole("button", { name, exact: true })).toBeDisabled()
})

Then("the list says {string}", async ({ page }, text: string) => {
  await expect(page.getByText(text, { exact: true })).toBeVisible()
})

Then("the button {string} is disabled", async ({ page }, name: string) => {
  await expect(page.getByRole("button", { name, exact: true })).toBeDisabled()
})

Then("the button {string} is enabled", async ({ page }, name: string) => {
  await expect(page.getByRole("button", { name, exact: true })).toBeEnabled()
})

Then("the row {string} links {string} to book {int} after {string}", async ({ page }, title: string, link: string, id: number, before: string) => {
  const a = row(page, title).getByRole("link", { name: link, exact: true })
  await expect(a).toHaveAttribute("href", `/books/${id}`)
  await expect(row(page, title).getByText(`${before} ${link}`)).toBeVisible()
})

Then("the row {string} says {string}", async ({ page }, title: string, text: string) => {
  await expect(row(page, title).getByText(text, { exact: true })).toBeVisible()
})

Then("the row {string} can't be accepted", async ({ page }, title: string) => {
  await expect(row(page, title).getByRole("button", { name: "Übernehmen", exact: true })).toBeDisabled()
})

Then("the drawer has the buttons {string}, {string}, {string} and {string}", async ({ page }, a: string, b: string, c: string, d: string) => {
  const names = await drawer(page).locator("button:has(kbd)").allInnerTexts()
  expect(names.map((n) => n.replace(/\s+/g, " ").trim())).toEqual([a, b, c, d])
})


Then("the button {string} is outlined in red", async ({ page }, name: string) => {
  const button = drawer(page).getByRole("button", { name, exact: true })
  await expect(button).toHaveClass(/border-destructive/)
  await expect(button).toHaveClass(/text-destructive/)
  await expect(button).toHaveCSS("background-color", "oklch(1 0 0)")
})

When("I hold {string} down", async ({ page }, key: string) => {
  await page.keyboard.down(key)
  await page.keyboard.down(key)
  await page.keyboard.up(key)
})

When("I type {string} as the title", async ({ page }, title: string) => {
  const input = drawer(page).getByLabel("Titel", { exact: true })
  await expect(input).toBeFocused()
  await input.fill("")
  await page.keyboard.type(title)
})

When("I set {string} to {string}", async ({ page }, label: string, value: string) => {
  await page.getByRole("dialog").getByLabel(label).fill(value)
})

Given("the analysis is {string}", async ({ page }, state: string) => {
  await page.addInitScript((s) => localStorage.setItem("hub.mock.intake", s), state)
})

Then("the page says {string}", async ({ page }, text: string) => {
  await expect(page.getByRole("main").getByText(text, { exact: true })).toBeVisible()
})

Then("the page says nothing about the analysis", async ({ page }) => {
  await expect(page.getByRole("main").getByText(/Die Analyse/)).toHaveCount(0)
})

Then("the row {string} shows the ring {string} in rgb\\({int}, {int}, {int}\\) at {int} px", async ({ page }, title: string, label: string, r: number, g: number, b: number, size: number) => {
  const ring = row(page, title).getByRole("img", { name: label, exact: true })
  await expect(ring).toBeVisible()
  await expect(ring).toHaveCSS("color", `rgb(${r}, ${g}, ${b})`)
  await expect(ring).toHaveCSS("width", `${size}px`)
  await expect(row(page, title).getByText(/ % · /)).toBeHidden()
})

Then("the row {string} shows no ring and a dot in rgb\\({int}, {int}, {int}\\)", async ({ page }, title: string, r: number, g: number, b: number) => {
  await expect(row(page, title).getByRole("img")).toBeHidden()
  await expect(row(page, title).locator("[data-slot=badge] span")).toHaveCSS("background-color", `rgb(${r}, ${g}, ${b})`)
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
