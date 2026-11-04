import { expect, type Page } from "@playwright/test"
import { createBdd } from "playwright-bdd"

const { Given, When, Then } = createBdd()

// Labels as in src/i18n/de.ts; the mock import in src/mocks/metadata.ts

const main = (page: Page) => page.getByRole("main")
const region = (page: Page, name: string) => main(page).getByRole("region", { name, exact: true })
const running = (page: Page) => region(page, "Import")
const runningCount = (page: Page) => running(page).getByRole("status")

When("I open the import page", async ({ page }) => {
  await page.goto("/import")
  await expect(page.getByRole("heading", { level: 1, name: "Import" })).toBeVisible()
})

When("I open the import page from the menu", async ({ page }) => {
  await page.goto("/")
  await expect(page.getByText(/^\d+ Bücher$/)).toBeVisible()
  await page.getByRole("button", { name: "Menü" }).click()
  await page.getByRole("link", { name: "Import", exact: true }).click()
  await expect(page).toHaveURL(/\/import$/)
  await expect(page.getByRole("heading", { level: 1, name: "Import" })).toBeVisible()
})

Then("the import phase is {string}", async ({ page }, phase: string) => {
  await expect(main(page).getByText(`Phase: ${phase}`, { exact: true })).toBeVisible()
})

Then("the backlog bar shows the imported share of about {word} new books", async ({ page }, total: string) => {
  const backlog = region(page, "Gesamtfortschritt")
  const bar = backlog.getByRole("progressbar", { name: "Altbestand importiert" })
  // about 1,360 of them, 5 more each poll
  await expect(bar).toHaveAttribute("aria-valuenow", /^[78]$/)
  await expect(backlog.getByText(new RegExp(`^1\\.\\d{3} von ~${total.replace(/\./g, "\\.")} neuen Büchern importiert \\([78] %\\)$`))).toBeVisible()
})

Then("the backlog lists {string} with {string}", async ({ page }, label: string, text: string) => {
  await expect(region(page, "Gesamtfortschritt").getByText(label)).toContainText(text)
})

Then("the running import is at {string}", async ({ page }, path: string) => {
  await expect(running(page).getByText(`Bei: ${path}`, { exact: true })).toBeVisible()
  await expect(running(page).getByRole("progressbar", { name: "Fortschritt des Laufs" })).toBeVisible()
})

Then("the running import shows {string}", async ({ page }, text: string) => {
  await expect(running(page).getByText(text, { exact: true })).toBeVisible()
})

Then("the running import lists the failed book {string} with {string}", async ({ page }, path: string, detail: string) => {
  const failures = running(page).getByRole("listitem")
  await expect(failures.filter({ hasText: path })).toHaveText(`${path}: ${detail}`)
})

Then("the scan of the dry run shows {string} at {string}", async ({ page }, rate: string, path: string) => {
  const scan = region(page, "Probelauf: Durchsuchen")
  await expect(scan.getByRole("status")).toHaveText("durchsucht … 12.840 Dateien, 6.210 Bücher")
  await expect(scan.getByText(rate)).toBeVisible()
  await expect(scan.getByText(`Bei: ${path}`, { exact: true })).toBeVisible()
  // the folders' size isn't known yet: no bar
  await expect(scan.getByRole("progressbar")).toHaveCount(0)
})

Then("the running import's count goes up without reloading the page", async ({ page }) => {
  const count = async () => Number((await runningCount(page).textContent())?.match(/(\d+) von/)?.[1])
  await expect(runningCount(page)).toHaveText(/^importiert … \d+ von 500$/)
  const before = await count()
  await expect.poll(count, { timeout: 10_000 }).toBeGreaterThan(before)
})

Then("the followup shows {string}", async ({ page }, queues: string) => {
  await expect(region(page, "Nachlauf").getByText(`Warteschlangen der importierten Bücher: ${queues}`)).toBeVisible()
})

Then("the followup waits for the import", async ({ page }) => {
  await expect(region(page, "Nachlauf").getByText("Wartet, bis der Import fertig ist.")).toBeVisible()
})

