import { X } from "lucide-react"
import { toast, useToast } from "@/lib/toast"
import { useSelection } from "@/lib/selection"
import { t } from "@/i18n"
import { cn } from "@/lib/utils"
import { Button } from "./button"

// Mounted once in the app shell. The live region is always there so screen
// readers announce what appears in it; the message itself is the status. No animation (E-Ink); clear of the
// bulk bar while books are selected.
export function Toaster() {
  const current = useToast()
  const { active: selecting } = useSelection()
  return (
    <div
      aria-live="polite"
      className={cn(
        "pointer-events-none fixed inset-x-0 z-50 flex justify-center px-4",
        selecting ? "bottom-36 xl:bottom-24" : "bottom-[max(1rem,env(safe-area-inset-bottom))]",
      )}
    >
      {current && (
        <div
          key={current.id}
          role="status"
          aria-label={t("toast.label")}
          className="pointer-events-auto flex max-w-lg items-center gap-2 rounded-md border bg-popover py-1.5 pr-1.5 pl-4 text-sm text-popover-foreground shadow-lg eink:border-2 eink:border-black eink:text-base eink:shadow-none"
        >
          <span className="min-w-0 flex-1">{current.text}</span>
          {current.action && (
            <Button
              variant="outline"
              size="sm"
              onClick={() => {
                const run = current.action!.run
                toast.dismiss(current.id)
                run()
              }}
            >
              {current.action.label}
            </Button>
          )}
          <Button variant="ghost" size="icon" onClick={() => toast.dismiss(current.id)} aria-label={t("toast.close")} title={t("toast.close")}>
            <X />
          </Button>
        </div>
      )}
    </div>
  )
}
