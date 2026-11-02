import { useQuery } from "@tanstack/react-query"
import { categoryOf, DEFAULT_CONFIG, type Book } from "@/lib/api"
import { configQuery } from "@/lib/queries"
import { categoryLabel } from "@/lib/kategorie"
import { defaultOrder, effectiveSort, type LibrarySearch } from "@/lib/search"
import type { Sort } from "@/lib/api"
import { cn } from "@/lib/utils"
import { LibraryLink } from "./library-link"
import { formatDate, t } from "@/i18n"
import { BookCover } from "./book-cover"
import { ArrowDown, ArrowUp } from "lucide-react"
import { FastTagSpacer, FastTagToggles } from "./fast-tags"
import { BookItem } from "./book-item"
import { formatIndex } from "./book-grid"

const COLUMNS = "grid-cols-[2.5rem_1fr] gap-3 px-1 md:grid-cols-[2.5rem_2fr_1fr_1fr_7rem]"

// Compact rows; columns beyond title/author, and their headers, only on wider screens.
export function BookList({ books, search }: { books: Book[]; search: LibrarySearch }) {
  const { data: config = DEFAULT_CONFIG } = useQuery(configQuery)
  const order = books.map((b) => b.id)
  return (
    <div>
      <div className="hidden items-center border-b md:flex eink:border-b-2 eink:border-black">
        <div className={cn("grid min-w-0 flex-1 items-center py-1 text-xs font-medium text-muted-foreground eink:text-sm eink:text-black", COLUMNS)}>
          <span />
          <span className="flex items-center gap-1">
            <SortHeader search={search} sort="title" label={t("sort.title")} />
            <span aria-hidden>·</span>
            <SortHeader search={search} sort="author" label={t("sort.author")} />
          </span>
          <span>
            <SortHeader search={search} sort="series" label={t("sort.series")} />
          </span>
          <span>{t("book.kategorie")}</span>
          <span className="flex justify-end">
            <SortHeader search={search} sort="added" label={t("sort.added")} />
          </span>
        </div>
        <FastTagSpacer className="shrink-0 px-2" />
      </div>
      <ul className="divide-y eink:divide-y-2 eink:divide-black">
      {books.map((b) => (
        <li key={b.id} className="group flex items-center">
          <BookItem
            id={b.id}
            order={order}
            search={search}
            className={cn("grid min-w-0 flex-1 items-center py-2 hover:bg-accent eink:min-h-16", COLUMNS)}
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
    </div>
  )
}

// A column header that sorts by its column; again reverses the order.
function SortHeader({ search, sort, label }: { search: LibrarySearch; sort: Sort; label: string }) {
  const current = effectiveSort(search)
  const active = current.sort === sort
  const order = active ? (current.order === "asc" ? "desc" : "asc") : defaultOrder(sort)
  const Arrow = current.order === "asc" ? ArrowUp : ArrowDown
  return (
    <LibraryLink
      search={{ ...search, sort, order, page: undefined }}
      aria-label={t("sort.by", { name: label })}
      aria-current={active ? "true" : undefined}
      className={cn(
        "-mx-1 inline-flex items-center gap-1 rounded-sm px-1 py-1 outline-none hover:text-foreground focus-visible:ring-[3px] focus-visible:ring-ring/50 eink:min-h-11 eink:min-w-11 eink:justify-center",
        active && "text-foreground eink:underline",
      )}
    >
      {label}
      {active && <Arrow className="size-3.5" aria-hidden />}
    </LibraryLink>
  )
}