Then("the runs list a finished import that took {string}", async ({ page }, took: string) => {
  const runs = region(page, "Läufe")
  await expect(runs.getByRole("listitem").filter({ hasText: "fertig" }).filter({ hasText: took })).toHaveCount(1)
})

Then("the runs link {int} reports", async ({ page }, n: number) => {
  await expect(region(page, "Läufe").getByRole("link", { name: "Bericht (JSON)" })).toHaveCount(n)
})

Then("the page doesn't scroll sideways", async ({ page }) => {
  await expect(running(page)).toBeVisible()
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
  expect(overflow).toBeLessThanOrEqual(0)
})

// the next portion (NextPortion in src/components/backlog-import.tsx)
const portion = (page: Page) => region(page, "Nächste Portion")
const checkButton = (page: Page) => portion(page).getByRole("button", { name: "Nächste Portion prüfen" })
const startButton = (page: Page) => portion(page).getByRole("button", { name: /^Portion starten/ })
// what the page posted to the hub in a scenario
const posted = new WeakMap<Page, string[]>()

// the mock's state between two portions (src/mocks/metadata.ts)
Given("the import is {string}", async ({ page }, mode: string) => {
  await page.addInitScript((m) => localStorage.setItem("hub.mock.import", m), mode)
  const runs: string[] = []
  posted.set(page, runs)
  page.on("request", (r) => {
    if (r.method() !== "POST" || new URL(r.url()).pathname !== "/api/import") return
    const { dryRun, limit } = r.postDataJSON() as { dryRun: boolean; limit: number }
    runs.push(`${dryRun ? "a dry run" : "an import"} of ${limit} books`)
  })
})

When("I check the next portion", async ({ page }) => {
  await checkButton(page).click()
})

When("I set the portion to {int} books", async ({ page }, books: number) => {
  await portion(page).getByLabel("Bücher je Portion").fill(String(books))
})

When("I start the portion of {int} books", async ({ page }, books: number) => {
  await portion(page).getByRole("button", { name: `Portion starten (${books} Bücher)`, exact: true }).click()
})

Then("the next portion offers no start", async ({ page }) => {
  await expect(startButton(page)).toHaveCount(0)
})

Then("the next portion can start {int} books", async ({ page }, books: number) => {
  await expect(startButton(page)).toHaveText(`Portion starten (${books} Bücher)`)
  await expect(startButton(page)).toBeEnabled()
})

Then("the next portion can be checked", async ({ page }) => {
  await expect(checkButton(page)).toBeEnabled()
})

Then("the next portion says {string}", async ({ page }, reason: string) => {
  await expect(portion(page).getByRole("status")).toHaveText(reason)
})

Then("the next portion shows {string}", async ({ page }, text: string) => {
  await expect(portion(page).getByText(text, { exact: true })).toBeVisible()
})

Then("the next portion is blocked by {string}", async ({ page }, reason: string) => {
  await expect(portion(page).getByRole("status")).toHaveText(reason)
  await expect(checkButton(page)).toBeDisabled()
  await expect(startButton(page)).toHaveCount(0)
})

Then("the review fits the screen", async ({ page }) => {
  await expect(startButton(page)).toBeVisible()
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
  expect(overflow).toBeLessThanOrEqual(0)
})

Then("the hub got a dry run of {int} books, then an import of {int} books", async ({ page }, dry: number, books: number) => {
  await expect.poll(() => posted.get(page)).toEqual([`a dry run of ${dry} books`, `an import of ${books} books`])
})

Then("the hub got a dry run of {int} books, a dry run of {int} books, then an import of {int} books", async ({ page }, first: number, second: number, books: number) => {
  await expect.poll(() => posted.get(page)).toEqual([`a dry run of ${first} books`, `a dry run of ${second} books`, `an import of ${books} books`])
})

// the quality report (src/components/import-quality.tsx)
const quality = (page: Page) => region(page, "Qualität")

Then("the quality report says {string}", async ({ page }, text: string) => {
  await expect(quality(page).getByRole("status")).toHaveText(text)
})

Then("the quality report counts {string} with {string}", async ({ page }, reason: string, count: string) => {
  await expect(quality(page).getByRole("term").filter({ hasText: reason })).toBeVisible()
  await expect(quality(page).getByRole("definition").filter({ hasText: count })).toBeVisible()
})

