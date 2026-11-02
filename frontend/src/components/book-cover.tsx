import { useState } from "react"
import { BookIcon } from "lucide-react"
import { coverUrl, type Book } from "@/lib/api"
import { cn } from "@/lib/utils"
import { ReadBar } from "./reading"

// Fixed 3:4 box so the grid does not jump while covers load.
// progress: a thin bar with how far the book has been read
export function BookCover({ book, thumb = true, compact = false, progress = false, className }: { book: Book; thumb?: boolean; compact?: boolean; progress?: boolean; className?: string }) {
  const [failed, setFailed] = useState(false)
  return (
    <div className={cn("relative aspect-[3/4] overflow-hidden rounded-md bg-muted eink:border-2 eink:border-black", className)}>
      {failed ? (
        <div className="flex h-full flex-col items-center justify-center gap-2 p-2 text-center text-muted-foreground eink:text-black">
          <BookIcon className={compact ? "size-4" : "size-8"} aria-hidden />
          {!compact && <span className="line-clamp-3 text-xs">{book.title}</span>}
        </div>
      ) : (
        <img
          src={coverUrl(book.id, thumb, book.lastModified)}
          alt=""
          loading="lazy"
          decoding="async"
          width={300}
          height={400}
          onError={() => setFailed(true)}
          className="h-full w-full object-cover"
        />
      )}
      {progress && <ReadBar bookId={book.id} />}
    </div>
  )
}
