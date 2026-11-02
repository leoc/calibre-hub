import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from "react"
import { load, save } from "./storage"

export const THEMES = ["system", "light", "dark", "eink"] as const
export type Theme = (typeof THEMES)[number]

const KEY = "hub.theme"
const ASKED_KEY = "hub.einkAsked"

interface ThemeState {
  theme: Theme
  setTheme: (t: Theme) => void
  eink: boolean
  suggestEink: boolean
  dismissEinkSuggestion: () => void
}

const ThemeContext = createContext<ThemeState | null>(null)

// Onyx Boox browsers report "Boox"/"Onyx" or the model in the user agent.
export const looksLikeEink = (ua: string) => /\b(boox|onyx|kobo|kindle|pocketbook|remarkable)\b/i.test(ua)

function apply(theme: Theme) {
  const root = document.documentElement
  const dark = theme === "dark" || (theme === "system" && matchMedia("(prefers-color-scheme: dark)").matches)
  root.classList.toggle("dark", dark)
  root.classList.toggle("eink", theme === "eink")
  document.querySelector('meta[name="theme-color"]')?.setAttribute("content", dark ? "#09090b" : "#ffffff")
}

export function ThemeProvider({ children }: { children: ReactNode }) {
  const [theme, setThemeState] = useState<Theme>(() => load(KEY, THEMES, "system"))
  const [suggestEink, setSuggestEink] = useState(
    () => theme !== "eink" && looksLikeEink(navigator.userAgent) && load(ASKED_KEY, ["1"], "0" as "1") !== "1",
  )

  useEffect(() => {
    apply(theme)
    if (theme !== "system") return
    const mq = matchMedia("(prefers-color-scheme: dark)")
    const onChange = () => apply("system")
    mq.addEventListener("change", onChange)
    return () => mq.removeEventListener("change", onChange)
  }, [theme])

  const setTheme = useCallback((t: Theme) => {
    save(KEY, t)
    setThemeState(t)
  }, [])

  const dismissEinkSuggestion = useCallback(() => {
    save(ASKED_KEY, "1")
    setSuggestEink(false)
  }, [])

  return (
    <ThemeContext.Provider value={{ theme, setTheme, eink: theme === "eink", suggestEink, dismissEinkSuggestion }}>
      {children}
    </ThemeContext.Provider>
  )
}

export function useTheme() {
  const ctx = useContext(ThemeContext)
  if (!ctx) throw new Error("useTheme outside ThemeProvider")
  return ctx
}
