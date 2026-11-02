import { expect, test } from "@playwright/test"

// Follow-ups from the design runs (docs/design-review.md, #8433)

const results = (page: import("@playwright/test").Page) => page.getByText(/^\d+ Bücher$/)

test("an empty result says so once (D18)", async ({ page }) => {
  await page.goto("/?q=xyzxyzxyz")
  await expect(page.getByText("Keine Bücher gefunden.")).toBeVisible()
  await expect(page.getByText(/^0 Bücher$/)).toHaveCount(0)
})

test("'Ohne Kategorie' keeps its row while the count loads (D19)", async ({ page, isMobile }) => {
  test.skip(isMobile, "sidebar is a drawer on phones")
  // hold back the count of books without a category
  await page.addInitScript(() => {
    const fetch0 = window.fetch
    window.fetch = async (input, init) => {
      const url = decodeURIComponent(typeof input === "string" ? input : input instanceof URL ? input.href : input.url)
      if (url.includes("kategorie:false") && url.includes("limit=1")) await new Promise((r) => setTimeout(r, 1500))
      return fetch0(input, init)
    }
  })
  await page.goto("/")
  const row = page.getByRole("link", { name: /^Ohne Kategorie/ })
  await expect(row).toBeVisible()
  await expect(row).toHaveAccessibleName("Ohne Kategorie")
  const before = await row.boundingBox()
  await expect(row).toHaveAccessibleName(/^Ohne Kategorie \d+$/)
  const after = await row.boundingBox()
  expect(after!.y).toBe(before!.y)
})

test("the palette hint names the platform's modifier key (D24)", async ({ page, isMobile }) => {
  test.skip(isMobile, "no hint on narrow screens")
  await page.goto("/")
  const hint = page.getByRole("button", { name: "Command-Palette öffnen" })
  await expect(hint).toHaveText("StrgK")
  await expect(hint).toHaveAttribute("title", /\(Strg\+K\)/)
})

test("the palette hint shows ⌘ on Apple devices (D24)", async ({ page, isMobile }) => {
  test.skip(isMobile, "no hint on narrow screens")
  await page.addInitScript(() => Object.defineProperty(navigator, "platform", { get: () => "MacIntel" }))
  await page.addInitScript(() => Object.defineProperty(navigator, "userAgentData", { get: () => undefined }))
  await page.goto("/")
  const hint = page.getByRole("button", { name: "Command-Palette öffnen" })
  await expect(hint).toHaveText("K")
  await expect(hint).toHaveAttribute("title", /\(⌘\+K\)/)
})

test("a compact pager at the top turns the pages (D26)", async ({ page }) => {
  await page.goto("/")
  await expect(results(page)).toBeVisible()
  const top = page.getByRole("navigation", { name: /^Seiten, Seite 1 von \d+$/ })
  await expect(top).toBeVisible()
  await expect(top.getByText(/^1 \/ \d+$/)).toBeVisible()
  await top.getByRole("link", { name: "Weiter" }).click()
  await expect(page).toHaveURL(/page=2/)
  await expect(page.getByRole("navigation", { name: /^Seiten, Seite 2 von \d+$/ })).toBeVisible()
  // one page: no pager
  await page.goto("/?series=Erdsee")
  await expect(page.getByText(/^\d+ Bücher$|^1 Buch$/)).toBeVisible()
  await expect(page.getByRole("navigation", { name: /^Seiten,/ })).toHaveCount(0)
})

test("list headers sort by their column (D20)", async ({ page, isMobile }) => {
  test.skip(isMobile, "headers from 768 px")
  await page.addInitScript(() => localStorage.setItem("hub.view", "list"))
  await page.goto("/")
  await expect(results(page)).toBeVisible()
  await page.getByRole("link", { name: "Nach Titel sortieren" }).click()
  await expect(page).toHaveURL(/sort=title&order=asc|order=asc&sort=title/)
  await expect(page.getByRole("combobox", { name: "Sortierung" })).toHaveValue("title")
  await page.getByRole("link", { name: "Nach Titel sortieren" }).click()
  await expect(page).toHaveURL(/order=desc/)
})

test("the side panel opens without a focus ring on its close button (D22)", async ({ page, isMobile }) => {
  test.skip(isMobile, "detail is its own page on phones")
  await page.goto("/")
  await page.locator("main li a").first().click()
  const dialog = page.getByRole("dialog")
  await expect(dialog).toBeVisible()
  await expect(dialog).toBeFocused()
  await expect(dialog.getByRole("button", { name: "Schließen" })).not.toBeFocused()
})

test("phones: suggestions are accepted from a bar at the bottom (M14)", async ({ page, isMobile }) => {
  test.skip(!isMobile, "phones only")
  await page.goto("/suggestions")
  const accept = page.getByRole("button", { name: /^Ausgewählte annehmen/ })
  await expect(accept).toBeVisible()
  const box = await accept.boundingBox()
  const height = page.viewportSize()!.height
  expect(box!.y + box!.height).toBeGreaterThan(height - 80)
})
