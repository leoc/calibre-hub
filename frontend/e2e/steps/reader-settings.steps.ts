import { expect, type Page } from "@playwright/test"
import { createBdd } from "playwright-bdd"

const { When, Then } = createBdd()

// Reader settings (reading.feature). The book's document lives in an
// iframe of foliate-js' paginator; these steps look into it.

const sheet = (page: Page) => page.locator("[data-reader-settings]")

// computed styles of the first paragraph of the shown section
const paragraph = (page: Page) =>
  page.evaluate(() => {
    const view = document.querySelector("foliate-view") as unknown as { renderer: { getContents(): { doc: Document }[] } }
    const doc = view.renderer.getContents()[0].doc
    const p = doc.querySelector("p.text") ?? doc.querySelector("p")!
    const cs = doc.defaultView!.getComputedStyle(p)
    const fonts = [...doc.fonts].filter((f) => f.status === "loaded").map((f) => f.family)
    return {
      fontSize: parseFloat(cs.fontSize),
      lineHeight: parseFloat(cs.lineHeight) / parseFloat(cs.fontSize),
      fontFamily: cs.fontFamily,
      background: doc.defaultView!.getComputedStyle(doc.documentElement).backgroundColor,
      fonts,
    }
  })

const renderer = (page: Page) =>
  page.evaluate(() => {
    const r = (document.querySelector("foliate-view") as unknown as { renderer: HTMLElement }).renderer
    return { columns: r.getAttribute("max-column-count"), flow: r.getAttribute("flow"), animated: r.hasAttribute("animated") }
  })

const sizes = new WeakMap<Page, number[]>()

When("I open the reader settings", async ({ page }) => {
  sizes.set(page, [(await paragraph(page)).fontSize])
  await page.getByRole("button", { name: "Darstellung" }).click()
  await expect(sheet(page)).toBeVisible()
})

When("I click {string} in the reader settings {int} times", async ({ page }, label: string, n: number) => {
  for (let i = 0; i < n; i++) await sheet(page).getByRole("button", { name: label, exact: true }).click()
  // the book is laid out again
  await page.waitForTimeout(300)
  sizes.get(page)!.push((await paragraph(page)).fontSize)
})

When("I choose {string} for {string} in the reader settings", async ({ page }, option: string, group: string) => {
  const radio = sheet(page).getByRole("radiogroup", { name: group }).getByRole("radio", { name: option, exact: true })
  await radio.click()
  await expect(radio).toHaveAttribute("aria-checked", "true")
})

When(/^I turn (on|off) "(.+)" in the reader settings$/, async ({ page }, state: string, label: string) => {
  const sw = sheet(page).getByRole("switch", { name: new RegExp(`^${label}`) })
  if ((await sw.getAttribute("aria-checked")) !== String(state === "on")) await sw.click()
  await expect(sw).toHaveAttribute("aria-checked", String(state === "on"))
})

When("I open the book in the reader again", async ({ page }) => {
  await page.keyboard.press("Escape")
  await expect(sheet(page)).toHaveCount(0)
  await page.keyboard.press("Escape")
  await page.getByRole("link", { name: /^(Lesen|Weiterlesen)/ }).click()
  await expect(page.locator('[data-reader="ready"]')).toBeVisible({ timeout: 15_000 })
})

Then("the book's text is larger than before", async ({ page }) => {
  const [first, now] = sizes.get(page)!
  expect(now).toBeGreaterThan(first * 1.15)
})

Then("the book's text is smaller than at first", async ({ page }) => {
  const all = sizes.get(page)!
  expect(all.at(-1)).toBeLessThan(all[0] * 0.95)
})

Then("the page is shown in sepia", async ({ page }) => {
  await expect.poll(async () => (await paragraph(page)).background).toBe("rgb(244, 236, 216)")
})

Then("the book's text is set in {string}", async ({ page }, font: string) => {
  await expect.poll(async () => (await paragraph(page)).fontFamily).toContain(font)
  // the bundled font itself, loaded from the hub (no CDN)
  await expect.poll(async () => (await paragraph(page)).fonts.some((f) => f.includes(font)), { timeout: 10_000 }).toBe(true)
})

Then("the hub has the reader setting {string} as {string}", async ({ page }, key: string, value: string) => {
  await expect.poll(() => page.evaluate((k) => fetch("/api/reader/settings").then((r) => r.json()).then((s) => s[k]), key), { timeout: 5000 }).toBe(value)
})

Then("the book's paragraphs have the line height {float}", async ({ page }, lh: number) => {
  await expect.poll(async () => Math.round((await paragraph(page)).lineHeight * 100) / 100).toBe(lh)
})

Then(/^the book is shown with up to (\d) columns?, (paginated|scrolled) and (animated|not animated)$/, async ({ page }, n: string, flow: string, animated: string) => {
  await expect.poll(() => renderer(page)).toEqual({ columns: n, flow, animated: animated === "animated" })
})

Then("the reader settings offer no animation and no colors", async ({ page }) => {
  await expect(sheet(page).getByRole("switch", { name: /^Animation/ })).toHaveCount(0)
  await expect(sheet(page).getByRole("radiogroup", { name: "Farben" })).toHaveCount(0)
  await expect(sheet(page).getByRole("radiogroup", { name: "Anzeige" })).toHaveCount(0)
  await expect(sheet(page)).toContainText("Auf E-Ink immer")
})
