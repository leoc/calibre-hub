import { Monitor, Moon, Sun, BookOpenText } from "lucide-react"
import { THEMES, useTheme, type Theme } from "@/lib/theme"
import { t } from "@/i18n"
import { cn } from "@/lib/utils"

const ICONS: Record<Theme, typeof Sun> = { system: Monitor, light: Sun, dark: Moon, eink: BookOpenText }

// Segmented buttons instead of a dropdown: one tap, works on E-Ink.
export function ThemeSwitch({ className }: { className?: string }) {
  const { theme, setTheme } = useTheme()
  return (
    <div role="radiogroup" aria-label={t("theme.label")} className={cn("grid grid-cols-4 gap-1 rounded-md border p-1 eink:border-2", className)}>
      {THEMES.map((th) => {
        const Icon = ICONS[th]
        return (
          <button
            key={th}
            role="radio"
            aria-checked={theme === th}
            onClick={() => setTheme(th)}
            className="flex flex-col items-center gap-0.5 rounded-sm px-1 py-1.5 text-xs hover:bg-accent aria-checked:bg-primary aria-checked:text-primary-foreground eink:min-h-12 touch:min-h-11 eink:text-sm"
          >
            <Icon className="size-4" aria-hidden />
            {t(`theme.${th}`)}
          </button>
        )
      })}
    </div>
  )
}

export function EinkSuggestion() {
  const { suggestEink, setTheme, dismissEinkSuggestion } = useTheme()
  if (!suggestEink) return null
  return (
    <div role="status" className="flex flex-wrap items-center gap-3 border-b-2 border-black bg-white px-4 py-3 text-black">
      <span className="text-base">{t("theme.einkSuggest")}</span>
      <button
        className="h-12 rounded border-2 border-black bg-black px-4 text-white"
        onClick={() => {
          setTheme("eink")
          dismissEinkSuggestion()
        }}
      >
        {t("theme.einkYes")}
      </button>
      <button className="h-12 rounded border-2 border-black px-4" onClick={dismissEinkSuggestion}>
        {t("theme.einkNo")}
      </button>
    </div>
  )
}
