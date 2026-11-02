import { expect, test, type Page } from "@playwright/test"

// E-Ink mode promises tap targets of at least 44×44 px (pen and finger on a
// slow screen). Walks the main pages on a Boox-sized screen and lists every
// visible interactive element that is smaller.

const BOOX_UA = "Mozilla/5.0 (Linux; Android 12; NoteAir3C) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/112.0.0.0 Safari/537.36 BOOX Onyx"
const MIN = 44

test.use({ viewport: { width: 1072, height: 1448 }, userAgent: BOOX_UA, hasTouch: true })

const results = (page: Page) => page.getByText(/^\d+ Bücher$|^1 Buch$/)

async function smallTargets(page: Page, scope = "body") {
  return page.locator(scope).evaluate((root, min) => {
    const sel = "a[href], button, input:not([type=hidden]), select, textarea, summary, [role=button], [role=checkbox], [role=radio], [role=option], [role=combobox], [role=switch], [role=tab], [tabindex]:not([tabindex='-1'])"
    const out: string[] = []
    for (const el of root.querySelectorAll<HTMLElement>(sel)) {
      // a visually hidden file input is tapped through its label
      const target = el.matches("input.sr-only") ? (el.closest("label") ?? el) : el
      const style = getComputedStyle(target)
      if (style.visibility === "hidden" || style.display === "none") continue
      const r = target.getBoundingClientRect()
      if (!r.width || !r.height || target.closest("[aria-hidden=true], .sr-only:not(input)")) continue
      // text fields inside a larger field box (chips input, combobox) count as the box
      const box = target.matches("input:not([type=checkbox]):not([type=radio])") ? (target.parentElement?.getBoundingClientRect() ?? r) : r
      // a checkbox counts with its label row
      const row = target.matches("input[type=checkbox], input[type=radio]") ? (target.closest("label")?.getBoundingClientRect() ?? r) : box
      if (Math.round(row.width) < min || Math.round(row.height) < min) {
        const name = (target.getAttribute("aria-label") ?? target.textContent ?? target.getAttribute("placeholder") ?? "").trim().slice(0, 40)
        out.push(`${target.tagName.toLowerCase()} "${name}" ${Math.round(row.width)}×${Math.round(row.height)}`)
      }
    }
    return out
  }, MIN)
}

test.beforeEach(async ({ page }, testInfo) => {
  test.skip(testInfo.project.name !== "desktop", "one device is enough")
  await page.addInitScript(() => {
    localStorage.setItem("hub.theme", "eink")
    localStorage.setItem("hub.einkAsked", "1")
  })
})

test("E-Ink: library, sidebar and pagination", async ({ page }) => {
  await page.goto("/?kategorie=Roman&page=2")
  await expect(results(page)).toBeVisible()
  expect(await smallTargets(page)).toEqual([])
})

test("E-Ink: list view and selection mode", async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem("hub.view", "list"))
  await page.goto("/")
  await expect(results(page)).toBeVisible()
  await page.getByRole("button", { name: "Auswählen" }).click()
  await page.locator("main [role=checkbox]").first().click()
  expect(await smallTargets(page)).toEqual([])
})

test("E-Ink: book detail and edit form", async ({ page }) => {
  await page.goto("/?book=7")
  await expect(page.getByRole("heading", { level: 1 })).toBeVisible()
  expect(await smallTargets(page, "[role=dialog]")).toEqual([])
  await page.getByRole("button", { name: "Bearbeiten" }).click()
  await expect(page.getByRole("form")).toBeVisible()
  await page.getByRole("button", { name: "Cover ändern" }).click()
  await page.getByRole("button", { name: "Kennung hinzufügen" }).click()
  expect(await smallTargets(page, "[role=dialog]")).toEqual([])
})

test("E-Ink: command palette", async ({ page }) => {
  await page.goto("/")
  await expect(results(page)).toBeVisible()
  await page.getByRole("button", { name: "Command-Palette öffnen" }).click()
  await page.getByRole("dialog").getByRole("combobox").fill("ter")
  await expect(page.getByRole("option").first()).toBeVisible()
  expect(await smallTargets(page, "[role=dialog]")).toEqual([])
})

test("E-Ink: category suggestions and the box in the detail", async ({ page }) => {
  await page.goto("/")
  await expect(results(page)).toBeVisible()
  await page.getByRole("link", { name: /^Vorschläge/ }).click()
  await expect(page.getByRole("heading", { level: 1 })).toBeVisible()
  const first = page.getByRole("list", { name: "Vorschläge" }).getByRole("listitem").first()
  await expect(first).toBeVisible()
  await first.getByRole("button", { name: /^Ändern/ }).click()
  expect(await smallTargets(page)).toEqual([])
  await first.getByRole("link").nth(1).click()
  await expect(page.getByRole("heading", { level: 1 })).toBeVisible()
  expect(await smallTargets(page, "main")).toEqual([])
})

test("E-Ink: metadata changes and candidates in the edit form", async ({ page }) => {
  await page.goto("/")
  await expect(results(page)).toBeVisible()
  await page.getByRole("link", { name: "Metadaten", exact: true }).click()
  await expect(page.getByRole("heading", { level: 1 })).toBeVisible()
  await page.getByRole("checkbox", { name: "Zurückgesetzte anzeigen" }).check()
  await expect(page.getByText("zurückgesetzt", { exact: true }).first()).toBeVisible()
  expect(await smallTargets(page)).toEqual([])
  await page.goto("/books/7?edit=true")
  await page.getByRole("button", { name: "Metadaten holen" }).click()
  await expect(page.getByRole("list", { name: "Treffer" })).toBeVisible()
  expect(await smallTargets(page, "[role=dialog]")).toEqual([])
})

test("E-Ink: trash and login", async ({ page }) => {
  await page.goto("/")
  await expect(results(page)).toBeVisible()
  await page.evaluate(() => fetch("/api/books/3", { method: "DELETE" }))
  await page.getByRole("link", { name: "Papierkorb" }).click()
  await expect(page.getByRole("button", { name: /Wiederherstellen/ })).toBeVisible()
  expect(await smallTargets(page)).toEqual([])
  await page.goto("/login")
  await expect(page.getByLabel("Passwort")).toBeVisible()
  expect(await smallTargets(page)).toEqual([])
})
