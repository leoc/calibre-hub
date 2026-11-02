import { useQuery } from "@tanstack/react-query"
import { Check, Sparkles, X } from "lucide-react"
import { ApiError, DEFAULT_CONFIG, type Book } from "@/lib/api"
import { configQuery, suggestionQuery } from "@/lib/queries"
import { useAcceptSuggestion, useRejectSuggestion } from "@/lib/mutations"
import { categoryLabel, percent } from "@/lib/kategorie"
import { t } from "@/i18n"
import { Button } from "./ui/button"

// An open category suggestion for the book, with accept and reject.
export function SuggestionBox({ book }: { book: Book }) {
  const { data: config = DEFAULT_CONFIG } = useQuery(configQuery)
  const { data: s } = useQuery({ ...suggestionQuery(book.id), enabled: !!config.classify })
  const accept = useAcceptSuggestion()
  const reject = useRejectSuggestion()
  if (!config.classify || !s || s.status !== "pending" || !s.category) return null
  const busy = accept.isPending || reject.isPending
  const failed = accept.error ?? reject.error
  return (
    <section aria-label={t("suggest.forBook")} className="space-y-2 rounded-md border p-3 text-sm eink:border-2">
      <p className="flex flex-wrap items-center gap-x-2">
        <Sparkles className="size-4" aria-hidden />
        <span className="font-medium">{t("suggest.forBook")}:</span>
        <span>{categoryLabel(s.category)}</span>
        <span className="text-muted-foreground tabular-nums eink:text-black">· {percent(s.confidence)}</span>
      </p>
      {s.reason && <p className="text-muted-foreground italic eink:text-black">{s.reason}</p>}
      <div className="flex flex-wrap gap-2">
        <Button size="sm" disabled={busy} onClick={() => accept.mutate({ bookId: book.id })}>
          <Check /> {t("suggest.accept")}
        </Button>
        <Button size="sm" variant="outline" disabled={busy} onClick={() => reject.mutate(book.id)}>
          <X /> {t("suggest.reject")}
        </Button>
      </div>
      {failed && (
        <p role="alert" className="text-destructive">
          {t("suggest.error")}: {failed instanceof ApiError ? failed.message : String(failed)}
        </p>
      )}
    </section>
  )
}
