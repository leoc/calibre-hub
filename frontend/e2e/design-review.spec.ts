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

test("phones: the list toggle on a cover is small but has a 44 px hit area (M12)", async ({ page, isMobile }) => {
  test.skip(!isMobile, "touch screens only")
  await page.goto("/")
  await expect(results(page)).toBeVisible()
  const toggle = page.locator("main li").first().getByRole("button", { name: /Leseliste/ })
  const box = (await toggle.boundingBox())!
  expect(box.width).toBeLessThanOrEqual(28)
  expect(box.height).toBeLessThanOrEqual(28)
  // the invisible ::after takes taps up to 44 px around the toggle
  const hit = await toggle.evaluate((el) => {
    const r = el.getBoundingClientRect()
    const cx = r.left + r.width / 2
    const cy = r.top + r.height / 2
    return [[cx, cy - 21], [cx, cy + 21], [cx - 21, cy], [cx + 21, cy]].map(([x, y]) => el.contains(document.elementFromPoint(x, y)))
  })
  expect(hit).toEqual([true, true, true, true])
})

test("phones: the view switch stays in the row of the sort (M13)", async ({ page, isMobile }) => {
  test.skip(!isMobile, "phones only")
  await page.setViewportSize({ width: 360, height: 740 })
  await page.goto("/")
  await expect(results(page)).toBeVisible()
  const sort = (await page.getByRole("combobox", { name: "Sortierung" }).boundingBox())!
  const view = (await page.getByRole("radiogroup", { name: "Ansicht" }).boundingBox())!
  expect(Math.abs(view.y + view.height / 2 - (sort.y + sort.height / 2))).toBeLessThanOrEqual(2)
  expect(view.x + view.width).toBeLessThanOrEqual(360)
})

test("phones: the book's first action is on the first screen at 360×740 (M16)", async ({ page, isMobile }) => {
  test.skip(!isMobile, "phones only")
  await page.setViewportSize({ width: 360, height: 740 })
  await page.goto("/")
  await expect(results(page)).toBeVisible()
  await page.locator("main li a").nth(1).click()
  const action = page.locator("main").locator("a[download], button").filter({ hasText: /^\s*(Lesen|EPUB|PDF|MOBI|AZW3|KEPUB|Bearbeiten)/ }).first()
  await expect(action).toBeVisible()
  const box = (await action.boundingBox())!
  expect(box.y + box.height).toBeLessThanOrEqual(740)
})

test("palette rows start their text at one x (D21)", async ({ page, isMobile }) => {
  test.skip(isMobile, "checked on the desktop palette")
  await page.goto("/")
  await expect(results(page)).toBeVisible()
  await page.keyboard.press("Control+k")
  await page.keyboard.type("erd")
  await expect(page.locator("[cmdk-group-heading]", { hasText: "Bücher" })).toBeVisible()
  await expect(page.locator("[cmdk-group-heading]", { hasText: "Serien" })).toBeVisible()
  const xs = await page.locator("[cmdk-item]").evaluateAll((items) =>
    items.map((item) => {
      const walk = document.createTreeWalker(item, NodeFilter.SHOW_TEXT, { acceptNode: (n) => (n.textContent!.trim() ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP) })
      const range = document.createRange()
      range.selectNodeContents(walk.nextNode()!)
      return Math.round(range.getBoundingClientRect().left)
    }),
  )
  expect(xs.length).toBeGreaterThan(3)
  expect(new Set(xs).size, `text starts at ${xs}`).toBe(1)
})

test("the selection ring keeps clear of cover and title (D23)", async ({ page, isMobile }) => {
  test.skip(isMobile, "checked on the desktop grid")
  await page.goto("/")
  await expect(results(page)).toBeVisible()
  await page.locator("main").getByRole("button", { name: "Auswählen" }).click()
  const item = page.locator("main li [role=checkbox]").first()
  await item.click()
  await expect(item).toHaveAttribute("aria-checked", "true")
  const gaps = await item.evaluate((el) => {
    const r = el.getBoundingClientRect()
    const title = el.querySelector("p")!.getBoundingClientRect()
    const cover = el.querySelector("div")!.getBoundingClientRect()
    return [title.left - r.left, r.right - title.right, cover.left - r.left, cover.top - r.top].map(Math.round)
  })
  for (const g of gaps) expect(g, `gaps ${gaps}`).toBeGreaterThanOrEqual(4)
})

test("five grid columns at 1024 px next to the sidebar (D25)", async ({ page, isMobile }) => {
  test.skip(isMobile, "desktop width")
  await page.setViewportSize({ width: 1024, height: 800 })
  await page.goto("/")
  await expect(results(page)).toBeVisible()
  const columns = await page.locator("main ul").first().evaluate((ul) => getComputedStyle(ul).gridTemplateColumns.split(" ").length)
  expect(columns).toBe(5)
})

test("E-Ink: the list headers are black (D20)", async ({ page, isMobile }) => {
  test.skip(isMobile, "headers from 768 px")
  await page.addInitScript(() => {
    localStorage.setItem("hub.view", "list")
    localStorage.setItem("hub.theme", "eink")
  })
  await page.goto("/")
  await expect(results(page)).toBeVisible()
  await expect(page.getByRole("link", { name: "Nach Titel sortieren" })).toHaveCSS("color", "rgb(0, 0, 0)")
  await expect(page.locator("main").getByText("Kategorie", { exact: true })).toHaveCSS("color", "rgb(0, 0, 0)")
})