Then("the quality report lists a run with {string}", async ({ page }, text: string) => {
  await expect(quality(page).getByRole("list", { name: "Letzte Importläufe" })).toContainText(text)
})

Then("the quality report shows {string}", async ({ page }, text: string) => {
  await expect(quality(page).getByText(text)).toBeVisible()
})

When("I draw a sample and record {int} of {int} right", async ({ page }, correct: number, checked: number) => {
  await quality(page).getByRole("button", { name: "Stichprobe ziehen" }).click()
  await expect(quality(page).getByText("Zu prüfen (1)")).toBeVisible()
  await quality(page).getByLabel("Geprüft").fill(String(checked))
  await quality(page).getByLabel("Richtig").fill(String(correct))
  await quality(page).getByRole("button", { name: "Ergebnis speichern" }).click()
})

// the repair of plain-file imports (src/components/import-repair.tsx)
const repair = (page: Page) => region(page, "Reparatur")
const proposals = (page: Page) => repair(page).getByRole("list", { name: "Reparatur" }).getByRole("listitem")

Then("the repair proposes {string} decided by {string}", async ({ page }, title: string, by: string) => {
  const item = proposals(page).filter({ hasText: `→ ${title}` })
  await expect(item).toHaveCount(1)
  await expect(item.getByText(`entschieden von: ${by}`)).toBeVisible()
})

Then("the repair lists a book decided by {string}", async ({ page }, by: string) => {
  await expect(proposals(page).filter({ hasText: `entschieden von: ${by}` })).toHaveCount(1)
})

When("I accept the repair of the first proposal", async ({ page }) => {
  await proposals(page).first().getByRole("button", { name: "Übernehmen", exact: true }).click()
})

When("I select the first proposal and reject the selected ones", async ({ page }) => {
  await proposals(page).first().getByRole("checkbox").check()
  await repair(page).getByRole("button", { name: /^Ausgewählte ablehnen/ }).click()
})

Then("the first proposal shows a cover and links to its book", async ({ page }) => {
  const first = proposals(page).first()
  await expect(first.locator("img")).toBeVisible()
  await expect(first.getByRole("link", { name: "Buchseite" })).toHaveAttribute("href", /\/books\/\d+/)
})

When("I click the first proposal", async ({ page }) => {
  await proposals(page).first().getByText("entschieden von:").click()
})

Then("the drawer shows the proposal {string} and the book", async ({ page }, change: string) => {
  const drawer = page.getByRole("dialog")
  await expect(drawer.getByText(change.replace("→ ", ""), { exact: true })).toBeVisible()
  await expect(drawer.getByRole("button", { name: "Bearbeiten" })).toBeVisible()
})

When("I accept the proposal in the drawer", async ({ page }) => {
  await page.getByRole("dialog").getByRole("button", { name: "Übernehmen", exact: true }).click()
})

When("I close the drawer", async ({ page }) => {
  await page.keyboard.press("Escape")
})

Then("the first proposal says {string}", async ({ page }, text: string) => {
  await expect(proposals(page).first().getByText(text)).toBeVisible()
})

Then("the repair lists {int} proposals", async ({ page }, count: number) => {
  await expect(proposals(page)).toHaveCount(count)
})

When("I show the band {string} of the repair", async ({ page }, band: string) => {
  await repair(page).getByLabel("Sicherheit").selectOption({ label: band })
})

When("I show the level {string} of the repair", async ({ page }, level: string) => {
  await repair(page).getByLabel("Stufe").selectOption({ label: level })
})

When("I sort the repair by {string}", async ({ page }, sort: string) => {
  await repair(page).getByLabel("Sortierung").selectOption({ label: sort })
})

When("I accept the sure proposals", async ({ page }) => {
  await repair(page).getByRole("button", { name: /^Sichere übernehmen/ }).click()
})

Then("the repair has {int} open proposals and {string}", async ({ page }, count: number, text: string) => {
  await expect(proposals(page)).toHaveCount(count)
  await expect(repair(page).getByRole("status")).toContainText(text)
})
