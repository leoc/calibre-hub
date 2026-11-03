import { useQuery } from "@tanstack/react-query"
import { ArrowLeft } from "lucide-react"
import { importStatusQuery } from "@/lib/queries"
import { t } from "@/i18n"
import { buttonVariants } from "@/components/ui/button"
import { ErrorMessage } from "@/components/error-view"
import { LibraryLink } from "@/components/library-link"
import { ImportOverview } from "@/components/backlog-import"
import { ImportQuality } from "@/components/import-quality"
import { ImportRepair } from "@/components/import-repair"

// The backlog import live: phase, the whole backlog, the running run with
// rates and ETA, the hooks' followup and the runs (polled while active)
export function ImportPage() {
  const { data, error, refetch } = useQuery(importStatusQuery)
  return (
    <div className="mx-auto max-w-4xl space-y-5 p-4 lg:p-6">
      <LibraryLink search={{}} className={buttonVariants({ variant: "ghost", className: "-ml-2" })}>
        <ArrowLeft /> {t("book.back")}
      </LibraryLink>
      <div className="space-y-1">
        <h1 className="text-2xl font-semibold">{t("import.page")}</h1>
        <p className="text-sm text-muted-foreground eink:text-black">{t("import.pageHint")}</p>
      </div>
      {error && !data ? (
        <ErrorMessage error={error} onRetry={() => refetch()} />
      ) : !data ? (
        <p className="py-12 text-center text-muted-foreground">{t("loading")}</p>
      ) : !data.enabled && data.cleanups.length === 0 ? (
        <p className="py-12 text-center text-lg">{t("import.off")}</p>
      ) : (
        <>
          <ImportOverview status={data} />
          {data.enabled && <ImportQuality />}
          {data.enabled && <ImportRepair />}
        </>
      )}
    </div>
  )
}
