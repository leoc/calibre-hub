import { defineConfig, devices } from "@playwright/test"

// Runs against `pnpm dev:mock`. On NixOS point CHROMIUM_PATH at a system
// chromium (e.g. $(which chromium)) instead of downloading browsers.
const executablePath = process.env.CHROMIUM_PATH || undefined
const port = 5174

export default defineConfig({
  testDir: "e2e",
  fullyParallel: true,
  reporter: "list",
  use: { baseURL: `http://localhost:${port}`, launchOptions: { executablePath } },
  projects: [
    { name: "desktop", use: { ...devices["Desktop Chrome"], viewport: { width: 1400, height: 900 } } },
    { name: "phone", use: { ...devices["Pixel 7"] } },
  ],
  webServer: {
    command: `pnpm exec vite --mode mock --port ${port} --strictPort`,
    port,
    reuseExistingServer: !process.env.CI,
  },
})
