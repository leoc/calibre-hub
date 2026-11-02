import { expect, test } from "@playwright/test"

test.describe.configure({ mode: "serial" })

test("edit a book and save", async ({ page }) => {
  await page.goto("/?book=3")
  await page.getByRole("button", { name: "Bearbeiten" }).click()
  await expect(page).toHaveURL(/edit=true/)
  const title = page.getByRole("textbox", { name: "Titel", exact: true })
  await title.fill("Ein neuer Titel")
  await page.getByRole("combobox", { name: "Tags" }).fill("neuer-tag")
  await page.keyboard.press("Enter")
  await expect(page.getByRole("button", { name: "Speichern" })).toBeEnabled()
  await page.getByRole("button", { name: "Speichern" }).click()
  await expect(page).not.toHaveURL(/edit=/)
  await expect(page.locator("h1")).toHaveText("Ein neuer Titel")
  await expect(page.locator("article").getByText("neuer-tag")).toBeVisible()
})

test("fast tag toggles optimistically", async ({ page, isMobile }) => {
  await page.goto("/?book=5")
  const btn = page.getByRole("button", { name: "leseliste", exact: true })
  const before = await btn.getAttribute("aria-pressed")
  await btn.click()
  await expect(btn).toHaveAttribute("aria-pressed", before === "true" ? "false" : "true")
  test.skip(isMobile)
})

test("upload with duplicate handling", async ({ page }) => {
  await page.goto("/")
  await expect(page.getByText(/\d+ Bücher/)).toBeVisible()
  const input = page.locator('input[type="file"][multiple]')
  await input.setInputFiles({ name: "Mein Testbuch.epub", mimeType: "application/epub+zip", buffer: Buffer.from("x") })
  const tray = page.getByRole("region", { name: "Uploads" })
  await expect(tray.getByText("Mein Testbuch")).toBeVisible()
  await expect(tray.getByRole("button", { name: "Bearbeiten" })).toBeVisible()
  // same title again: duplicate
  await input.setInputFiles({ name: "Mein Testbuch.epub", mimeType: "application/epub+zip", buffer: Buffer.from("x") })
  await expect(tray.getByText("Schon in der Bibliothek:")).toBeVisible()
  await tray.getByRole("button", { name: "Trotzdem als neues Buch" }).click()
  await expect(tray.getByRole("button", { name: "Bearbeiten" })).toHaveCount(2)
})

test("bulk: add a tag to the whole page", async ({ page, isMobile }) => {
  test.skip(isMobile, "same flow on desktop is enough")
  await page.goto("/?series=Erdsee")
  await page.getByRole("button", { name: "Auswählen" }).click()
  await page.getByRole("button", { name: "Seite auswählen" }).click()
  await page.getByRole("button", { name: "Tags hinzufügen" }).click()
  await page.getByRole("combobox", { name: "Tags" }).fill("bulk-test")
  await page.keyboard.press("Enter")
  await page.getByRole("button", { name: "Anwenden" }).click()
  await expect(page.getByText(/geändert, 0 Fehler/)).toBeVisible({ timeout: 10_000 })
  await page.getByRole("button", { name: "Auswahl beenden" }).click()
  // mock data lives in the page, so navigate inside the app
  await page.getByRole("navigation").getByRole("link", { name: /bulk-test/ }).click()
  await expect(page).toHaveURL(/tag=bulk-test/)
  await expect(page.getByText(/^\d+ Bücher$/)).toHaveText("20 Bücher")
})

test("bulk on all matches, with a retry for failed books", async ({ page, isMobile }) => {
  test.skip(isMobile, "same flow on desktop is enough")
  await page.goto("/")
  await page.getByRole("button", { name: "Auswählen" }).click()
  await page.getByRole("button", { name: /^Alle .* Treffer$/ }).click()
  await page.getByRole("button", { name: "Kategorie setzen" }).click()
  await page.getByRole("combobox", { name: "Kategorie" }).fill("Neu › Sortiert")
  await page.getByRole("button", { name: "Anwenden" }).click()
  await page.getByRole("button", { name: /Bücher ändern/ }).click()
  await expect(page.getByText(/geändert, 4 Fehler/)).toBeVisible({ timeout: 20_000 })
  await page.getByRole("button", { name: "4 erneut versuchen" }).click()
  await expect(page.getByText(/4 geändert, 0 Fehler/)).toBeVisible({ timeout: 10_000 })
})

test("cover: from URL and online search", async ({ page }) => {
  await page.goto("/books/7?edit=true")
  await page.getByRole("button", { name: "Cover ändern" }).click()
  await page.getByRole("button", { name: "Online suchen" }).click()
  await expect(page.getByText(/Open Library/).first()).toBeVisible()
  await page.getByRole("textbox", { name: "Von URL" }).fill("https://example.org/c.jpg")
  await page.keyboard.press("Enter")
  await expect(page.getByText("Cover konnte nicht gesetzt werden")).toHaveCount(0)
  // saving the form afterwards must not report a conflict: the cover bumped lastModified
  await page.getByRole("textbox", { name: "Titel", exact: true }).fill("Nach Coverwechsel")
  await page.getByRole("button", { name: "Speichern" }).click()
  await expect(page.locator("h1")).toHaveText("Nach Coverwechsel")
})
