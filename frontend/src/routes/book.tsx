import { getRouteApi, useNavigate } from "@tanstack/react-router"
import { ArrowLeft } from "lucide-react"
import { t } from "@/i18n"
import { BookDetail } from "@/components/book-detail"
import { buttonVariants } from "@/components/ui/button"
import { LibraryLink } from "@/components/library-link"

const route = getRouteApi("/_app/books/$id")

// Permanent link to a book; inside the library the detail opens via ?book=.
export function BookPage() {
  const { id } = route.useParams()
  const { edit } = route.useSearch()
  const navigate = useNavigate()
  const setEdit = (on: boolean) => navigate({ to: "/books/$id", params: { id }, search: { edit: on || undefined }, replace: !on })
  return (
    <div className="mx-auto max-w-3xl p-4 lg:p-6">
      <LibraryLink search={{}} className={buttonVariants({ variant: "ghost", className: "mb-4 -ml-2" })}>
        <ArrowLeft /> {t("book.back")}
      </LibraryLink>
      <BookDetail id={id} edit={edit} onEdit={setEdit} />
    </div>
  )
}
