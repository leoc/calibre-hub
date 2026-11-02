import { useQuery } from "@tanstack/react-query"
import { Bookmark } from "lucide-react"
import { DEFAULT_CONFIG, type Book } from "@/lib/api"
import { configQuery } from "@/lib/queries"
import { cn } from "@/lib/utils"

// Marker on a cover for each fast tag the book has (toggle comes in Phase 4).
export function FastTagMarks({ book, className }: { book: Book; className?: string }) {
  const { data: config = DEFAULT_CONFIG } = useQuery(configQuery)
  const tags = config.fastTags.filter((t) => book.tags.includes(t))
  if (!tags.length) return null
  return (
    <span className={cn("flex gap-1", className)}>
      {tags.map((t) => (
        <span key={t} title={t} className="rounded-sm bg-background/90 p-1 eink:border-2 eink:border-black eink:bg-white">
          <Bookmark className="size-3.5 fill-current" aria-label={t} />
        </span>
      ))}
    </span>
  )
}
