import { useState } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { importQualityQuery } from "@/lib/queries"
import { api, write, type ConfidenceBand, type ImportQuality as Report } from "@/lib/api"
import { formatNumber, t } from "@/i18n"
import type { MessageKey } from "@/i18n/de"
import { sourceLabel } from "@/lib/metadata"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { BANDS, bandLabel, levelLabel } from "@/components/import-repair"
import { cn } from "@/lib/utils"

const muted = "text-muted-foreground eink:text-black"
const n = (v: number) => formatNumber(v)

const REASON: Record<string, MessageKey> = {
  unknownAuthor: "quality.reason.unknownAuthor",
  notAPerson: "quality.reason.notAPerson",
  publisherAuthor: "quality.reason.publisherAuthor",
  titleSaysNothing: "quality.reason.titleSaysNothing",
  swappedPair: "quality.reason.swappedPair",
  pathTitle: "quality.reason.pathTitle",
  leftoverTitle: "quality.reason.leftoverTitle",
  fileNameTitle: "quality.reason.fileNameTitle",
  unsure: "quality.reason.unsure",
}

const reasonLabel = (r: string) => (r in REASON ? t(REASON[r]) : r)

const ISBN_SOURCE: Record<string, MessageKey> = {
  text: "quality.isbn.text",
  ocr: "quality.isbn.ocr",
  opf: "quality.isbn.opf",
  calibre: "quality.isbn.calibre",
}

function isbnSource(s: string) {
  if (s in ISBN_SOURCE) return t(ISBN_SOURCE[s])
  const key = sourceLabel(s)
  return key ? t(key) : s
}

const percent = (part: number, total: number) => (total > 0 ? Math.round((part * 100) / total) : 0)

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
      <Decisions report={data} />
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

// What the rule flow decided: bands, levels, where the ISBNs came from,
// conflicts, and the sample checks that measure a band
function Decisions({ report }: { report: Report }) {
  const sources = Object.entries(report.isbn.sources).sort(([, a], [, b]) => b - a)
  const shares = (count: number) => `${n(count)} (${n(percent(count, report.isbn.with))} %)`
  return (
    <div className="space-y-2 text-sm tabular-nums">
      <dl className="grid grid-cols-[auto_1fr] gap-x-3" aria-label={t("quality.bands")}>
        {BANDS.map((b) => (
          <div key={b} className="contents">
            <dt>{bandLabel(b)}</dt>
            <dd>{n(report.bands[b])}</dd>
          </div>
        ))}
        <div className="contents">
          <dt>{t("quality.band.none")}</dt>
          <dd>{n(report.bands.none)}</dd>
        </div>
      </dl>
      <dl className="grid grid-cols-[auto_1fr] gap-x-3" aria-label={t("quality.levels")}>
        {([1, 2, 3] as const).map((l) => (
          <div key={l} className="contents">
            <dt>{levelLabel(l)}</dt>
            <dd>{n(report.levels[String(l) as "1" | "2" | "3"])}</dd>
          </div>
        ))}
      </dl>
      <p>{t("quality.isbn", { with: n(report.isbn.with), without: n(report.isbn.without) })}</p>
      {sources.length > 0 && (
        <dl className="grid grid-cols-[auto_1fr] gap-x-3" aria-label={t("quality.isbn.source")}>
          {sources.map(([source, count]) => (
            <div key={source} className="contents">
              <dt>{isbnSource(source)}</dt>
              <dd>{shares(count)}</dd>
            </div>
          ))}
        </dl>
      )}
      <p>{t("quality.conflicts", { duplicates: n(report.conflicts.duplicateCount), noted: n(report.conflicts.notedCount) })}</p>
      <Samples report={report} />
    </div>
  )
}

// The hit rate of a band: a random sample to check by hand, its result kept
function Samples({ report }: { report: Report }) {
  const qc = useQueryClient()
  const [band, setBand] = useState<ConfidenceBand>("bulk")
  const [checked, setChecked] = useState("")
  const [correct, setCorrect] = useState("")
  const pick = useMutation({ mutationFn: () => api.importSample(band) })
  const save = useMutation({
    mutationFn: () => write.addImportSample({ band, checked: Number(checked), correct: Number(correct) }),
    onSuccess: () => {
      setChecked("")
      setCorrect("")
      qc.invalidateQueries({ queryKey: importQualityQuery.queryKey })
    },
  })
  const valid = Number(checked) > 0 && correct !== "" && Number(correct) >= 0 && Number(correct) <= Number(checked)
  return (
    <div className="space-y-2">
      <h3 className="font-medium">{t("quality.samples")}</h3>
      {report.samples.length > 0 && (
        <ul aria-label={t("quality.samples")}>
          {report.samples.map((s) => (
            <li key={s.band}>
              {t("quality.sample", { band: bandLabel(s.band), correct: n(s.correct), checked: n(s.checked), rate: n(percent(s.correct, s.checked)) })}
            </li>
          ))}
        </ul>
      )}
      <div className="flex flex-wrap items-end gap-2">
        <label className="inline-flex flex-col gap-1">
          {t("quality.sample.band")}
          <select
            className="min-h-9 rounded-md border bg-background px-2 eink:min-h-12 eink:border-2 touch:min-h-11"
            value={band}
            onChange={(e) => setBand(e.target.value as ConfidenceBand)}
          >
            {BANDS.map((b) => (
              <option key={b} value={b}>
                {bandLabel(b)}
              </option>
            ))}
          </select>
        </label>
        <Button variant="outline" disabled={pick.isPending} onClick={() => pick.mutate()}>
          {t("quality.sample.pick")}
        </Button>
        <label className="inline-flex w-24 flex-col gap-1">
          {t("quality.sample.checked")}
          <Input type="number" min={1} value={checked} onChange={(e) => setChecked(e.target.value)} />
        </label>
        <label className="inline-flex w-24 flex-col gap-1">
          {t("quality.sample.correct")}
          <Input type="number" min={0} value={correct} onChange={(e) => setCorrect(e.target.value)} />
        </label>
        <Button disabled={!valid || save.isPending} onClick={() => save.mutate()}>
          {t("quality.sample.save")}
        </Button>
      </div>
      {pick.data && (
        <details open>
          <summary className="cursor-pointer eink:min-h-11 touch:min-h-11">{t("quality.sample.picked", { count: n(pick.data.books.length) })}</summary>
          <ul className="mt-1 space-y-0.5">
            {pick.data.books.map((b) => (
              <li key={b.id} className="break-words">
                {b.title} · {b.authors.join(", ")} <span className={muted}>({b.confidence})</span>
              </li>
            ))}
          </ul>
        </details>
      )}
    </div>
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
