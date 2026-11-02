import { useSyncExternalStore, type ReactNode } from "react"
import { Check } from "lucide-react"
import type { LibrarySearch } from "@/lib/search"
import { selection, useSelection } from "@/lib/selection"
import { keyboard } from "@/lib/keyboard"
import { cn } from "@/lib/utils"
import { LibraryLink } from "./library-link"

// Roving tabindex: only the active book (or the first, before there is one)
// is a tab stop; arrows and hjkl move from there.
function useTabStop(id: number, order: number[]): "active" | "stop" | null {
  return useSyncExternalStore(keyboard.subscribe, () => {
    const active = keyboard.get().active
    if (active === id) return "active"
    return (active == null || !order.includes(active)) && order[0] === id ? "stop" : null
  })
}

// Keyboard focus: a clear ring off the book (E-Ink: thick and black); the
// scroll margins keep it clear of the sticky header and the bulk bar.
const focusRing =
  "scroll-mt-20 scroll-mb-32 focus-visible:outline-[3px] focus-visible:outline-offset-2 focus-visible:outline-ring eink:focus-visible:outline-4 eink:focus-visible:outline-black"

// A book in grid or list: opens the detail, or toggles it in selection mode.
export function BookItem({
  id,
  order,
  search,
  className,
  selectedClassName = "ring-offset-2",
  children,
}: {
  id: number
  order: number[]
  search: LibrarySearch
  className?: string
  // where the selection ring sits
  selectedClassName?: string
  children: ReactNode
}) {
  const sel = useSelection()
  const stop = useTabStop(id, order)
  const keys = { "data-book-id": id, "data-active": stop === "active" || undefined, tabIndex: stop ? 0 : -1, onFocus: () => keyboard.setActive(id) }
  if (!sel.active) {
    return (
      <LibraryLink search={{ ...search, book: id }} className={cn(className, focusRing)} {...keys}>
        {children}
      </LibraryLink>
    )
  }
  const on = sel.all || sel.ids.has(id)
  return (
    <button
      type="button"
      role="checkbox"
      aria-checked={on}
      onClick={(e) => selection.toggle(id, e.shiftKey, order)}
      {...keys}
      className={cn("relative w-full text-left", className, focusRing, on && cn("ring-2 ring-primary ring-offset-background eink:ring-4", selectedClassName))}
    >
      <span
        aria-hidden
        data-check
        className={cn(
          "absolute top-1.5 left-1.5 z-10 flex size-6 items-center justify-center rounded-sm border-2 border-primary bg-background eink:size-8 eink:border-black",
          on && "bg-primary text-primary-foreground eink:bg-black eink:text-white",
        )}
      >
        {on && <Check className="size-4" />}
      </span>
      {children}
    </button>
  )
}
