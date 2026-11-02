import { useEffect, useState } from "react"
import { getRouteApi, useNavigate } from "@tanstack/react-router"
import { useQuery, useQueryClient } from "@tanstack/react-query"
import { ArrowLeft } from "lucide-react"
import { DEFAULT_CONFIG, type BookPatch } from "@/lib/api"
import { booksQuery, configQuery } from "@/lib/queries"
import { hasFilters, PAGE_SIZE, toBookQuery } from "@/lib/search"
import { useView } from "@/lib/prefs"
import { useDesktop } from "@/lib/use-media"
import { t } from "@/i18n"
import { BookGrid, LoadingBooks } from "@/components/book-grid"
import { BookList } from "@/components/book-list"
import { BookDetail } from "@/components/book-detail"
import { LibraryToolbar } from "@/components/library-toolbar"
import { Pagination } from "@/components/pagination"
import { ErrorMessage } from "@/components/error-view"
import { Sheet, SheetContent, SheetTitle } from "@/components/ui/sheet"
import { Button, buttonVariants } from "@/components/ui/button"
import { BulkBar } from "@/components/bulk-bar"
import { useSelection } from "@/lib/selection"
import { LibraryLink } from "@/components/library-link"
import { useListKeys } from "@/components/keyboard"
import { activateWhenLoaded, focusActive, keyboard, usePendingActivation } from "@/lib/keyboard"

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
  const deleted = () => navigate({ to: "/", search: { ...search, book: undefined, edit: undefined }, replace: true })
  const placeholder = data?.books.find((b) => b.id === search.book)

  // keyboard: moving, selecting, opening; after a search or a page change
  // the first new book becomes the active one
  useListKeys({ books: data?.books, search, page, pages })
  const pendingActivation = usePendingActivation()
  useEffect(() => {
    if (!pendingActivation || !data || isPlaceholderData || !pendingActivation.when(search)) return
    activateWhenLoaded(null)
    const first = data.books[0]
    if (!first) return
    keyboard.setActive(first.id)
    if (pendingActivation.focus) requestAnimationFrame(() => focusActive())
  }, [pendingActivation, data, isPlaceholderData, search])

  // "Ohne Kategorie": once a book has one, go on with the next unsorted book
  // in the list (it drops out of the refetched list), or close at the end.
  // Shift+Enter in the category field carries the category to the next book
  const [carry, setCarry] = useState<string | null>(null)
  const onSaved = search.unsorted
    ? async (patch: BookPatch, opts: { carry: boolean }) => {
        const id = search.book
        setCarry(opts.carry ? (patch.kategorie ?? null) : null)
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
        <BookDetail id={search.book} placeholder={placeholder} edit={search.edit} onEdit={setEdit} onSaved={onSaved} onDeleted={deleted} prefillKategorie={search.unsorted ? carry : null} />
      </div>
    )
  }

  return (
    <div className="mx-auto max-w-[110rem] space-y-5 p-4 lg:p-6">
      <LibraryToolbar search={search} total={data?.total} page={page} pages={pages} />
      {error && !data ? (
        <ErrorMessage error={error} onRetry={() => refetch()} />
      ) : !data ? (
        <LoadingBooks view={view} />
      ) : data.books.length === 0 ? (
        <div className="space-y-4 py-12 text-center">
          <p className="text-lg">{t("results.none")}</p>
          {hasFilters(search) && (
            <LibraryLink search={{}} className={buttonVariants({ variant: "outline" })}>
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
          {/* opening it pushed ?book=, so Back closes it already */}
          <SheetContent
            side="right"
            className="sm:max-w-2xl"
            closeOnBack={false}
            aria-describedby={undefined}
            // the list keys go on working in the detail (j: next book), not in the form
            data-keys={search.edit ? undefined : "pass"}
            // back to the active book, which may be another one by now
            onCloseAutoFocus={(e) => focusActive() && e.preventDefault()}
          >
            <SheetTitle className="sr-only">{placeholder?.title ?? t("app.title")}</SheetTitle>
            {/* no bottom padding: the edit form's sticky bar sits flush at the bottom */}
            <div className="min-h-0 flex-1 overflow-y-auto px-6">
              {search.book != null && <BookDetail id={search.book} placeholder={placeholder} edit={search.edit} onEdit={setEdit} onSaved={onSaved} onDeleted={deleted} prefillKategorie={search.unsorted ? carry : null} />}
            </div>
          </SheetContent>
        </Sheet>
      )}
    </div>
  )
}
