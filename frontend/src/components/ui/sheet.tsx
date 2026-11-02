import * as React from "react"
import { Dialog as SheetPrimitive } from "radix-ui"
import { XIcon } from "lucide-react"
import { cn } from "@/lib/utils"
import { t } from "@/i18n"
import { BackToClose, Dialog as Sheet } from "./dialog"

const SheetTitle = SheetPrimitive.Title
const SheetDescription = SheetPrimitive.Description

// The close button sits in its own bar, so content never runs under it and it
// stays in reach while the content scrolls. Children are the scroll area.
function SheetContent({
  className,
  children,
  side = "right",
  header,
  closeOnBack = true,
  ...props
}: React.ComponentProps<typeof SheetPrimitive.Content> & {
  side?: "left" | "right"
  header?: React.ReactNode
  // off when opening the sheet already added a history entry (?book=)
  closeOnBack?: boolean
}) {
  return (
    <SheetPrimitive.Portal>
      <SheetPrimitive.Overlay className="fixed inset-0 z-50 bg-black/40 eink:bg-transparent" />
      <SheetPrimitive.Content
        className={cn(
          "fixed inset-y-0 z-50 flex h-full flex-col bg-background pt-[env(safe-area-inset-top)] pb-[env(safe-area-inset-bottom)] shadow-lg eink:border-black",
          side === "right"
            ? "right-0 w-full border-l pr-[env(safe-area-inset-right)] sm:max-w-xl eink:border-l-2"
            : "left-0 w-80 max-w-[85vw] border-r pl-[env(safe-area-inset-left)] eink:border-r-2",
          className,
        )}
        {...props}
      >
        <BackToClose enabled={closeOnBack} />
        <div className="flex h-14 shrink-0 items-center gap-2 pr-1.5 pl-4 eink:h-16">
          <div className="min-w-0 flex-1 truncate font-semibold">{header}</div>
          <SheetPrimitive.Close
            className="flex size-11 items-center justify-center rounded-md opacity-70 outline-none hover:bg-accent hover:opacity-100 focus-visible:opacity-100 focus-visible:ring-[3px] focus-visible:ring-ring/50 eink:size-12 touch:size-11 eink:opacity-100"
          >
            <XIcon className="size-5 eink:size-7" />
            <span className="sr-only">{t("book.close")}</span>
          </SheetPrimitive.Close>
        </div>
        {children}
      </SheetPrimitive.Content>
    </SheetPrimitive.Portal>
  )
}

export { Sheet, SheetContent, SheetTitle, SheetDescription }
