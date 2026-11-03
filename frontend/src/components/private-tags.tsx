import { useState } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { LockKeyhole, Pencil } from "lucide-react"
import { ApiError, write, type Book } from "@/lib/api"
import { categoriesQuery } from "@/lib/queries"
import { refreshPrivateTags } from "@/lib/run-action"
import { togglePrivateTag } from "@/lib/search"
import { t } from "@/i18n"
import { LibraryLink } from "./library-link"
import { Badge } from "./ui/badge"
import { Button } from "./ui/button"
import { ChipsInput } from "./ui/suggest"

const tap = "eink:inline-flex eink:min-h-11 eink:items-center touch:inline-flex touch:min-h-11 touch:items-center"

// The user's private tags of a book in the detail: links to filter by them,
// and editing them in place (they live in the hub, never in calibre, so a
// reader edits them too)
export function PrivateTags({ book, onNavigate }: { book: Book; onNavigate?: () => void }) {
  const qc = useQueryClient()
  const { data: cats } = useQuery(categoriesQuery)
  const tags = book.privateTags ?? []
  const [editing, setEditing] = useState<string[] | null>(null)
  const save = useMutation({
    mutationFn: (next: string[]) => write.setPrivateTags(book.id, next),
    onSuccess: async (r) => {
      qc.setQueryData<Book>(["book", book.id], (old) => old && { ...old, privateTags: r.privateTags })
      setEditing(null)
      await refreshPrivateTags(qc)
    },
  })

  if (editing) {
    return (
      <div className="space-y-2">
        <ChipsInput aria-label={t("book.privateTags")} value={editing} onChange={setEditing} suggestions={cats?.privateTags ?? []} />
        <p className="text-xs text-muted-foreground eink:text-black">{t("book.privateTagsHint")}</p>
        {save.error && (
          <p role="alert" className="text-sm text-destructive">
            {save.error instanceof ApiError ? save.error.message : String(save.error)}
          </p>
        )}
        <div className="flex gap-2">
          <Button size="sm" onClick={() => save.mutate(editing)} disabled={save.isPending}>
            {t("book.privateTagsSave")}
          </Button>
          <Button size="sm" variant="outline" onClick={() => setEditing(null)}>
            {t("edit.cancel")}
          </Button>
        </div>
      </div>
    )
  }
  return (
    <span className="flex flex-wrap items-center gap-1.5">
      {tags.map((tag) => (
        <LibraryLink key={tag} search={togglePrivateTag({}, tag)} onClick={onNavigate} className={tap}>
          <Badge variant="outline" className="gap-1">
            <LockKeyhole className="size-3" aria-hidden /> {tag}
          </Badge>
        </LibraryLink>
      ))}
      {!tags.length && <span className="text-muted-foreground eink:text-black">{t("book.privateTagsNone")}</span>}
      <Button type="button" variant="ghost" size="icon" className="size-7 eink:size-11 touch:size-11" onClick={() => setEditing(tags)} aria-label={t("book.privateTagsEdit")} title={t("book.privateTagsEdit")}>
        <Pencil className="size-3.5" />
      </Button>
    </span>
  )
}
