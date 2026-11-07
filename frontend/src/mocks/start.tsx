import { worker } from "./browser"
import { mountSwitcher } from "./scenario-switcher"
import { scenarioAsked } from "./scenarios"

// All that `pnpm dev:mock` adds to the app, behind one import in main.tsx
export async function startMocks() {
  await worker.start({ quiet: true })
  // the e2e tests measure and tap what is on the page: only theirs about it
  if (!navigator.webdriver || scenarioAsked()) mountSwitcher()
}
