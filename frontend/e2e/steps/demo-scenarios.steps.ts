import { expect } from "@playwright/test"
import { createBdd } from "playwright-bdd"

const { When, Then } = createBdd()

// src/mocks/scenarios.ts
const heading = { level: 1, name: "Eingang" }

When("I open the demo scenario {string}", async ({ page }, scenario: string) => {
  await page.goto(`/eingang?scenario=${scenario}`)
  await expect(page.getByRole("heading", heading)).toBeVisible()
})

When("I switch the demo to {string}", async ({ page }, label: string) => {
  const switcher = page.getByTestId("mock-scenarios")
  await switcher.locator("summary").click()
  await switcher.getByRole("link", { name: label }).click()
  await expect(switcher.locator("summary")).toHaveText(`Demo: ${label}`)
})

When("I load the Eingang again", async ({ page }) => {
  await page.goto("/eingang")
  await expect(page.getByRole("heading", heading)).toBeVisible()
})

When("I trash the first sure duplicate", async ({ page }) => {
  await page.getByRole("main").getByLabel("Art").selectOption({ label: "Sichere Dubletten (120)" })
  await page.locator("[data-entry]").first().getByRole("button", { name: "Papierkorb" }).click()
})

Then("the demo switcher says {string}", async ({ page }, text: string) => {
  await expect(page.getByTestId("mock-scenarios").locator("summary")).toHaveText(text)
})
