import { useState } from "react"
import { useQuery } from "@tanstack/react-query"
import { useNavigate } from "@tanstack/react-router"
import { ArrowLeft, Bookmark, ChevronRight, Folder, ListFilter, Pencil, Plus, RefreshCw, Star, Trash2 } from "lucide-react"
import { emptyCondition, shelfDialog } from "@/lib/shelves"
import { RuleLine } from "@/components/shelf"
import { ApiError } from "@/lib/api"
import { flattenListTree, listLabel, nodeSearch, useListTree, useUpdateList, type ListNode } from "@/lib/lists"
import { sessionQuery } from "@/lib/queries"
import { mayConfigureList, maySync } from "@/lib/session"
import { withFilter } from "@/lib/search"
import { formatNumber, t } from "@/i18n"
import { cn } from "@/lib/utils"
import { Badge } from "@/components/ui/badge"
import { Button, buttonVariants } from "@/components/ui/button"
import { ErrorMessage } from "@/components/error-view"
import { LibraryLink } from "@/components/library-link"
import { ListEditDialog, Mosaic, NewListInline } from "@/components/lists"

// All reading lists (the sidebar shows the favorites) as a tree: covers,
// name, description, count, flags, and what can be done with each; a node
// with sublists folds them away.
export function ListsPage() {
  const { lists, tree, user, error, refetch } = useListTree()
  const navigate = useNavigate()
  // keys of the folded nodes
  const [folded, setFolded] = useState<Set<string>>(new Set())
  const toggle = (key: string) => setFolded((f) => new Set(f.has(key) ? [...f].filter((k) => k !== key) : [...f, key]))
  const visible = (nodes: ListNode[]): ListNode[] => nodes.flatMap((n) => [n, ...(folded.has(n.key) ? [] : visible(n.children))])
  // without sublists anywhere no room for chevrons
  const nested = !!tree?.some((n) => n.children.length)
  return (
    <div className="mx-auto max-w-3xl space-y-5 p-4 lg:p-6">
      <LibraryLink search={{}} className={buttonVariants({ variant: "ghost", className: "-ml-2" })}>
        <ArrowLeft /> {t("book.back")}
      </LibraryLink>
      <div className="space-y-1">
        <h1 className="text-2xl font-semibold">{t("nav.lists")}</h1>
        <p className="text-sm text-muted-foreground eink:text-black">{t("list.overviewHint")}</p>
      </div>
      <div className="flex flex-wrap items-start gap-2">
        <NewListInline className="-ml-2" onCreated={(l) => navigate({ to: "/", search: withFilter({}, { list: l.id }) })} />
        <Button type="button" variant="ghost" onClick={() => shelfDialog.open({ rule: { match: "all", conditions: [emptyCondition()] } })}>
          <ListFilter /> {t("shelf.new")}
        </Button>
      </div>
      {error && !lists ? (
        <ErrorMessage error={error} onRetry={() => refetch()} />
      ) : !lists || !tree ? (
        <p className="py-12 text-center text-muted-foreground">{t("loading")}</p>
      ) : lists.length === 0 ? (
        <p className="py-12 text-center text-lg">{t("list.none")}</p>
      ) : (
        <ul className="divide-y border-y eink:divide-y-2 eink:border-y-2" aria-label={t("nav.lists")}>
          {visible(tree).map((n) => (
            <ListRow key={n.key} node={n} user={user} nested={nested} folded={folded.has(n.key)} onFold={() => toggle(n.key)} />
          ))}
        </ul>
      )}
    </div>
  )
}

// The chevron that folds a node's sublists, or its room
function Fold({ node, folded, onFold }: { node: ListNode; folded: boolean; onFold: () => void }) {
  if (!node.children.length) return <span className="w-7 shrink-0 eink:w-11 touch:w-11" />
  return (
    <button
      type="button"
      onClick={onFold}
      aria-expanded={!folded}
      aria-label={t(folded ? "list.expand" : "list.collapse", { name: listLabel(node.path) })}
      className="flex size-7 shrink-0 items-center justify-center self-start rounded-sm hover:bg-accent eink:size-11 touch:size-11"
    >
      <ChevronRight className={cn("size-4 transition-transform", !folded && "rotate-90")} aria-hidden />
    </button>
  )
}

const indent = (n: ListNode) => ({ paddingLeft: n.depth * 16 })

