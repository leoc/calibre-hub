import { expect, test, type Page } from "@playwright/test"

// The mock starts with changed books at the end of the library ("Der Herr
// der Ringe" from a messy file name, two Le Guin books with the author
// spelling unified, Kahneman, a series with a reverted publisher); a run
// fills missing fields by id, "Autoren vereinheitlichen" fixes "Gaiman, Neil".
async function openMetadata(page: Page, isMobile: boolean) {
  await page.goto("/")
  await expect(page.getByText(/^\d+ Bücher$/)).toBeVisible()
  if (isMobile) await page.getByRole("button", { name: "Menü" }).click()
  await page.getByRole("link", { name: "Metadaten", exact: true }).click()
  await expect(page).toHaveURL(/\/metadata$/)
}

const groups = (page: Page) => page.getByRole("list", { name: "Geänderte Bücher" }).locator(":scope > li")
const group = (page: Page, title: string) => page.getByRole("list", { name: "Geänderte Bücher" }).getByRole("listitem", { name: title, exact: true })
const bookOf = (page: Page, href: string) => page.evaluate((h) => fetch(`/api${h}`).then((r) => r.json()), href)

test("review changes: revert one, show reverted, revert selected", async ({ page, isMobile }) => {
  await openMetadata(page, isMobile)
  await expect(page.getByText("Quellen: Datei, Hardcover, DNB, Open Library · Modell qwen2.5:3b · jede Nacht um 03:30")).toBeVisible()

  const lotr = group(page, "Der Herr der Ringe")
  await expect(lotr).toContainText("J. R. R. Tolkien")
  await expect(lotr.getByRole("listitem", { name: "Autoren", exact: true })).toContainText("Unbekannt")
  await expect(lotr.getByRole("listitem", { name: "Verlag" })).toContainText("Klett-Cotta")
  await expect(lotr.getByRole("listitem", { name: "Verlag" })).toContainText("DNB")
  await expect(lotr.getByRole("listitem", { name: "Sprachen" })).toContainText("Deutsch")

  // one field back: the title is the file name again
  await page.getByRole("button", { name: "Zurücksetzen: Titel, Der Herr der Ringe" }).click()
  const messy = group(page, "tolkien - der herr der ringe (z-lib.org)")
  await expect(messy).toBeVisible()
  await expect(messy.getByRole("listitem", { name: "Titel", exact: true })).toHaveCount(0)
  await page.getByRole("checkbox", { name: "Zurückgesetzte anzeigen" }).check()
  await expect(messy.getByRole("listitem", { name: "Titel", exact: true })).toContainText("zurückgesetzt")
  await page.getByRole("checkbox", { name: "Zurückgesetzte anzeigen" }).uncheck()

  // both Le Guin books at once
  const leGuin = groups(page).filter({ hasText: "LeGuin" })
  await expect(leGuin).toHaveCount(2)
  const hrefs: string[] = []
  for (const li of await leGuin.all()) {
    const title = (await li.getAttribute("aria-label"))!
    hrefs.push((await li.getByRole("link", { name: title, exact: true }).getAttribute("href"))!)
    await page.getByRole("checkbox", { name: `Auswählen: ${title}` }).check()
  }
  const before = await groups(page).count()
  await page.getByRole("button", { name: "Auswahl zurücksetzen (2)" }).click()
  await expect(page.getByRole("status").filter({ hasText: "4 Änderungen zurückgesetzt" })).toBeVisible()
  await expect(groups(page)).toHaveCount(before - 2)
  for (const href of hrefs) {
    const book = await bookOf(page, href)
    expect(book.authors).toEqual(["Ursula K. LeGuin"])
    expect(book.tags).not.toContain("auto-metadaten")
  }
})

test("revert all changes of a book", async ({ page, isMobile }) => {
  await openMetadata(page, isMobile)
  const lotr = group(page, "Der Herr der Ringe")
  const href = (await lotr.getByRole("link", { name: "Der Herr der Ringe" }).getAttribute("href"))!
  await page.getByRole("button", { name: "Alle zurücksetzen: Der Herr der Ringe" }).click()
  await expect(lotr).toHaveCount(0)
  const book = await bookOf(page, href)
  expect(book).toMatchObject({ title: "tolkien - der herr der ringe (z-lib.org)", authors: ["Unbekannt"], publisher: null, identifiers: {} })
  expect(book.tags).not.toContain("auto-metadaten")
})

