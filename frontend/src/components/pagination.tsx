import { ChevronLeft, ChevronRight } from "lucide-react"
import type { LibrarySearch } from "@/lib/search"
import { t } from "@/i18n"
import { cn } from "@/lib/utils"
import { buttonVariants } from "./ui/button"
import { LibraryLink } from "@/components/library-link"

const pageSearch = (s: LibrarySearch, page: number) => ({ ...s, page: page > 1 ? page : undefined, book: undefined })

// Pages instead of infinite scroll: one redraw per page on E-Ink.
export function Pagination({ search, page, pages }: { search: LibrarySearch; page: number; pages: number }) {
  if (pages <= 1) return null
  const near = [...new Set([1, page - 1, page, page + 1, pages])].filter((p) => p >= 1 && p <= pages).sort((a, b) => a - b)
  return (
    <nav aria-label={t("page.of", { page, pages })} className="flex flex-wrap items-center justify-center gap-1 py-6">
      <PageLink search={search} page={page - 1} disabled={page <= 1} label={t("page.prev")}>
        <ChevronLeft /> <span className="hidden sm:inline">{t("page.prev")}</span>
      </PageLink>
      {near.map((p, i) => (
        <span key={p} className="flex items-center">
          {i > 0 && p - near[i - 1] > 1 && <span className="px-1 text-muted-foreground">…</span>}
          <LibraryLink
            search={pageSearch(search, p)}
            aria-current={p === page ? "page" : undefined}
            className={cn(buttonVariants({ variant: p === page ? "default" : "ghost", size: "icon" }), "tabular-nums")}
          >
            {p}
          </LibraryLink>
        </span>
      ))}
      <PageLink search={search} page={page + 1} disabled={page >= pages} label={t("page.next")}>
        <span className="hidden sm:inline">{t("page.next")}</span> <ChevronRight />
      </PageLink>
    </nav>
  )
}

function PageLink({ search, page, disabled, label, children }: { search: LibrarySearch; page: number; disabled: boolean; label: string; children: React.ReactNode }) {
  const cls = cn(buttonVariants({ variant: "outline" }), disabled && "pointer-events-none opacity-40")
  return disabled ? (
    <span aria-disabled className={cls}>
      {children}
    </span>
  ) : (
    <LibraryLink search={pageSearch(search, page)} aria-label={label} className={cls}>
      {children}
    </LibraryLink>
  )
}
