import { expect, test, type Page } from "@playwright/test"

// The mock starts with 5 open suggestions; a run classifies the other
// unsorted books (id % 3: 0 applied with the tag, 1 open, 2 nothing fits).
async function openSuggestions(page: Page, isMobile: boolean) {
  if (isMobile) await page.getByRole("button", { name: "Menü" }).click()
  const link = page.getByRole("link", { name: /^Vorschläge/ })
  await expect(link).toContainText("5")
  await link.click()
  await expect(page).toHaveURL(/\/suggestions$/)
}

const rows = (page: Page) => page.getByRole("list", { name: "Vorschläge" }).getByRole("listitem")

test("review suggestions: accept, change, reject, accept selected", async ({ page, isMobile }) => {
  await page.goto("/")
  await openSuggestions(page, isMobile)
  await expect(page.getByText("Modell qwen2.5:3b, übernimmt ab 85 %")).toBeVisible()
  await expect(rows(page)).toHaveCount(5)
  const first = rows(page).first()
  await expect(first).toContainText("/")
  await expect(first).toContainText("%")

  const title = async (i: number) => (await rows(page).nth(i).getAttribute("aria-label"))!
  const accepted = await title(0)
  await page.getByRole("button", { name: `Annehmen: ${accepted}` }).click()
  await expect(rows(page)).toHaveCount(4)

  const rejected = await title(0)
  await page.getByRole("button", { name: `Ablehnen: ${rejected}` }).click()
  await expect(rows(page)).toHaveCount(3)

  const changed = await title(0)
  await page.getByRole("button", { name: `Ändern: ${changed}` }).click()
  const box = rows(page).first().getByRole("combobox", { name: "Kategorie" })
  await box.fill("Roman/Klassiker")
  await rows(page).first().getByRole("button", { name: "Übernehmen" }).click()
  await expect(rows(page)).toHaveCount(2)

  await page.getByRole("checkbox", { name: "Alle auswählen" }).check()
  await page.getByRole("button", { name: "Ausgewählte annehmen (2)" }).click()
  await expect(page.getByRole("status").filter({ hasText: "2 angenommen" })).toBeVisible()
  await expect(page.getByText("Keine offenen Vorschläge.")).toBeVisible()
})

test("classify the unsorted books and see progress", async ({ page, isMobile }) => {
  await page.goto("/")
  await openSuggestions(page, isMobile)
  await page.getByRole("button", { name: "Unsortierte klassifizieren" }).click()
  await expect(page.getByRole("status").filter({ hasText: /^Fertig: \d+ Bücher, 0 Fehler$/ })).toBeVisible({ timeout: 15_000 })
  // new open suggestions besides the 5 from the start
  await expect.poll(() => rows(page).count()).toBeGreaterThan(5)
  // sure ones were applied with the tag
  await page.goto("/?tag=auto-kategorie")
  await expect(page.getByText(/^\d+ Bücher$/)).toBeVisible()
})

test("accept a suggestion in the book detail", async ({ page }) => {
  await page.goto("/suggestions")
  const first = rows(page).first()
  const title = (await first.getAttribute("aria-label"))!
  const category = (await first.locator("span.font-medium").innerText()).trim()
  await first.getByRole("link", { name: title }).click()
  await expect(page.locator("h1")).toHaveText(title)
  const box = page.getByRole("region", { name: "Kategorievorschlag" })
  await expect(box).toContainText(category)
  await box.getByRole("button", { name: "Annehmen" }).click()
  await expect(box).toHaveCount(0)
  await expect(page.locator("article dl")).toContainText(category)
})

test("suggestions from the command palette", async ({ page, isMobile }) => {
  test.skip(isMobile, "palette flow on desktop is enough")
  await page.goto("/")
  await expect(page.getByText(/^\d+ Bücher$/)).toBeVisible()
  await page.keyboard.press("Control+k")
  await page.getByRole("dialog", { name: "Suchen und Befehle" }).getByRole("combobox").fill(">vorschl")
  await page.getByRole("option", { name: "Vorschläge" }).click()
  await expect(page).toHaveURL(/\/suggestions$/)
})
