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
