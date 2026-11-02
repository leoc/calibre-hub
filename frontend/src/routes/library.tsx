import { getRouteApi, useNavigate } from "@tanstack/react-router"
import { useQuery, useQueryClient } from "@tanstack/react-query"
import { ArrowLeft } from "lucide-react"
import { DEFAULT_CONFIG, type BookPatch } from "@/lib/api"
import { booksQuery, configQuery } from "@/lib/queries"
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
import { BulkBar } from "@/components/bulk-bar"
import { useSelection } from "@/lib/selection"
import { LibraryLink } from "@/components/library-link"

const route = getRouteApi("/_app/")

export function LibraryPage() {
  const search = route.useSearch()
  const navigate = useNavigate()
  const desktop = useDesktop()
  const view = useView()
  const sel = useSelection()
  const qc = useQueryClient()
  const { data: config = DEFAULT_CONFIG } = useQuery(configQuery)
  const query = toBookQuery(search, config.categoryColumn)
  const { data, error, isFetching, isPlaceholderData, refetch } = useQuery(booksQuery(query))
  const page = search.page ?? 1
  const pages = data ? Math.max(1, Math.ceil(data.total / PAGE_SIZE)) : 1
  const closeBook = () => navigate({ to: "/", search: { ...search, book: undefined, edit: undefined } })
  const setEdit = (on: boolean) => navigate({ to: "/", search: { ...search, edit: on || undefined }, replace: !on })
  const placeholder = data?.books.find((b) => b.id === search.book)

  // "Ohne Kategorie": once a book has one, go on with the next unsorted book
  // in the list (it drops out of the refetched list), or close at the end.
  const onSaved = search.unsorted
    ? async (patch: BookPatch) => {
        const id = search.book
        if (!patch.kategorie) return setEdit(false)
        const at = Math.max(0, data?.books.findIndex((b) => b.id === id) ?? 0)
        const fresh = await qc.fetchQuery({ ...booksQuery(query), staleTime: 0 }).catch(() => null)
        const rest = fresh?.books.filter((b) => b.id !== id) ?? []
        const next = rest[Math.min(at, rest.length - 1)]
        navigate({ to: "/", search: { ...search, book: next?.id, edit: next ? true : undefined }, replace: true })
      }
    : undefined

  // small screens: the detail replaces the list, back returns to it
  if (search.book != null && !desktop) {
    return (
      <div className="mx-auto max-w-3xl p-4">
        <Button variant="ghost" className="mb-4 -ml-2" onClick={() => (history.length > 1 ? history.back() : closeBook())}>
          <ArrowLeft /> {t("book.back")}
        </Button>
        <BookDetail id={search.book} placeholder={placeholder} edit={search.edit} onEdit={setEdit} onSaved={onSaved} />
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
      {sel.active && data && <BulkBar search={search} pageIds={data.books.map((b) => b.id)} total={data.total} />}
      {desktop && (
        <Sheet open={search.book != null} onOpenChange={(o) => !o && closeBook()}>
          <SheetContent side="right" className="overflow-y-auto p-6 sm:max-w-2xl" aria-describedby={undefined}>
            <SheetTitle className="sr-only">{placeholder?.title ?? t("app.title")}</SheetTitle>
            {search.book != null && <BookDetail id={search.book} placeholder={placeholder} edit={search.edit} onEdit={setEdit} onSaved={onSaved} />}
          </SheetContent>
        </Sheet>
      )}
    </div>
  )
}
