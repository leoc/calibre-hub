import { useState } from "react"
import { useQuery } from "@tanstack/react-query"
import { useNavigate } from "@tanstack/react-router"
import { ArrowLeft, Bookmark, Pencil, RefreshCw, Star, Trash2 } from "lucide-react"
import { ApiError, type ReadingList } from "@/lib/api"
import { listsQuery, useUpdateList } from "@/lib/lists"
import { sessionQuery } from "@/lib/queries"
import { withFilter } from "@/lib/search"
import { formatNumber, t } from "@/i18n"
import { cn } from "@/lib/utils"
import { Badge } from "@/components/ui/badge"
import { Button, buttonVariants } from "@/components/ui/button"
import { ErrorMessage } from "@/components/error-view"
import { LibraryLink } from "@/components/library-link"
import { ListEditDialog, Mosaic, NewListInline } from "@/components/lists"

// All reading lists (the sidebar shows the favorites): covers, name,
// description, count, flags, and what can be done with each.
export function ListsPage() {
  const { data: lists, error, refetch } = useQuery(listsQuery)
  const navigate = useNavigate()
  return (
    <div className="mx-auto max-w-3xl space-y-5 p-4 lg:p-6">
      <LibraryLink search={{}} className={buttonVariants({ variant: "ghost", className: "-ml-2" })}>
        <ArrowLeft /> {t("book.back")}
      </LibraryLink>
      <div className="space-y-1">
        <h1 className="text-2xl font-semibold">{t("nav.lists")}</h1>
        <p className="text-sm text-muted-foreground eink:text-black">{t("list.overviewHint")}</p>
      </div>
      <NewListInline className="-ml-2" onCreated={(l) => navigate({ to: "/", search: withFilter({}, { list: l.id }) })} />
      {error && !lists ? (
        <ErrorMessage error={error} onRetry={() => refetch()} />
      ) : !lists ? (
        <p className="py-12 text-center text-muted-foreground">{t("loading")}</p>
      ) : lists.length === 0 ? (
        <p className="py-12 text-center text-lg">{t("list.none")}</p>
      ) : (
        <ul className="divide-y border-y eink:divide-y-2 eink:border-y-2" aria-label={t("nav.lists")}>
          {lists.map((l) => (
            <ListRow key={l.id} list={l} />
          ))}
        </ul>
      )}
    </div>
  )
}

function ListRow({ list }: { list: ReadingList }) {
  const update = useUpdateList()
  const { data: session } = useQuery(sessionQuery)
  const [dialog, setDialog] = useState<"edit" | "delete" | null>(null)
  // only the owner deletes a list
  const owner = session?.user === list.owner
  const open = withFilter({}, { list: list.id })
  const toggle = (patch: Parameters<typeof update.mutate>[0]["patch"]) => update.mutate({ id: list.id, patch })
  const headingId = `list-${list.id}`
  return (
    <li className="flex gap-3 py-4 sm:gap-4" aria-labelledby={headingId}>
      <Mosaic list={list} className="w-16 sm:w-20" />
      <div className="min-w-0 flex-1 space-y-1.5">
        <h2 id={headingId} className="text-lg leading-tight font-semibold">
          <LibraryLink search={open} className="underline-offset-2 hover:underline eink:inline-flex eink:min-h-11 eink:items-center touch:inline-flex touch:min-h-11 touch:items-center">
            {list.name}
          </LibraryLink>
        </h2>
        {list.description && <p className="line-clamp-2 text-sm whitespace-pre-line text-muted-foreground eink:text-base eink:text-black">{list.description}</p>}
        <p className="flex flex-wrap items-center gap-2 text-sm">
          <span className="tabular-nums">{list.count === 1 ? t("list.oneBook") : t("list.books", { count: formatNumber(list.count) })}</span>
          {list.isDefault && <Badge variant="secondary">{t("list.defaultShort")}</Badge>}
          {list.favorite && <Badge variant="secondary">{t("list.favoriteShort")}</Badge>}
          {list.sync && <Badge variant="secondary">{t("list.syncShort")}</Badge>}
          {list.visibility !== "private" && <Badge variant="outline">{t(`list.visibility.${list.visibility}`)}</Badge>}
          {!list.editable && <Badge variant="outline">{t("list.readOnly")}</Badge>}
          {list.owner !== session?.user && <span className="text-muted-foreground eink:text-black">{t("list.owner", { owner: list.owner })}</span>}
        </p>
        <div className="flex flex-wrap gap-2 pt-1">
          <LibraryLink search={open} className={buttonVariants({ variant: "outline", size: "sm" })}>
            {t("list.open")}
          </LibraryLink>
          {list.editable && (
            <>
              <Button variant="outline" size="sm" onClick={() => setDialog("edit")}>
                <Pencil /> {t("list.editShort")}
              </Button>
              <Button variant="outline" size="sm" aria-pressed={list.favorite} disabled={update.isPending} onClick={() => toggle({ favorite: !list.favorite })}>
                <Star className={cn(list.favorite && "fill-current")} /> {t("list.favoriteShort")}
              </Button>
              <Button variant="outline" size="sm" aria-pressed={list.sync} disabled={update.isPending} onClick={() => toggle({ sync: !list.sync })}>
                <RefreshCw /> {t("list.syncAction")}
              </Button>
              <Button variant="outline" size="sm" aria-pressed={list.isDefault} disabled={update.isPending} onClick={() => toggle({ isDefault: !list.isDefault })}>
                <Bookmark className={cn(list.isDefault && "fill-current")} /> {t("list.defaultShort")}
              </Button>
            </>
          )}
          {owner && (
            <Button variant="outline" size="sm" className="text-destructive hover:text-destructive eink:text-black" onClick={() => setDialog("delete")}>
              <Trash2 /> {t("bulk.delete")}
            </Button>
          )}
        </div>
        {update.error && (
          <p role="alert" className="text-sm text-destructive">
            {update.error instanceof ApiError ? update.error.message : String(update.error)}
          </p>
        )}
      </div>
      {dialog && <ListEditDialog list={list} startWithDelete={dialog === "delete"} onClose={() => setDialog(null)} onDeleted={() => undefined} />}
    </li>
  )
}
