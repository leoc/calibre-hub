import { getRouteApi, useNavigate } from "@tanstack/react-router"
import { useQuery } from "@tanstack/react-query"
import { ArrowLeft } from "lucide-react"
import { booksQuery } from "@/lib/queries"
import { hasFilters, PAGE_SIZE, toBookQuery } from "@/lib/search"
import { useView } from "@/lib/prefs"
import { useDesktop } from "@/lib/use-media"
import { t } from "@/i18n"
import { BookGrid } from "@/components/book-grid"
import { BookList } from "@/components/book-list"
import { BookDetail } from "@/components/book-detail"
import { LibraryToolbar } from "@/components/library-toolbar"
import { Pagination } from "@/components/pagination"
import { ErrorMessage } from "@/components/error-view"
import { Sheet, SheetContent, SheetTitle } from "@/components/ui/sheet"
import { Button } from "@/components/ui/button"
import { LibraryLink } from "@/components/library-link"

const route = getRouteApi("/_app/")

export function LibraryPage() {
  const search = route.useSearch()
  const navigate = useNavigate()
  const desktop = useDesktop()
  const view = useView()
  const query = toBookQuery(search)
  const { data, error, isFetching, isPlaceholderData, refetch } = useQuery(booksQuery(query))
  const page = search.page ?? 1
  const pages = data ? Math.max(1, Math.ceil(data.total / PAGE_SIZE)) : 1
  const closeBook = () => navigate({ to: "/", search: { ...search, book: undefined } })
  const placeholder = data?.books.find((b) => b.id === search.book)

  // small screens: the detail replaces the list, back returns to it
  if (search.book != null && !desktop) {
    return (
      <div className="mx-auto max-w-3xl p-4">
        <Button variant="ghost" className="mb-4 -ml-2" onClick={() => (history.length > 1 ? history.back() : closeBook())}>
          <ArrowLeft /> {t("book.back")}
        </Button>
        <BookDetail id={search.book} placeholder={placeholder} />
      </div>
    )
  }

  return (
    <div className="mx-auto max-w-[110rem] space-y-5 p-4 lg:p-6">
      <LibraryToolbar search={search} total={data?.total} />
      {error && !data ? (
        <ErrorMessage error={error} onRetry={() => refetch()} />
      ) : !data ? (
        <p className="py-12 text-center text-muted-foreground">{t("loading")}</p>
      ) : data.books.length === 0 ? (
        <div className="space-y-4 py-12 text-center">
          <p className="text-lg">{t("results.none")}</p>
          {hasFilters(search) && (
            <LibraryLink search={{}} className="underline">
              {t("results.reset")}
            </LibraryLink>
          )}
        </div>
      ) : (
        <div className={isFetching && isPlaceholderData ? "opacity-60 eink:opacity-100" : undefined} aria-busy={isFetching}>
          {view === "grid" ? (
            <BookGrid books={data.books} search={search} showIndex={!!search.series && query.sort === "series"} />
          ) : (
            <BookList books={data.books} search={search} />
          )}
          <Pagination search={search} page={page} pages={pages} />
        </div>
      )}
      {desktop && (
        <Sheet open={search.book != null} onOpenChange={(o) => !o && closeBook()}>
          <SheetContent side="right" className="overflow-y-auto p-6 sm:max-w-2xl" aria-describedby={undefined}>
            <SheetTitle className="sr-only">{placeholder?.title ?? t("app.title")}</SheetTitle>
            {search.book != null && <BookDetail id={search.book} placeholder={placeholder} />}
          </SheetContent>
        </Sheet>
      )}
    </div>
  )
}
