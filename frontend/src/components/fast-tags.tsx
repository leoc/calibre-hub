import { useQuery } from "@tanstack/react-query"
import { Bookmark, BookmarkCheck } from "lucide-react"
import { DEFAULT_CONFIG, type Book } from "@/lib/api"
import { configQuery } from "@/lib/queries"
import { useToggleTag } from "@/lib/mutations"
import { t } from "@/i18n"
import { cn } from "@/lib/utils"
import { Button } from "./ui/button"

function useFastTags() {
  const { data: config = DEFAULT_CONFIG } = useQuery(configQuery)
  return config.fastTags
}

// Small toggles on covers and list rows. Set tags always show; unset ones
// appear on hover, and always on touch screens and E-Ink.
export function FastTagToggles({ book, className }: { book: Book; className?: string }) {
  const tags = useFastTags()
  const toggle = useToggleTag()
  return (
    <span className={cn("flex gap-1", className)}>
      {tags.map((tag) => {
        const on = book.tags.includes(tag)
        return (
          <button
            key={tag}
            type="button"
            aria-pressed={on}
            aria-label={on ? t("fast.remove", { tag }) : t("fast.add", { tag })}
            title={on ? t("fast.remove", { tag }) : t("fast.add", { tag })}
            onClick={(e) => {
              e.preventDefault()
              e.stopPropagation()
              toggle.mutate({ book, tag, on: !on })
            }}
            className={cn(
              "rounded-sm bg-background/90 p-1 shadow-sm hover:bg-background eink:border-2 eink:border-black eink:bg-white eink:p-2",
              !on && "opacity-0 group-hover:opacity-100 focus-visible:opacity-100 [@media(hover:none)]:opacity-100 eink:opacity-100",
            )}
          >
            <Bookmark className={cn("size-3.5 eink:size-5", on && "fill-current")} aria-hidden />
          </button>
        )
      })}
    </span>
  )
}

// Big buttons in the detail view.
export function FastTagButtons({ book }: { book: Book }) {
  const tags = useFastTags()
  const toggle = useToggleTag()
  return tags.map((tag) => {
    const on = book.tags.includes(tag)
    return (
      <Button key={tag} type="button" variant={on ? "secondary" : "outline"} aria-pressed={on} onClick={() => toggle.mutate({ book, tag, on: !on })}>
        {on ? <BookmarkCheck /> : <Bookmark />}
        <span className="capitalize">{tag}</span>
      </Button>
    )
  })
}
