import { expect, test, type Page } from "@playwright/test"

// The mock library lives in the page: navigate inside the app after changes.
async function openTrash(page: Page, isMobile: boolean) {
  if (isMobile) await page.getByRole("button", { name: "Menü" }).click()
  await page.getByRole("link", { name: "Papierkorb" }).click()
  await expect(page).toHaveURL(/\/trash$/)
}

test("delete a book from the detail and restore it from the trash", async ({ page, isMobile }) => {
  await page.goto("/books/11")
  const title = await page.locator("h1").innerText()
  await page.getByRole("button", { name: "Löschen" }).click()
  const dialog = page.getByRole("dialog", { name: "Buch löschen?" })
  await expect(dialog).toContainText(title)
  // cancel keeps the book
  await dialog.getByRole("button", { name: "Abbrechen" }).click()
  await expect(dialog).toHaveCount(0)
  await page.getByRole("button", { name: "Löschen" }).click()
  await page.getByRole("button", { name: "In den Papierkorb" }).click()
  await expect(page).toHaveURL(/\/$|\/\?/)
  await expect(page.getByText(/^\d+ Bücher$/)).toHaveText("399 Bücher")

  await openTrash(page, isMobile)
  const list = page.getByRole("list", { name: "Papierkorb" })
  await expect(list.getByText(title, { exact: true })).toBeVisible()
  await list.getByRole("button", { name: `Wiederherstellen: ${title}` }).click()
  await expect(page.getByRole("status")).toContainText(`„${title}“ ist wieder in der Bibliothek.`)
  await expect(page.getByText("Der Papierkorb ist leer.")).toBeVisible()
  await page.getByRole("status").getByRole("link", { name: "Öffnen" }).click()
  await expect(page.locator("h1")).toHaveText(title)
})

test("bulk delete with confirmation, trash from the command palette", async ({ page, isMobile }) => {
  test.skip(isMobile, "same flow on desktop is enough")
  await page.goto("/?series=Erdsee")
  await page.getByRole("button", { name: "Auswählen" }).click()
  await page.getByRole("button", { name: "Seite auswählen" }).click()
  await page.getByRole("button", { name: "Löschen" }).click()
  const dialog = page.getByRole("dialog")
  await expect(dialog).toContainText("in den Papierkorb verschoben")
  await dialog.getByRole("button", { name: "Ja, 20 Bücher löschen" }).click()
  await expect(page.getByText("20 gelöscht, 0 Fehler")).toBeVisible({ timeout: 10_000 })
  await expect(page.getByText("Keine Bücher gefunden.")).toBeVisible()

  await page.keyboard.press("Control+k")
  await page.getByRole("combobox").fill(">papier")
  await page.getByRole("option", { name: "Papierkorb" }).click()
  await expect(page).toHaveURL(/\/trash$/)
  await expect(page.getByRole("list", { name: "Papierkorb" }).getByRole("listitem")).toHaveCount(20)
})
