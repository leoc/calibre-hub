import { ArrowDown, ArrowUp, LayoutGrid, List, X } from "lucide-react"
import { SORTS, type Sort } from "@/lib/api"
import { defaultOrder, effectiveSort, toggleTag, withFilter, type LibrarySearch } from "@/lib/search"
import { setView, useView } from "@/lib/prefs"
import { useGoLibrary } from "@/lib/use-library"
import { formatNumber, languageName, t } from "@/i18n"
import { cn } from "@/lib/utils"
import { Badge } from "./ui/badge"
import { Button } from "./ui/button"
import { LibraryLink } from "@/components/library-link"

export function LibraryToolbar({ search, total }: { search: LibrarySearch; total: number | undefined }) {
  const view = useView()
  const go = useGoLibrary()
  const { sort, order } = effectiveSort(search)

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <p className="mr-auto text-sm text-muted-foreground tabular-nums eink:text-base eink:text-black" aria-live="polite">
          {total == null ? " " : total === 1 ? t("results.one") : t("results.count", { count: formatNumber(total) })}
        </p>
        <label className="flex items-center gap-1.5 text-sm">
          <span className="sr-only">{t("sort.label")}</span>
          <select
            value={sort}
            onChange={(e) => {
              const s = e.target.value as Sort
              go({ ...search, sort: s, order: defaultOrder(s), page: undefined })
            }}
            className="h-9 rounded-md border bg-background px-2 text-sm eink:h-12 eink:border-2 eink:text-base"
          >
            {SORTS.map((s) => (
              <option key={s} value={s}>
                {t(`sort.${s}`)}
              </option>
            ))}
          </select>
        </label>
        <Button
          variant="outline"
          size="icon"
          aria-label={order === "asc" ? t("order.asc") : t("order.desc")}
          title={order === "asc" ? t("order.asc") : t("order.desc")}
          onClick={() => go({ ...search, sort, order: order === "asc" ? "desc" : "asc", page: undefined })}
        >
          {order === "asc" ? <ArrowUp /> : <ArrowDown />}
        </Button>
        <div role="radiogroup" className="flex rounded-md border eink:border-2">
          {(["grid", "list"] as const).map((v) => (
            <button
              key={v}
              role="radio"
              aria-checked={view === v}
              aria-label={t(`view.${v}`)}
              title={t(`view.${v}`)}
              onClick={() => setView(v)}
              className="flex size-9 items-center justify-center first:rounded-l-md last:rounded-r-md hover:bg-accent aria-checked:bg-primary aria-checked:text-primary-foreground eink:size-12"
            >
              {v === "grid" ? <LayoutGrid className="size-4" /> : <List className="size-4" />}
            </button>
          ))}
        </div>
      </div>
      <ActiveFilters search={search} />
    </div>
  )
}

function ActiveFilters({ search }: { search: LibrarySearch }) {
  const chips: { key: string; label: string; value: string; next: LibrarySearch }[] = []
  if (search.q) chips.push({ key: "q", label: t("filter.q"), value: search.q, next: withFilter(search, { q: undefined }) })
  if (search.kategorie) chips.push({ key: "k", label: t("filter.kategorie"), value: search.kategorie.replaceAll(".", " › "), next: withFilter(search, { kategorie: undefined }) })
  if (search.author) chips.push({ key: "a", label: t("filter.author"), value: search.author, next: withFilter(search, { author: undefined }) })
  if (search.series) chips.push({ key: "s", label: t("filter.series"), value: search.series, next: withFilter(search, { series: undefined }) })
  search.tag?.forEach((tag) => chips.push({ key: `t:${tag}`, label: t("filter.tag"), value: tag, next: toggleTag(search, tag) }))
  if (search.lang) chips.push({ key: "l", label: t("filter.lang"), value: languageName(search.lang), next: withFilter(search, { lang: undefined }) })
  if (!chips.length) return null
  return (
    <ul className="flex flex-wrap gap-2">
      {chips.map((c) => (
        <li key={c.key}>
          <LibraryLink search={c.next} aria-label={t("filter.remove", { name: `${c.label} ${c.value}` })}>
            <Badge variant="outline" className={cn("h-7 gap-1.5 pr-1 text-sm hover:bg-accent eink:h-11 eink:border-2")}>
              <span className="text-muted-foreground eink:text-black">{c.label}:</span> {c.value}
              <X className="size-3.5" aria-hidden />
            </Badge>
          </LibraryLink>
        </li>
      ))}
    </ul>
  )
}
