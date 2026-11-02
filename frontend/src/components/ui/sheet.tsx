import * as React from "react"
import { Dialog as SheetPrimitive } from "radix-ui"
import { XIcon } from "lucide-react"
import { cn } from "@/lib/utils"
import { t } from "@/i18n"

const Sheet = SheetPrimitive.Root
const SheetTitle = SheetPrimitive.Title
const SheetDescription = SheetPrimitive.Description

function SheetContent({
  className,
  children,
  side = "right",
  ...props
}: React.ComponentProps<typeof SheetPrimitive.Content> & { side?: "left" | "right" }) {
  return (
    <SheetPrimitive.Portal>
      <SheetPrimitive.Overlay className="fixed inset-0 z-50 bg-black/40 eink:bg-transparent" />
      <SheetPrimitive.Content
        className={cn(
          "fixed inset-y-0 z-50 flex h-full flex-col bg-background shadow-lg eink:border-black",
          side === "right" ? "right-0 w-full border-l sm:max-w-xl eink:border-l-2" : "left-0 w-80 max-w-[85vw] border-r eink:border-r-2",
          className,
        )}
        {...props}
      >
        {children}
        <SheetPrimitive.Close className="absolute top-3 right-3 rounded-md p-2 opacity-70 hover:bg-accent hover:opacity-100 eink:opacity-100">
          <XIcon className="size-5 eink:size-7" />
          <span className="sr-only">{t("book.close")}</span>
        </SheetPrimitive.Close>
      </SheetPrimitive.Content>
    </SheetPrimitive.Portal>
  )
}

export { Sheet, SheetContent, SheetTitle, SheetDescription }
