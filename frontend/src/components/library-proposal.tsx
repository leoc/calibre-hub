import type { ImportRepairEntry, MetadataField, RepairNote } from "@/lib/api"
import { fieldLabel, formatValue, sourceLabel } from "@/lib/metadata"
import { formatNumber, t } from "@/i18n"
import { cn } from "@/lib/utils"

const muted = "text-muted-foreground eink:text-black"

const levelLabel = (level: 1 | 2 | 3) => t(level === 1 ? "repair.level.1" : level === 2 ? "repair.level.2" : "repair.level.3")

// who decided an unclear file name: the name, the folder, the file, a
// metadata source, the model, or nobody (the unsure tag)
export function decidedLabel(by: string | null, unsureTag: string): string {
  if (!by || by === "name") return t("repair.decided.name")
  if (by === "folder") return t("repair.decided.folder")
  if (by === "calibre") return t("repair.decided.calibre")
  if (by === "unsure") return t("repair.decided.unsure", { tag: unsureTag })
  const key = sourceLabel(by)
  return key ? t(key) : by
}

const sourceName = (source: string) => {
  const key = sourceLabel(source)
  return key ? t(key) : source
}

const noteText = (note: RepairNote) =>
  note.kind === "duplicateIsbn"
    ? t("repair.note.duplicateIsbn", { isbn: note.isbn, books: note.books.map((id) => `#${id}`).join(", ") })
    : t("repair.note.isbnConflict", { isbn: note.isbn })

// who decided, how sure and old → new, for a book of the library in the drawer
export function LibraryProposalView({ entry: e, title, unsureTag }: { entry: Pick<ImportRepairEntry, "file" | "decided" | "confidence" | "level" | "notes" | "changes">; title: string; unsureTag: string }) {
  const name = e.file.split("/").pop() ?? e.file
  const changes = e.changes.filter((c) => c.field !== "candidate")
  const candidate = e.changes.find((c) => c.field === "candidate")?.new as { title?: string; authors: string[]; source: string } | undefined
  return (
    <div className="space-y-1">
      <p className="flex flex-wrap gap-x-3">
        <span className={muted}>{t("repair.decided", { by: decidedLabel(e.decided, unsureTag) })}</span>
        <span className={cn("tabular-nums", muted)}>
          {e.confidence !== null && e.level !== null ? t("repair.confidence", { value: formatNumber(e.confidence), level: levelLabel(e.level) }) : t("repair.confidence.none")}
        </span>
      </p>
      {e.notes.map((note) => (
        <p key={note.kind} className="font-medium">
          {noteText(note)}
        </p>
      ))}
      {name && <p className={cn("break-all", muted)}>{name}</p>}
      <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-0.5">
        {changes.map((c) => (
          <div key={c.field} className="contents">
            <dt className="font-medium">{fieldLabel(c.field)}</dt>
            <dd className="break-words">
              <span className="line-through decoration-1 eink:no-underline">{formatValue(c.field as MetadataField, c.old)}</span>
              {" → "}
              <span>{formatValue(c.field as MetadataField, c.new)}</span>
            </dd>
          </div>
        ))}
      </dl>
      {candidate && (
        <p className={muted}>
          {t("repair.candidate", { title: candidate.title ?? title, authors: candidate.authors.join(", "), source: sourceName(candidate.source) })}
        </p>
      )}
    </div>
  )
}
