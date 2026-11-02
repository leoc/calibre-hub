import type { ReactNode } from "react"
import { Check } from "lucide-react"
import type { LibrarySearch } from "@/lib/search"
import { selection, useSelection } from "@/lib/selection"
import { cn } from "@/lib/utils"
import { LibraryLink } from "./library-link"

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
  if (!sel.active) {
    return (
      <LibraryLink search={{ ...search, book: id }} className={className}>
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
      className={cn("relative w-full text-left", className, on && cn("ring-2 ring-primary ring-offset-background eink:ring-4", selectedClassName))}
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