test("run over incomplete books, then unify authors", async ({ page, isMobile }) => {
  test.skip(isMobile, "same flow on desktop is enough")
  await openMetadata(page, isMobile)
  const before = await groups(page).count()
  await page.getByRole("button", { name: "Unvollständige prüfen" }).click()
  await expect(page.getByRole("status").filter({ hasText: /^Prüfe … / })).toBeVisible()
  await expect(page.getByRole("status").filter({ hasText: /^Fertig: \d+ Bücher, \d+ Fehler$/ })).toBeVisible({ timeout: 20_000 })
  await expect.poll(() => groups(page).count()).toBeGreaterThan(before)
  await expect(page.getByText(/^Letzter Lauf: /)).toBeVisible()

  await page.getByRole("button", { name: "Autoren vereinheitlichen" }).click()
  await expect(page.getByRole("status").filter({ hasText: /^Fertig: \d+ Bücher, 0 Fehler$/ })).toBeVisible({ timeout: 20_000 })
  const gaiman = groups(page).filter({ hasText: "Gaiman, Neil" })
  await expect(gaiman.getByRole("listitem", { name: "Autoren", exact: true })).toContainText("Neil Gaiman")
  await expect(gaiman.getByRole("listitem", { name: "Autoren", exact: true })).toContainText("Autorenabgleich")
})

test("fetch metadata in the edit form: take fields, cover, save", async ({ page }) => {
  await page.goto("/books/7?edit=true")
  await page.getByRole("button", { name: "Metadaten holen" }).click()
  const dialog = page.getByRole("dialog", { name: "Metadaten holen" })
  const dnb = dialog.getByRole("list", { name: "Treffer" }).getByRole("listitem", { name: "DNB", exact: true })
  await expect(dnb).toContainText("97 %")
  await expect(dnb).toContainText("sicher")
  await expect(dnb.getByRole("link", { name: "Bei DNB ansehen" })).toHaveAttribute("href", /d-nb\.info/)

  await dialog.getByRole("button", { name: "Übernehmen: Verlag (DNB)" }).click()
  await expect(dnb.getByRole("listitem", { name: "Verlag" })).toContainText("Gleich")
  await dialog.getByRole("button", { name: "Übernehmen: ISBN (DNB)" }).click()
  // the cover is set right away
  await dialog.getByRole("button", { name: "Übernehmen: Cover (Open Library)" }).click()
  await expect(dialog.getByRole("listitem", { name: "Open Library" }).getByRole("listitem", { name: "Cover" })).toContainText("Übernommen")

  // own search text; nothing found
  await dialog.getByRole("textbox", { name: "Eigener Suchbegriff …" }).fill("nichts")
  await page.keyboard.press("Enter")
  await expect(dialog.getByText("Nichts gefunden.")).toBeVisible()
  await dialog.getByRole("button", { name: "Schließen" }).click()
  await expect(dialog).toHaveCount(0)

  await expect(page.getByRole("textbox", { name: "Verlag" })).toHaveValue("Klett-Cotta")
  await expect(page.getByRole("textbox", { name: "Wert" }).last()).toHaveValue("978360000007")
  // the cover bumped lastModified: saving must not report a conflict
  await page.getByRole("button", { name: "Speichern" }).click()
  await expect(page).not.toHaveURL(/edit=/)
  await expect(page.locator("article dl")).toContainText("Klett-Cotta")
  await expect(page.locator("article dl")).toContainText("isbn: 978360000007")
})

test("take everything of a candidate", async ({ page }) => {
  await page.goto("/books/7?edit=true")
  await page.getByRole("button", { name: "Metadaten holen" }).click()
  const dialog = page.getByRole("dialog", { name: "Metadaten holen" })
  await dialog.getByRole("button", { name: "Alle übernehmen: Open Library" }).click()
  await expect(dialog).toHaveCount(0)
  await expect(page.getByRole("combobox", { name: "Serie" })).toHaveValue("Foundation")
  await expect(page.getByRole("textbox", { name: "Band" })).toHaveValue("2")
  await expect(page.getByRole("textbox", { name: "Beschreibung" })).toContainText("Freundschaft")
  await page.getByRole("button", { name: "Speichern" }).click()
  await expect(page).not.toHaveURL(/edit=/)
  await expect(page.locator("article")).toContainText("Freundschaft")
})

test("metadata from the command palette", async ({ page, isMobile }) => {
  test.skip(isMobile, "palette flow on desktop is enough")
  await page.goto("/")
  await expect(page.getByText(/^\d+ Bücher$/)).toBeVisible()
  await page.keyboard.press("Control+k")
  await page.getByRole("dialog", { name: "Suchen und Befehle" }).getByRole("combobox").fill(">metad")
  await page.getByRole("option", { name: "Metadaten" }).click()
  await expect(page).toHaveURL(/\/metadata$/)
})
