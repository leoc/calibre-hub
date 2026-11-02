import { getRouteApi } from "@tanstack/react-router"
import { ArrowLeft } from "lucide-react"
import { t } from "@/i18n"
import { BookDetail } from "@/components/book-detail"
import { buttonVariants } from "@/components/ui/button"
import { LibraryLink } from "@/components/library-link"

const route = getRouteApi("/_app/books/$id")

// Permanent link to a book; inside the library the detail opens via ?book=.
export function BookPage() {
  const { id } = route.useParams()
  return (
    <div className="mx-auto max-w-3xl p-4 lg:p-6">
      <LibraryLink search={{}} className={buttonVariants({ variant: "ghost", className: "mb-4 -ml-2" })}>
        <ArrowLeft /> {t("book.back")}
      </LibraryLink>
      <BookDetail id={id} />
    </div>
  )
}
