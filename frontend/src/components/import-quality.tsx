import { useQuery } from "@tanstack/react-query"
import { importQualityQuery } from "@/lib/queries"
import type { ImportQuality as Report } from "@/lib/api"
import { formatNumber, t } from "@/i18n"
import type { MessageKey } from "@/i18n/de"
import { cn } from "@/lib/utils"

const muted = "text-muted-foreground eink:text-black"
const n = (v: number) => formatNumber(v)

const REASON: Record<string, MessageKey> = {
  unknownAuthor: "quality.reason.unknownAuthor",
  notAPerson: "quality.reason.notAPerson",
  publisherAuthor: "quality.reason.publisherAuthor",
  titleSaysNothing: "quality.reason.titleSaysNothing",
  leftoverTitle: "quality.reason.leftoverTitle",
  fileNameTitle: "quality.reason.fileNameTitle",
  unsure: "quality.reason.unsure",
}

const reasonLabel = (r: string) => (r in REASON ? t(REASON[r]) : r)

// How many books look wrong and why (GET /api/import/quality): the library
// and the last import runs, so every portion can be measured
export function ImportQuality() {
  const { data } = useQuery(importQualityQuery)
  if (!data) return null
  return (
    <section className="space-y-2" aria-labelledby="import-quality">
      <h2 id="import-quality" className="text-lg font-semibold">
        {t("quality.title")}
      </h2>
      <p role="status" className="text-sm tabular-nums">
        {t("quality.summary", { suspect: n(data.suspect), total: n(data.total) })}
      </p>
      <Reasons report={data} />
      {data.runs.length > 0 && (
        <ul className={cn("text-sm tabular-nums", muted)} aria-label={t("quality.runs")}>
          {data.runs.map((r) => (
            <li key={r.run}>{t("quality.run", { run: r.run.slice(0, 8), suspect: n(r.suspect), total: n(r.total) })}</li>
          ))}
        </ul>
      )}
      {data.books.length > 0 && (
        <details className="text-sm">
          <summary className="cursor-pointer eink:min-h-11 touch:min-h-11">{t("quality.examples", { count: n(data.books.length) })}</summary>
          <ul className="mt-1 space-y-0.5">
            {data.books.map((b) => (
              <li key={b.id} className="break-words">
                {b.title} · {b.authors.join(", ")} <span className={muted}>({b.reasons.map(reasonLabel).join(", ")})</span>
              </li>
            ))}
          </ul>
        </details>
      )}
    </section>
  )
}

function Reasons({ report }: { report: Report }) {
  const rows = Object.entries(report.reasons).filter(([, count]) => count > 0)
  if (rows.length === 0) return null
  return (
    <dl className="grid grid-cols-[auto_1fr] gap-x-3 text-sm tabular-nums">
      {rows.map(([reason, count]) => (
        <div key={reason} className="contents">
          <dt>{reasonLabel(reason)}</dt>
          <dd>{n(count)}</dd>
        </div>
      ))}
    </dl>
  )
}
