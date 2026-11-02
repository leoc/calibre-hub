import { expect, test, type Page } from "@playwright/test"

// Android's back button closes an open drawer, dialog or palette instead of
// leaving the page (src/lib/back-to-close.ts).

const results = (page: Page) => page.getByText(/^\d+ Bücher$/)

test("Back closes the palette and the drawer, then works as usual", async ({ page, isMobile }) => {
  await page.goto("/?q=insel")
  await expect(results(page)).toBeVisible()
  const start = page.url()

  // first entry of the tab: without the extra entry Back would leave the app
  if (isMobile) await page.getByRole("banner").getByLabel("Suchen …", { exact: true }).click()
  else await page.getByRole("button", { name: "Command-Palette öffnen" }).click()
  const palette = page.getByRole("dialog", { name: "Suchen und Befehle" })
  await expect(palette).toBeVisible()
  await page.waitForTimeout(50)
  await page.goBack()
  await expect(palette).toBeHidden()
  expect(page.url()).toBe(start)

  if (isMobile) {
    await page.getByRole("button", { name: "Menü" }).click()
    const drawer = page.getByRole("dialog", { name: "Bibliothek" })
    await expect(drawer).toBeVisible()
    await page.waitForTimeout(50)
    await page.goBack()
    await expect(drawer).toBeHidden()
    expect(page.url()).toBe(start)

    // a link in the drawer replaces the drawer's entry: one Back returns
    await page.getByRole("button", { name: "Menü" }).click()
    await page.getByRole("dialog", { name: "Bibliothek" }).getByRole("link", { name: /^Urlaub/ }).click()
    await expect(page).toHaveURL(/list=2/)
    await page.goBack()
    await expect(page).toHaveURL(start)
  }
})

test("closing a dialog with its button leaves no extra history entry", async ({ page }) => {
  await page.goto("/")
  await page.goto("/books/11")
  await expect(page.locator("h1")).toBeVisible()
  await page.getByRole("button", { name: "Löschen" }).click()
  const dialog = page.getByRole("dialog", { name: "Buch löschen?" })
  await expect(dialog).toBeVisible()
  await page.waitForTimeout(50)
  await dialog.getByRole("button", { name: "Abbrechen" }).click()
  await expect(dialog).toBeHidden()
  // one Back returns to the library, not to the closed dialog
  await page.waitForTimeout(100)
  await page.goBack()
  await expect(page).toHaveURL(/\/$/)
})
