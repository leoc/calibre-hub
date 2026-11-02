import { Link } from "@tanstack/react-router"
import { useQuery } from "@tanstack/react-query"
import { BookOpenText } from "lucide-react"
import type { Book } from "@/lib/api"
import { allProgressQuery } from "@/lib/queries"
import { percent, readerFormat } from "@/lib/reader"
import { cn } from "@/lib/utils"
import { t } from "@/i18n"
import { buttonVariants } from "./ui/button"

// newest position of the book over all devices, null when never opened
export function useReadFraction(bookId: number): number | null {
  const { data } = useQuery(allProgressQuery)
  return data?.get(bookId) ?? null
}

// "Lesen" / "Weiterlesen (63 %)" in the detail; only for formats the reader opens
export function ReadButton({ book, className }: { book: Book; className?: string }) {
  const fraction = useReadFraction(book.id)
  if (!readerFormat(book)) return null
  const started = fraction != null && fraction > 0
  return (
    <Link to="/read/$id" params={{ id: book.id }} className={buttonVariants({ className })}>
      <BookOpenText aria-hidden /> {started ? t("reader.continue", { percent: percent(fraction) }) : t("reader.read")}
    </Link>
  )
}

// Thin bar at the bottom of a cover once the book has been opened
export function ReadBar({ bookId, className }: { bookId: number; className?: string }) {
  const fraction = useReadFraction(bookId)
  if (fraction == null || fraction <= 0) return null
  const pct = percent(fraction)
  return (
    <div
      role="progressbar"
      aria-label={t("reader.read.percent", { percent: pct })}
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={pct}
      className={cn("pointer-events-none absolute inset-x-0 bottom-0 h-1 bg-black/25 eink:h-1.5 eink:border-t eink:border-black eink:bg-white", className)}
    >
      <div className="h-full bg-primary eink:bg-black" style={{ width: `${Math.max(pct, 2)}%` }} />
    </div>
  )
}
