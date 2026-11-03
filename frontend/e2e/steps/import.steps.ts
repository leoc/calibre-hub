import { expect, type Page } from "@playwright/test"
import { createBdd } from "playwright-bdd"

const { When, Then } = createBdd()

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
