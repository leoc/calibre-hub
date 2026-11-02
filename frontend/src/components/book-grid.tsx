import type { Book } from "@/lib/api"
import type { LibrarySearch } from "@/lib/search"
import { BookCover } from "./book-cover"
import { FastTagToggles } from "./fast-tags"
import { BookItem } from "./book-item"
import { t } from "@/i18n"

const seriesLabel = (b: Book) => (b.series ? `${b.series}${b.seriesIndex != null ? ` ${formatIndex(b.seriesIndex)}` : ""}` : null)
export const formatIndex = (n: number) => (Number.isInteger(n) ? String(n) : n.toLocaleString("de-DE"))

export function BookGrid({ books, search, showIndex }: { books: Book[]; search: LibrarySearch; showIndex: boolean }) {
  const order = books.map((b) => b.id)
  return (
    <ul className="grid grid-cols-[repeat(auto-fill,minmax(6.5rem,1fr))] gap-x-3 gap-y-5 sm:grid-cols-[repeat(auto-fill,minmax(8.5rem,1fr))] sm:gap-x-4 sm:gap-y-6 eink:grid-cols-[repeat(auto-fill,minmax(10rem,1fr))]">
      {books.map((b) => (
        <li key={b.id} className="group relative">
          <BookItem id={b.id} order={order} search={search} className="block rounded-md outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50">
            <div className="relative">
              <BookCover book={b} className="transition-shadow group-hover:shadow-md" />
              {showIndex && b.seriesIndex != null && (
                <span className="absolute top-1.5 left-1.5 rounded-sm bg-background/90 px-1.5 text-sm font-semibold tabular-nums eink:border-2 eink:border-black eink:bg-white">
                  {formatIndex(b.seriesIndex)}
                </span>
              )}
            </div>
            <p className="mt-2 line-clamp-2 text-sm leading-snug font-medium eink:text-base">{b.title}</p>
            <p className="truncate text-xs text-muted-foreground eink:text-sm eink:text-black">{b.authors.join(", ")}</p>
            {!showIndex && seriesLabel(b) && <p className="truncate text-xs text-muted-foreground italic eink:text-sm eink:text-black">{seriesLabel(b)}</p>}
          </BookItem>
          <FastTagToggles book={b} className="absolute top-1.5 right-1.5" />
        </li>
      ))}
    </ul>
  )
}

// Placeholder while the first page loads: the same grid, so nothing jumps.
// E-Ink gets plain text instead (no greys, one redraw).
export function LoadingBooks({ view }: { view: "grid" | "list" }) {
  return (
    <div role="status" aria-busy>
      <p className="hidden py-12 text-center eink:block">{t("loading")}</p>
      <span className="sr-only eink:hidden">{t("loading")}</span>
      {view === "grid" ? (
        <ul aria-hidden className="grid grid-cols-[repeat(auto-fill,minmax(6.5rem,1fr))] gap-x-3 gap-y-5 sm:grid-cols-[repeat(auto-fill,minmax(8.5rem,1fr))] sm:gap-x-4 sm:gap-y-6 eink:hidden">
          {Array.from({ length: 14 }, (_, i) => (
            <li key={i} className="animate-pulse space-y-2">
              <div className="aspect-[3/4] rounded-md bg-muted" />
              <div className="h-3.5 w-4/5 rounded-sm bg-muted" />
              <div className="h-3 w-1/2 rounded-sm bg-muted" />
            </li>
          ))}
        </ul>
      ) : (
        <ul aria-hidden className="divide-y eink:hidden">
          {Array.from({ length: 10 }, (_, i) => (
            <li key={i} className="flex animate-pulse items-center gap-3 px-1 py-2">
              <div className="aspect-[3/4] w-10 rounded-sm bg-muted" />
              <div className="flex-1 space-y-2">
                <div className="h-3.5 w-2/5 rounded-sm bg-muted" />
                <div className="h-3 w-1/4 rounded-sm bg-muted" />
              </div>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
