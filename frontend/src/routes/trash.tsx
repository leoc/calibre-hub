import { useState } from "react"
import { useQuery } from "@tanstack/react-query"
import { Link } from "@tanstack/react-router"
import { ArrowLeft, CheckCircle2, RotateCcw } from "lucide-react"
import { ApiError, type Book } from "@/lib/api"
import { trashQuery } from "@/lib/queries"
import { useRestoreBook } from "@/lib/mutations"
import { formatDate, t } from "@/i18n"
import { Button, buttonVariants } from "@/components/ui/button"
import { ErrorMessage } from "@/components/error-view"
import { LibraryLink } from "@/components/library-link"

// Books in calibre's trash, newest first, with "Wiederherstellen".
export function TrashPage() {
  const { data, error, refetch } = useQuery(trashQuery)
  const restore = useRestoreBook()
  const [restored, setRestored] = useState<{ book: Book; warning?: string } | null>(null)

  return (
    <div className="mx-auto max-w-3xl space-y-5 p-4 lg:p-6">
      <LibraryLink search={{}} className={buttonVariants({ variant: "ghost", className: "-ml-2" })}>
        <ArrowLeft /> {t("book.back")}
      </LibraryLink>
      <div className="space-y-1">
        <h1 className="text-2xl font-semibold">{t("trash.title")}</h1>
        <p className="text-sm text-muted-foreground eink:text-black">{t("trash.hint")}</p>
      </div>
      {restored && (
        <p role="status" className="flex items-start gap-2 rounded-md border p-3 text-sm eink:border-2 eink:text-base">
          <CheckCircle2 className="mt-0.5 size-4 shrink-0" aria-hidden />
          <span>
            {t("trash.restored", { title: restored.book.title })}{" "}
            <Link to="/books/$id" params={{ id: restored.book.id }} search={{}} className="underline underline-offset-2 eink:inline-flex eink:min-h-11 eink:items-center touch:inline-flex touch:min-h-11 touch:items-center">
              {t("trash.open")}
            </Link>
            {restored.warning && (
              <span className="block text-destructive">
                {t("trash.listsFailed")}: {restored.warning}
              </span>
            )}
          </span>
        </p>
      )}
      {restore.error && (
        <p role="alert" className="text-sm text-destructive">
          {t("trash.error")}: {restore.error instanceof ApiError ? restore.error.message : String(restore.error)}
        </p>
      )}
      {error && !data ? (
        <ErrorMessage error={error} onRetry={() => refetch()} />
      ) : !data ? (
        <p className="py-12 text-center text-muted-foreground">{t("loading")}</p>
      ) : data.length === 0 ? (
        <p className="py-12 text-center text-lg">{t("trash.empty")}</p>
      ) : (
        <ul className="divide-y border-y eink:divide-y-2 eink:border-y-2" aria-label={t("trash.title")}>
          {data.map((e) => (
            <li key={`${e.id}-${e.deletedAt}`} className="flex flex-wrap items-center gap-3 py-3">
              <div className="min-w-0 flex-1">
                <p className="font-medium">{e.title}</p>
                <p className="text-sm text-muted-foreground eink:text-black">
                  {[e.authors.join(", "), e.formats.join(", "), t("trash.deletedAt", { date: formatDate(e.deletedAt) ?? "" })].filter(Boolean).join(" · ")}
                </p>
              </div>
              <Button
                variant="outline"
                size="sm"
                aria-label={`${t("trash.restore")}: ${e.title}`}
                disabled={restore.isPending}
                onClick={() => restore.mutate(e.id, { onSuccess: (r) => setRestored(r) })}
              >
                <RotateCcw /> {t("trash.restore")}
              </Button>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
