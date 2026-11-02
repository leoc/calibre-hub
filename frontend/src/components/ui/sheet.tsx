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
  onOpenAutoFocus,
  overlayClassName,
  ...props
}: React.ComponentProps<typeof SheetPrimitive.Content> & {
  // bottom: over the lower part of the screen, the rest stays visible
  side?: "left" | "right" | "bottom"
  header?: React.ReactNode
  // off when opening the sheet already added a history entry (?book=)
  closeOnBack?: boolean
  overlayClassName?: string
}) {
  return (
    <SheetPrimitive.Portal>
      <SheetPrimitive.Overlay className={cn("fixed inset-0 z-50 bg-black/40 eink:bg-transparent", overlayClassName)} />
      <SheetPrimitive.Content
        className={cn(
          "fixed z-50 flex flex-col bg-background outline-none pb-[env(safe-area-inset-bottom)] shadow-lg eink:border-black",
          side === "bottom"
            ? "inset-x-0 bottom-0 max-h-[60dvh] rounded-t-xl border-t pr-[env(safe-area-inset-right)] pl-[env(safe-area-inset-left)] eink:rounded-none eink:border-t-2"
            : "inset-y-0 h-full pt-[env(safe-area-inset-top)]",
          side === "right" && "right-0 w-full border-l pr-[env(safe-area-inset-right)] sm:max-w-xl eink:border-l-2",
          side === "left" && "left-0 w-80 max-w-[85vw] border-r pl-[env(safe-area-inset-left)] eink:border-r-2",
          className,
        )}
        // Radix would focus the close button and show its ring right away;
        // the sheet itself takes the focus instead (Tab reaches the button)
        onOpenAutoFocus={(e) => {
          onOpenAutoFocus?.(e)
          if (e.defaultPrevented) return
          e.preventDefault()
          ;(e.currentTarget as HTMLElement).focus()
        }}
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
