import { Check } from "lucide-react"
import type { IntakeKind, IntakeShares } from "@/lib/api"
import { inBar, inLegend, isPicked, partLabel, partTitle, shareParts, type IntakeBand, type IntakeSource, type SharePart } from "@/lib/intake"
import { formatNumber, t } from "@/i18n"
import { cn } from "@/lib/utils"

const muted = "text-muted-foreground eink:text-black"

// Where everything stands, the library against the Eingang. Its own bar: in one
// the library's share would press the rest together.
function OverallBar({ books, open }: { books: number; open: number }) {
  return (
    <div className="space-y-1.5">
      <div className={cn("flex justify-between gap-3 text-[13px] tabular-nums", muted)}>
        <span>{t("intake.overall.library", { count: formatNumber(books) })}</span>
        <span>{t("intake.overall.open", { count: formatNumber(open) })}</span>
      </div>
      <div
        role="img"
        aria-label={t("intake.overall", { library: formatNumber(books), open: formatNumber(open) })}
        className="flex h-2 gap-0.5 overflow-hidden rounded-full eink:h-4 eink:rounded-none"
      >
        <div className="share-part share-books" style={{ flex: `${books} 1 0` }} />
        {open > 0 && <div className="share-part share-open min-w-1 eink:min-w-3" style={{ flex: `${open} 1 0` }} />}
      </div>
    </div>
  )
}

// a part of the bar; what isn't analysed yet leads nowhere, it only moves
function BarPart({ part, picked, moving, analysed, onPick }: { part: SharePart; picked: boolean; moving: boolean; analysed: number; onPick: (p: SharePart) => void }) {
  const size = { flex: `${part.count} 1 8px` }
  const title = partTitle(part)
  const look = cn("share-part min-w-2 eink:h-12 eink:min-w-11", `share-${part.id}`)
  if (part.kind === null) {
    return <div role="progressbar" aria-label={title} aria-valuemin={0} aria-valuemax={100} aria-valuenow={analysed} title={title} className={cn(look, moving && "share-moving")} style={size} />
  }
  return (
    <button
      type="button"
      aria-label={title}
      aria-pressed={picked}
      title={title}
      className={cn(look, "cursor-pointer outline-ring hover:brightness-110 focus-visible:outline-2 focus-visible:-outline-offset-2 eink:hover:brightness-100", picked && "share-picked")}
      style={size}
      onClick={() => onPick(part)}
    />
  )
}

// A row of the legend: the number, and where a finger or a pen can't hit a small
// part, the target
function LegendRow({ part, picked, onPick }: { part: SharePart; picked: boolean; onPick: (p: SharePart) => void }) {
  return (
    <button
      type="button"
      aria-pressed={part.kind === null ? undefined : picked}
      className={cn(
        "flex min-h-9 cursor-pointer items-center gap-2 rounded-md px-1.5 py-0.5 text-left hover:bg-accent/60 eink:min-h-12 eink:hover:bg-transparent touch:min-h-11",
        part.count === 0 && muted,
        picked && "bg-accent font-semibold hover:bg-accent eink:bg-transparent eink:outline-4 eink:-outline-offset-4 eink:outline-black",
      )}
      onClick={() => onPick(part)}
    >
      <span aria-hidden className={cn("share-part size-3 shrink-0 rounded-[3px] eink:size-6 eink:rounded-none", `share-${part.id}`)} />
      <span className="min-w-0 flex-auto">{partLabel(part)}</span>
      {picked && <Check className="size-4 shrink-0" aria-hidden />}
      <span className="font-semibold tabular-nums">{formatNumber(part.count)}</span>
    </button>
  )
}

// The two bars and the legend. The numbers don't follow the filters, only the
// source, so nothing here jumps while filtering; a click on a part filters.
// E-Ink shows no colors: a pattern per part (index.css), the same in the legend.
export function ShareBars(props: {
  shares: IntakeShares
  open: number
  analysed: number
  moving: boolean
  kind: IntakeKind
  band: IntakeBand
  source: IntakeSource
  onPick: (p: SharePart) => void
}) {
  const { shares, open, analysed, moving, kind, band, source, onPick } = props
  const parts = shareParts(shares, source)
  const bar = inBar(parts)
  return (
    <div className="space-y-4 text-sm">
      {shares.books !== null && <OverallBar books={shares.books} open={open} />}
      <div className="space-y-2.5">
        {bar.length > 0 && (
          <div role="group" aria-label={t("intake.parts")} className="flex h-8 gap-0.5 overflow-hidden rounded-md eink:h-auto eink:flex-wrap eink:overflow-visible eink:rounded-none">
            {bar.map((p) => (
              <BarPart key={p.id} part={p} picked={isPicked(p, kind, band)} moving={moving} analysed={analysed} onPick={onPick} />
            ))}
          </div>
        )}
        <div className="grid grid-cols-[repeat(auto-fit,minmax(170px,1fr))] gap-x-4 gap-y-1">
          {inLegend(parts).map((p) => (
            <LegendRow key={p.id} part={p} picked={isPicked(p, kind, band)} onPick={onPick} />
          ))}
        </div>
      </div>
    </div>
  )
}
