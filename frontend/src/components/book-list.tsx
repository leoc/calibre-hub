import { useQuery } from "@tanstack/react-query"
import { categoryOf, DEFAULT_CONFIG, type Book } from "@/lib/api"
import { configQuery } from "@/lib/queries"
import { categoryLabel } from "@/lib/kategorie"
import type { LibrarySearch } from "@/lib/search"
import { formatDate, t } from "@/i18n"
import { BookCover } from "./book-cover"
import { FastTagToggles } from "./fast-tags"
import { BookItem } from "./book-item"
import { formatIndex } from "./book-grid"

// Compact rows; columns beyond title/author only on wider screens.
export function BookList({ books, search }: { books: Book[]; search: LibrarySearch }) {
  const { data: config = DEFAULT_CONFIG } = useQuery(configQuery)
  const order = books.map((b) => b.id)
  return (
    <ul className="divide-y eink:divide-y-2 eink:divide-black">
      {books.map((b) => (
        <li key={b.id} className="group flex items-center">
          <BookItem
            id={b.id}
            order={order}
            search={search}
            className="grid min-w-0 flex-1 grid-cols-[2.5rem_1fr] items-center gap-3 px-1 py-2 hover:bg-accent md:grid-cols-[2.5rem_2fr_1fr_1fr_7rem] eink:min-h-16"
          >
            <BookCover book={b} compact className="w-10 rounded-sm" />
            <div className="min-w-0">
              <p className="truncate font-medium">{b.title}</p>
              <p className="truncate text-sm text-muted-foreground eink:text-black">{b.authors.join(", ")}</p>
            </div>
            <p className="hidden truncate text-sm md:block">
              {b.series && (
                <>
                  {b.series}
                  {b.seriesIndex != null && <span className="text-muted-foreground eink:text-black"> {formatIndex(b.seriesIndex)}</span>}
                </>
              )}
            </p>
            <p className="hidden truncate text-sm text-muted-foreground md:block eink:text-black">{categoryLabel(categoryOf(b, config.categoryColumn) ?? "")}</p>
            <p className="hidden text-right text-xs text-muted-foreground tabular-nums md:block eink:text-black" title={t("book.added")}>
              {b.added && formatDate(b.added)}
            </p>
          </BookItem>
          <FastTagToggles book={b} className="shrink-0 px-2" />
        </li>
      ))}
    </ul>
  )
}