function ListRow({ node, user, nested, folded, onFold }: { node: ListNode; user?: string; nested: boolean; folded: boolean; onFold: () => void }) {
  const update = useUpdateList()
  const { data: session } = useQuery(sessionQuery)
  const [dialog, setDialog] = useState<"edit" | "delete" | null>(null)
  const [adding, setAdding] = useState(false)
  const navigate = useNavigate()
  const list = node.list
  const open = withFilter({}, nodeSearch(node, user))
  const headingId = `list-${node.key.replace(/[^\w-]/g, "_")}`
  const subCount = flattenListTree(node.children).filter((c) => c.list).length
  const newSub = (
    <>
      {(!list || list.editable) && node.owner === session?.user && (
        <Button variant="outline" size="sm" aria-expanded={adding} aria-label={t("list.newSubIn", { name: listLabel(node.path) })} onClick={() => setAdding(!adding)}>
          <Plus /> {t("list.newSub")}
        </Button>
      )}
    </>
  )
  const subForm = adding && (
    <NewListInline initialOpen parent={node.path} onCreated={(l) => navigate({ to: "/", search: withFilter({}, { list: l.id }) })} className="pt-1" />
  )
  if (!list) {
    return (
      <li className="flex gap-3 py-4 sm:gap-4" style={indent(node)} aria-labelledby={headingId}>
        {nested && <Fold node={node} folded={folded} onFold={onFold} />}
        <div className="flex aspect-[3/4] w-16 shrink-0 items-center justify-center rounded-md bg-muted sm:w-20 eink:border-2 eink:border-black">
          <Folder className="size-6 text-muted-foreground eink:text-black" aria-hidden />
        </div>
        <div className="min-w-0 flex-1 space-y-1.5">
          <h2 id={headingId} className="text-lg leading-tight font-semibold">
            <LibraryLink search={open} className="underline-offset-2 hover:underline eink:inline-flex eink:min-h-11 eink:items-center touch:inline-flex touch:min-h-11 touch:items-center">
              {node.name}
            </LibraryLink>
          </h2>
          <p className="flex flex-wrap items-center gap-2 text-sm">
            <span>{t("list.folder")}</span>
            <span aria-hidden>·</span>
            <span>{subCount === 1 ? t("list.oneSubList") : t("list.subLists", { count: formatNumber(subCount) })}</span>
          </p>
          <div className="flex flex-wrap gap-2 pt-1">
            <LibraryLink search={open} className={buttonVariants({ variant: "outline", size: "sm" })}>
              {t("list.open")}
            </LibraryLink>
            {newSub}
          </div>
          {subForm}
        </div>
      </li>
    )
  }
  // only the owner deletes a list
  const owner = session?.user === list.owner
  const toggle = (patch: Parameters<typeof update.mutate>[0]["patch"]) => update.mutate({ id: list.id, patch })
  const total = list.totalCount ?? list.count
  return (
    <li className="flex gap-3 py-4 sm:gap-4" style={indent(node)} aria-labelledby={headingId}>
      {nested && <Fold node={node} folded={folded} onFold={onFold} />}
      <Mosaic list={list} className="w-16 sm:w-20" />
      <div className="min-w-0 flex-1 space-y-1.5">
        <h2 id={headingId} className="text-lg leading-tight font-semibold">
          <LibraryLink search={open} className="underline-offset-2 hover:underline eink:inline-flex eink:min-h-11 eink:items-center touch:inline-flex touch:min-h-11 touch:items-center">
            {node.name}
          </LibraryLink>
        </h2>
        {list.description && <p className="line-clamp-2 text-sm whitespace-pre-line text-muted-foreground eink:text-base eink:text-black">{list.description}</p>}
        {list.rule && <RuleLine rule={list.rule} error={list.queryError} />}
        <p className="flex flex-wrap items-center gap-2 text-sm">
          <span className="tabular-nums">{list.count === 1 ? t("list.oneBook") : t("list.books", { count: formatNumber(list.count) })}</span>
          {subCount > 0 && <span className="tabular-nums text-muted-foreground eink:text-black">{t("list.withSub", { count: formatNumber(total) })}</span>}
          {list.rule && <Badge variant="secondary">{t("shelf.label")}</Badge>}
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
          {mayConfigureList(session, list) && (
            <>
              <Button variant="outline" size="sm" onClick={() => setDialog("edit")}>
                <Pencil /> {t("list.editShort")}
              </Button>
              <Button variant="outline" size="sm" aria-pressed={list.favorite} disabled={update.isPending} onClick={() => toggle({ favorite: !list.favorite })}>
                <Star className={cn(list.favorite && "fill-current")} /> {t("list.favoriteShort")}
              </Button>
              {/* a shelf finds its books itself: no reader sync, never the default list */}
              {!list.rule && (
                <>
                  {/* the admin's e-reader, or a reader folder of the user's own */}
                  {maySync(session) && (
                    <Button variant="outline" size="sm" aria-pressed={list.sync} disabled={update.isPending} onClick={() => toggle({ sync: !list.sync })}>
                      <RefreshCw /> {t("list.syncAction")}
                    </Button>
                  )}
                  <Button variant="outline" size="sm" aria-pressed={list.isDefault} disabled={update.isPending} onClick={() => toggle({ isDefault: !list.isDefault })}>
                    <Bookmark className={cn(list.isDefault && "fill-current")} /> {t("list.defaultShort")}
                  </Button>
                </>
              )}
            </>
          )}
          {newSub}
          {owner && (
            <Button variant="outline" size="sm" className="text-destructive hover:text-destructive eink:text-black" onClick={() => setDialog("delete")}>
              <Trash2 /> {t("bulk.delete")}
            </Button>
          )}
        </div>
        {subForm}
        {update.error && (
          <p role="alert" className="text-sm text-destructive">
            {update.error instanceof ApiError ? update.error.message : String(update.error)}
          </p>
        )}
      </div>
      {dialog && <ListEditDialog list={list} hasSublists={subCount > 0} startWithDelete={dialog === "delete"} onClose={() => setDialog(null)} onDeleted={() => undefined} />}

    </li>
  )
}
