import { expect } from "@playwright/test"
import { createBdd } from "playwright-bdd"

const { When, Then } = createBdd()

const tray = (page: import("@playwright/test").Page) => page.getByRole("region", { name: "Uploads" })

When("I upload {string}", async ({ page }, name: string) => {
  await page.locator('input[type="file"][multiple]').setInputFiles({ name, mimeType: "application/octet-stream", buffer: Buffer.from("x") })
})

Then("the tray says {string}", async ({ page }, text: string) => {
  await expect(tray(page).getByText(text)).toBeVisible()
})

Then("the tray offers {string}", async ({ page }, name: string) => {
  await expect(tray(page).getByRole("button", { name }).first()).toBeVisible()
})

Then("the tray offers {int} times {string}", async ({ page }, count: number, name: string) => {
  await expect(tray(page).getByRole("button", { name })).toHaveCount(count)
})

When("I press the tray's {string}", async ({ page }, name: string) => {
  await tray(page).getByRole("button", { name }).click()
})

When("I follow the tray's link {string}", async ({ page }, name: string) => {
  await tray(page).getByRole("link", { name }).click()
})

Then("the page is the Eingang", async ({ page }) => {
  await expect(page.getByRole("heading", { level: 1, name: "Eingang" })).toBeVisible()
})
