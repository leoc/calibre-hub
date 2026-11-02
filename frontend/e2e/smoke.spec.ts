import { expect, test } from "@playwright/test"

test("browse, filter, open a book", async ({ page, isMobile }) => {
  await page.goto("/")
  await expect(page.getByText(/\d+ Bücher/)).toBeVisible()
  const first = page.locator("main li a").first()
  const title = (await first.locator("p").first().textContent())!.trim()

  await first.click()
  await expect(page).toHaveURL(/book=\d+/)
  await expect(page.getByRole("heading", { level: 1, name: title })).toBeVisible()
  await expect(page.getByRole("link", { name: /EPUB|PDF|AZW3/ }).first().or(page.getByText("Keine Dateien"))).toBeVisible()

  // author link filters the library
  await page.locator("article p a").first().click()
  await expect(page).toHaveURL(/author=/)
  await expect(page.getByText(/^Autor:/)).toBeVisible()
  if (!isMobile) await expect(page.getByRole("dialog")).toBeHidden()
})

test("live search and pages keep their state in the URL", async ({ page }) => {
  await page.goto("/?page=2")
  await expect(page.locator('[aria-current="page"]')).toHaveText("2")
  await page.getByRole("searchbox").fill("pratchett")
  await expect(page).toHaveURL(/q=pratchett/)
  await expect(page).not.toHaveURL(/page=/)
  await page.reload()
  await expect(page.getByRole("searchbox")).toHaveValue("pratchett")
})

test("command palette with prefixes", async ({ page, isMobile }) => {
  test.skip(isMobile, "keyboard shortcut")
  await page.goto("/")
  await expect(page.getByText(/\d+ Bücher/)).toBeVisible()
  await page.keyboard.press("/")
  await page.keyboard.type("s scheibe")
  await expect(page.getByRole("option", { name: /Scheibenwelt/ })).toBeVisible()
  await page.keyboard.press("Enter")
  await expect(page).toHaveURL(/series=Scheibenwelt/)
})

test("login after logout", async ({ page }) => {
  await page.goto("/")
  await page.getByRole("button", { name: "Abmelden" }).click()
  await expect(page).toHaveURL(/\/login/)
  await page.getByLabel("Benutzer").fill("arthur")
  await page.getByLabel("Passwort").fill("falsch")
  await page.getByRole("button", { name: "Anmelden" }).click()
  await expect(page.getByRole("alert")).toHaveText("Benutzer oder Passwort falsch.")
  await page.getByLabel("Passwort").fill("hub")
  await page.getByRole("button", { name: "Anmelden" }).click()
  await expect(page.getByText(/\d+ Bücher/)).toBeVisible()
})
