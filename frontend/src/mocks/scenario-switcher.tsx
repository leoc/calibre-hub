import { createRoot } from "react-dom/client"
import { SCENARIOS, scenario, type Scenario } from "./scenarios"

// Next to the app, not in it (only mocks/start.tsx imports this), and a choice
// loads the page, which is what starts a scenario.
function Switcher() {
  const link = (s: string) => `${location.pathname}?scenario=${s}`
  return (
    <details data-testid="mock-scenarios" className="fixed left-2 bottom-2 z-[60] rounded border border-border bg-background/90 px-2 py-1 text-xs text-muted-foreground shadow print:hidden">
      <summary className="cursor-pointer select-none">Demo: {SCENARIOS[scenario]}</summary>
      <ul className="mt-1 space-y-1">
        {(Object.keys(SCENARIOS) as Scenario[]).map((s) => (
          <li key={s}>
            <a className={s === scenario ? "font-semibold text-foreground" : "underline"} href={link(s)} aria-current={s === scenario ? "true" : undefined}>
              {SCENARIOS[s]}
            </a>
          </li>
        ))}
      </ul>
    </details>
  )
}

export function mountSwitcher() {
  const el = document.createElement("div")
  document.body.append(el)
  createRoot(el).render(<Switcher />)
}
