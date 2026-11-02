import { expect, test, type Page } from "@playwright/test"

// Sorting in a library where most books have no category yet (#8404).

const results = (page: Page) => page.getByText(/^\d+ Bücher$/)
const count = async (page: Page) => Number((await results(page).textContent())!.replace(/\D/g, ""))
const bookId = (page: Page) => Number(new URL(page.url()).searchParams.get("book"))

test("categorize books without a category one after another", async ({ page, isMobile }) => {
  await page.goto("/")
  await expect(results(page)).toBeVisible()
  // phones: sidebar in the drawer
  if (isMobile) await page.getByRole("button", { name: "Menü" }).click()
  await page.getByRole("link", { name: /^Ohne Kategorie \d+$/ }).click()
  await expect(page).toHaveURL(/unsorted=(1|true)/)
  await expect(page.getByRole("link", { name: "Filter Ohne Kategorie entfernen" })).toBeVisible()
  const before = await count(page)

  await page.locator("main li a[href*='book=']").first().click()
  await page.getByRole("button", { name: "Bearbeiten" }).click()
  const first = bookId(page)
  const input = page.getByRole("combobox", { name: "Kategorie" })
  await expect(input).toHaveValue("")

  // a dot inside a name can't be stored
  await input.fill("Reisen/St. Petersburg")
  await expect(page.getByRole("alert")).toContainText("„St. Petersburg“ enthält einen Punkt")
  await expect(page.getByRole("button", { name: "Speichern" })).toBeDisabled()

  await input.fill("Roman/Neu")
  await page.getByRole("button", { name: "Speichern" }).click()
  // on to the next unsorted book, form open
  await expect.poll(() => bookId(page)).not.toBe(first)
  await expect(page).toHaveURL(/edit=true/)
  await expect(page.getByRole("combobox", { name: "Kategorie" })).toHaveValue("")
  const saved = await page.evaluate((id) => fetch(`/api/books/${id}`).then((r) => r.json()), first)
  expect(saved.custom.kategorie).toBe("Roman.Neu")

  await page.getByRole("button", { name: "Abbrechen" }).click()
  // phones: back walks through the books done (next one, first one, list)
  if (isMobile) {
    await page.getByRole("button", { name: "Zurück zur Liste" }).click()
    await expect(page).toHaveURL(new RegExp(`book=${first}`))
    await page.getByRole("button", { name: "Zurück zur Liste" }).click()
  } else await page.keyboard.press("Escape")
  await expect(results(page)).toHaveText(`${before - 1} Bücher`)
  if (isMobile) await page.getByRole("button", { name: "Menü" }).click()
  await expect(page.getByRole("link", { name: `Ohne Kategorie ${before - 1}` })).toBeVisible()
})

test("bulk: number a series in selection order", async ({ page, isMobile }) => {
  test.skip(isMobile, "same flow on desktop is enough")
  await page.goto("/")
  await expect(results(page)).toBeVisible()
  await page.getByRole("button", { name: "Auswählen" }).click()

  // numbering needs explicitly selected books
  await page.getByRole("button", { name: /^Alle .* Treffer$/ }).click()
  await page.getByRole("button", { name: "Serie setzen" }).click()
  await page.getByRole("combobox", { name: "Serie" }).fill("Testreihe")
  await expect(page.getByRole("checkbox", { name: /In Auswahlreihenfolge durchnummerieren/ })).toBeDisabled()
  await page.getByRole("button", { name: "Abbrechen" }).click()
  await page.getByRole("button", { name: "Keine" }).click()

  const items = page.locator("main li [role=checkbox]")
  const picked: string[] = []
  for (const i of [2, 0, 1]) {
    await items.nth(i).click()
    picked.push((await items.nth(i).locator("p").first().textContent())!.trim())
  }
  await page.getByRole("button", { name: "Serie setzen" }).click()
  await page.getByRole("combobox", { name: "Serie" }).fill("Testreihe")
  await page.getByRole("checkbox", { name: /In Auswahlreihenfolge durchnummerieren/ }).check()
  await page.getByRole("button", { name: "Anwenden" }).click()
  await expect(page.getByText("3 geändert, 0 Fehler")).toBeVisible({ timeout: 10_000 })
  await page.getByRole("button", { name: "Auswahl beenden" }).click()

  // mock data lives in the page, so navigate inside the app; a series sorts by volume
  await page.getByRole("navigation").getByRole("link", { name: /Testreihe/ }).click()
  await expect(results(page)).toHaveText("3 Bücher")
  const titles = await page.locator("main li a[href*='book=']").evaluateAll((as) => as.map((a) => a.querySelector("p")!.textContent!.trim()))
  expect(titles).toEqual(picked)
  await expect(page.locator("main li a[href*='book=']").first()).toContainText("1")
})

test("Shift+Enter carries the category to the next unsorted book", async ({ page, isMobile }) => {
  test.skip(isMobile, "keyboard shortcut")
  await page.goto("/?unsorted=true")
  await expect(results(page)).toBeVisible()
  await page.locator("main li a[href*='book=']").first().click()
  await page.getByRole("button", { name: "Bearbeiten" }).click()
  const first = bookId(page)
  await expect(page.getByText("Shift+Enter speichert")).toBeVisible()
  const input = page.getByRole("combobox", { name: "Kategorie" })
  await input.fill("Roman/Neu")
  await input.press("Shift+Enter")
  await expect.poll(() => bookId(page)).not.toBe(first)
  const second = bookId(page)
  // next book starts with the same category, Shift+Enter again goes on
  await expect(page.getByRole("combobox", { name: "Kategorie" })).toHaveValue("Roman/Neu")
  await page.getByRole("combobox", { name: "Kategorie" }).press("Shift+Enter")
  await expect.poll(() => bookId(page)).not.toBe(second)
  // a normal save ends the carry-over
  const third = page.getByRole("combobox", { name: "Kategorie" })
  await expect(third).toHaveValue("Roman/Neu")
  await page.getByRole("button", { name: "Speichern" }).click()
  await expect.poll(() => bookId(page)).not.toBe(second)
  await expect(page.getByRole("combobox", { name: "Kategorie" })).toHaveValue("")
  for (const id of [first, second]) {
    const b = await page.evaluate((i) => fetch(`/api/books/${i}`).then((r) => r.json()), id)
    expect(b.custom.kategorie).toBe("Roman.Neu")
  }
})
