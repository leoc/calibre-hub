import { defineConfig, devices } from "@playwright/test"
import { defineBddConfig } from "playwright-bdd"

// Runs against `pnpm dev:mock`. On NixOS point CHROMIUM_PATH at a system
// chromium (e.g. $(which chromium)) instead of downloading browsers.
const executablePath = process.env.CHROMIUM_PATH || undefined
const port = 5174

const phone = devices["Pixel 7"]
const desktop = { ...devices["Desktop Chrome"], viewport: { width: 1400, height: 900 } }

// Gherkin scenarios (e2e/features), once per device class
const bdd = (name: string, tags: string) =>
  defineBddConfig({ features: "e2e/features/*.feature", steps: "e2e/steps/*.ts", outputDir: `.features-gen/${name}`, tags })

export default defineConfig({
  fullyParallel: true,
  reporter: "list",
  use: { baseURL: `http://localhost:${port}`, launchOptions: { executablePath } },
  projects: [
    { name: "desktop", testDir: "e2e", testMatch: "*.spec.ts", use: desktop },
    { name: "phone", testDir: "e2e", testMatch: "*.spec.ts", use: phone },
    { name: "bdd-wide", testDir: bdd("wide", "not @narrow"), use: desktop },
    { name: "bdd-narrow", testDir: bdd("narrow", "not @wide"), use: phone },
  ],
  webServer: {
    command: `pnpm exec vite --mode mock --port ${port} --strictPort`,
    port,
    reuseExistingServer: !process.env.CI,
  },
})
