import * as React from "react"
import { Dialog as DialogPrimitive } from "radix-ui"
import { XIcon } from "lucide-react"
import { cn } from "@/lib/utils"
import { useBackToClose } from "@/lib/back-to-close"
import { t } from "@/i18n"

const DialogTrigger = DialogPrimitive.Trigger
const DialogClose = DialogPrimitive.Close
const DialogTitle = DialogPrimitive.Title
const DialogDescription = DialogPrimitive.Description

const CloseContext = React.createContext<() => void>(() => {})

// Radix' Root, plus a way for the content to close it (the back button).
function Dialog({ onOpenChange, ...props }: React.ComponentProps<typeof DialogPrimitive.Root>) {
  const close = React.useCallback(() => onOpenChange?.(false), [onOpenChange])
  return (
    <CloseContext.Provider value={close}>
      <DialogPrimitive.Root onOpenChange={onOpenChange} {...props} />
    </CloseContext.Provider>
  )
}

// Rendered inside the content, so it exists only while the dialog is open.
function BackToClose({ enabled = true }: { enabled?: boolean }) {
  useBackToClose(React.useContext(CloseContext), enabled)
  return null
}

function DialogOverlay({ className, ...props }: React.ComponentProps<typeof DialogPrimitive.Overlay>) {
  return (
    <DialogPrimitive.Overlay
      className={cn(
        "fixed inset-0 z-50 bg-black/50 data-[state=open]:animate-in data-[state=open]:fade-in-0 eink:bg-transparent",
        className,
      )}
      {...props}
    />
  )
}

// Phones: a sheet from the bottom, buttons in thumb reach. Larger screens:
// centered near the top. Scrolls inside when a long body (or the keyboard)
// makes it taller than the screen; the title keeps clear of the close button.
function DialogContent({
  className,
  children,
  showClose = true,
  ...props
}: React.ComponentProps<typeof DialogPrimitive.Content> & { showClose?: boolean }) {
  return (
    <DialogPrimitive.Portal>
      <DialogOverlay />
      <DialogPrimitive.Content
        className={cn(
          "fixed bottom-0 left-1/2 z-50 grid max-h-[calc(100dvh-env(safe-area-inset-top)-2rem)] w-full max-w-lg -translate-x-1/2 gap-4 overflow-y-auto rounded-t-xl border bg-background p-6 pb-[max(1.5rem,env(safe-area-inset-bottom))] shadow-lg sm:top-[10vh] sm:bottom-auto sm:max-h-[calc(100dvh-10vh-1rem)] sm:w-[calc(100%-2rem)] sm:rounded-lg sm:pb-6 eink:border-[3px] [&>h2]:pr-8",
          className,
        )}
        {...props}
      >
        <BackToClose />
        {children}
        {showClose && (
          <DialogPrimitive.Close className="absolute top-2.5 right-2.5 flex size-9 items-center justify-center rounded-md opacity-70 outline-none hover:bg-accent hover:opacity-100 focus-visible:opacity-100 focus-visible:ring-[3px] focus-visible:ring-ring/50 eink:size-12 touch:size-11 eink:opacity-100">
            <XIcon className="size-4 eink:size-6" />
            <span className="sr-only">{t("book.close")}</span>
          </DialogPrimitive.Close>
        )}
      </DialogPrimitive.Content>
    </DialogPrimitive.Portal>
  )
}

export { Dialog, DialogTrigger, DialogClose, DialogContent, DialogTitle, DialogDescription, BackToClose }
