import { expect, type Page } from "@playwright/test"
import { createBdd } from "playwright-bdd"

const { Given, When, Then } = createBdd()

// Labels as in src/i18n/de.ts. No reload after the login: it would reset
// the mock session to the admin.
const results = (page: Page) => page.getByText(/^\d+ Bücher$|^1 Buch$/)
const detail = (page: Page) => page.locator("article").filter({ has: page.getByRole("heading", { level: 1 }) })
const upload = (page: Page) => page.getByRole("banner").getByTitle("Bücher hochladen")

// --- Given ------------------------------------------------------------------

Given("I am logged in as {string}", async ({ page }, user: string) => {
  await page.goto("/login")
  await page.getByLabel("Benutzer").fill(user)
  await page.getByLabel("Passwort").fill("hub")
  await page.getByRole("button", { name: "Anmelden" }).click()
  await expect(results(page)).toBeVisible()
})

// --- When -------------------------------------------------------------------

When("I open the first book in the library", async ({ page }) => {
  await page.locator('main a[href*="book="]').first().click()
  await expect(detail(page)).toBeVisible()
})

// --- Then -------------------------------------------------------------------

Then("the detail offers no button {string}", async ({ page }, name: string) => {
  await expect(detail(page).getByRole("button", { name, exact: true })).toHaveCount(0)
})

Then("the detail offers the button {string}", async ({ page }, name: string) => {
  await expect(detail(page).getByRole("button", { name, exact: true })).toBeVisible()
})

Then("there is no upload", async ({ page }) => {
  await expect(upload(page)).toHaveCount(0)
})

Then("there is an upload", async ({ page }) => {
  await expect(upload(page)).toBeVisible()
})

Then("there is no button {string}", async ({ page }, name: string) => {
  await expect(page.getByRole("button", { name, exact: true })).toHaveCount(0)
})

Then("there is a button {string}", async ({ page }, name: string) => {
  await expect(page.getByRole("button", { name, exact: true })).toBeVisible()
})

Then("the sidebar has no link {string}", async ({ page }, name: string) => {
  await expect(page.getByRole("navigation").getByRole("link", { name })).toHaveCount(0)
})
