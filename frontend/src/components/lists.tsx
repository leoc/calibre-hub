import { useMemo, useState, type FormEvent } from "react"
import { useQuery } from "@tanstack/react-query"
import { useNavigate } from "@tanstack/react-router"
import { Bookmark, BookmarkCheck, BookmarkPlus, ChevronRight, Folder, ListPlus, ListTree, Pencil, Plus, RefreshCw, Star, Trash2 } from "lucide-react"
import { ApiError, coverUrl, VISIBILITIES, type Book, type ListPatch, type ReadingList, type ShelfRule, type Visibility } from "@/lib/api"
import { fromForm, ruleComplete, toForm } from "@/lib/shelves"
import { RuleEditor, RuleLine } from "./shelf"
import { bookQuery, sessionQuery } from "@/lib/queries"
import { isAdmin, mayConfigureList } from "@/lib/session"
import {
  buildListTree,
  defaultList,
  flattenListTree,
  inList,
  lastUsedList,
  listLabel,
  listLeaf,
  listsQuery,
  nodeSearch,
  nodeTrail,
  type ListNode,
  saveDialog,
  savableLists,
  useCreateList,
  useDeleteList,
  useListMembership,
  useLongPress,
  useSaveDialog,
  useUpdateList,
} from "@/lib/lists"
import { leaveOverlays } from "@/lib/back-to-close"
import { withFilter, type LibrarySearch } from "@/lib/search"
import { LibraryLink } from "./library-link"

import { formatNumber, t } from "@/i18n"
import { cn } from "@/lib/utils"
import { Badge } from "./ui/badge"
import { Button } from "./ui/button"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "./ui/dialog"
import { Input } from "./ui/input"

const toggleClass = (onCover?: boolean) =>
  cn(
    "relative rounded-sm bg-background/90 p-1 shadow-sm hover:bg-background eink:border-2 eink:border-black eink:bg-white eink:p-2 touch:after:absolute eink:after:hidden",
    // 26 px on a cover, 34 px in a list row; the hit area is 44 either way
    onCover ? "touch:p-1.5 touch:after:-inset-[9px]" : "touch:p-2.5 touch:after:-inset-[5px]",
  )

// The bookmark on covers and list rows: saves to the default list; a long
// press or right click opens "Speichern" with all lists. Set ones always
// show; unset ones appear on hover, and always on touch screens and E-Ink.
// On touch screens an invisible ::after makes the tap target 44 px without
// covering more of the cover (E-Ink shows the full 44 px).
export function QuickListToggle({ book, onCover, className }: { book: Book; onCover?: boolean; className?: string }) {
  const { data: lists } = useQuery(listsQuery)
  const target = defaultList(lists)
  const membership = useListMembership()
  const press = useLongPress(() => saveDialog.open(book))
  const on = target ? inList(book, target.id) : false
  const label = target ? (on ? t("list.remove", { name: listLabel(target) }) : t("list.add", { name: listLabel(target) })) : t("list.saveTo")
  return (
    <span className={cn("flex gap-1 touch:gap-3", className)}>
      <button
        type="button"
        aria-pressed={target ? on : undefined}
        aria-label={label}
        title={target ? `${label} · ${t("list.saveTo")}` : t("list.noDefault")}
        {...press.handlers}
        onClick={(e) => {
          e.preventDefault()
          e.stopPropagation()
          if (press.consumed()) return
          if (!target) return saveDialog.open(book)
          membership.mutate({ list: target, bookIds: [book.id], on: !on })
        }}
        className={cn(toggleClass(onCover), "touch-manipulation select-none [-webkit-touch-callout:none]", !on && "opacity-0 group-hover:opacity-100 focus-visible:opacity-100 [@media(hover:none)]:opacity-100 eink:opacity-100")}
      >
        <Bookmark className={cn("size-3.5 eink:size-5", on && "fill-current")} aria-hidden />
      </button>
    </span>
  )
}

// Takes the toggle's room in the list header, so the columns line up.
export function QuickListSpacer({ className }: { className?: string }) {
  return (
    <span aria-hidden className={cn("invisible flex gap-1 touch:gap-3", className)}>
      <span className={toggleClass()}>
        <Bookmark className="size-3.5 eink:size-5" />
      </span>
    </span>
  )
}

// Detail view: the default list as a toggle, "Speichern" for all lists and
// the list used last as a shortcut
export function ListButtons({ book }: { book: Book }) {
  const { data: lists } = useQuery(listsQuery)
  const membership = useListMembership()
  const target = defaultList(lists)
  const last = lastUsedList(lists)
  const on = target ? inList(book, target.id) : false
  return (
    <>
      {target && (
        <Button type="button" variant={on ? "secondary" : "outline"} aria-pressed={on} onClick={() => membership.mutate({ list: target, bookIds: [book.id], on: !on })}>
          {on ? <BookmarkCheck /> : <Bookmark />}
          {listLabel(target)}
        </Button>
      )}
      {last && last.id !== target?.id && !inList(book, last.id) && (
        <Button type="button" variant="outline" title={t("list.quickHint")} onClick={() => membership.mutate({ list: last, bookIds: [book.id], on: true })}>
          <BookmarkPlus /> {t("list.quick", { name: listLabel(last) })}
        </Button>
      )}
      <Button type="button" variant="outline" onClick={() => saveDialog.open(book)}>
        <ListPlus /> {t("list.save")}
      </Button>
    </>
  )
}

// Mounted once in the app shell
export function SaveDialogHost() {
  const book = useSaveDialog()
  return book ? <SaveDialog book={book} onClose={saveDialog.close} /> : null
}

// "Speichern": a checkbox per list, like a playlist dialog, nested like the
// lists; a new list with its name typed in place, a sublist under its node
function SaveDialog({ book, onClose }: { book: Book; onClose: () => void }) {
  const { data: lists, isPending } = useQuery(listsQuery)
  const { data: session } = useQuery(sessionQuery)
  // the cached book follows the toggles (optimistic)
  const { data: current = book } = useQuery({ ...bookQuery(book.id), placeholderData: book })
  const membership = useListMembership()
  // A click shows at once: the optimistic patch reaches `current` only a
  // tick later, and until then React puts the controlled box back. The
  // clicks hold until the cached book changes (patched or rolled back).
  const [clicked, setClicked] = useState<{ of: Book; on: Record<number, boolean> }>({ of: current, on: {} })
  if (clicked.of !== current) setClicked({ of: current, on: {} })
  const toggle = (l: ReadingList, on: boolean) => {
    setClicked((c) => ({ of: c.of, on: { ...c.on, [l.id]: on } }))
    membership.mutate({ list: l, bookIds: [book.id], on })
  }
  const editable = useMemo(() => savableLists(lists), [lists])
  const nodes = useMemo(() => flattenListTree(buildListTree(editable, session?.user)), [editable, session?.user])
  // the node a new sublist is typed under
  const [subOf, setSubOf] = useState<string | null>(null)
  const add = (l: ReadingList) => membership.mutate({ list: l, bookIds: [book.id], on: true })
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent aria-describedby={undefined} className="sm:max-w-sm">
        <DialogTitle className="text-lg font-semibold">{t("list.saveTitle")}</DialogTitle>
        <p className="-mt-2 truncate text-sm text-muted-foreground eink:text-black">{book.title}</p>
        {isPending ? (
          <p className="text-sm text-muted-foreground">{t("loading")}</p>
        ) : !editable.length ? (
          <p className="text-sm text-muted-foreground eink:text-black">{t("list.none")}</p>
        ) : (
          <ul className="-mx-2 max-h-[50vh] overflow-y-auto" aria-label={t("nav.lists")}>
            {nodes.map((n) => {
              const l = n.list
              const on = !!l && (clicked.on[l.id] ?? inList(current, l.id))
              const row = "flex min-h-9 min-w-0 flex-1 items-center gap-3 rounded-sm px-2 py-1 eink:min-h-12 touch:min-h-11"
              return (
                <li key={n.key} style={{ paddingLeft: n.depth * 20 }}>
                  <div className="flex items-center gap-1">
                    {l ? (
                      <label className={cn(row, "cursor-pointer hover:bg-accent")}>
                        <input
                          type="checkbox"
                          checked={on}
                          aria-label={listLabel(l)}
                          onChange={() => toggle(l, !on)}
                          className="size-4 eink:size-6"
                        />
                        <span className="min-w-0 flex-1 truncate">{n.name}</span>
                        {l.isDefault && <Bookmark className="size-3.5 shrink-0 text-muted-foreground eink:text-black" aria-label={t("list.defaultShort")} />}
                        {l.sync && <RefreshCw className="size-3.5 shrink-0 text-muted-foreground eink:text-black" aria-label={t("list.syncShort")} />}
                      </label>
                    ) : (
                      <span className={cn(row, "text-muted-foreground eink:text-black")}>
                        <Folder className="size-4 shrink-0 eink:size-6" aria-hidden />
                        <span className="min-w-0 flex-1 truncate">{n.name}</span>
                      </span>
                    )}
                    <Button
                      type="button"
                      variant="ghost"
                      size="icon"
                      aria-label={t("list.newSubIn", { name: listLabel(n.path) })}
                      title={t("list.newSubIn", { name: listLabel(n.path) })}
                      aria-expanded={subOf === n.path}
                      onClick={() => setSubOf(subOf === n.path ? null : n.path)}
                      className="shrink-0 text-muted-foreground eink:size-11 eink:text-black touch:size-11"
                    >
                      <Plus />
                    </Button>
                  </div>
                  {subOf === n.path && (
                    <NewListInline
                      initialOpen
                      parent={n.path}
                      className="pl-6"
                      onCreated={(created) => {
                        setSubOf(null)
                        add(created)
                      }}
                    />
                  )}
                </li>
              )
            })}
          </ul>
        )}
        {membership.error && (
          <p role="alert" className="text-sm text-destructive">
            {membership.error instanceof ApiError ? membership.error.message : String(membership.error)}
          </p>
        )}
        <NewListInline onCreated={(l) => membership.mutate({ list: l, bookIds: [book.id], on: true })} />
        <div className="flex justify-end">
          <Button variant="outline" onClick={onClose}>
            {t("book.close")}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  )
}

// "+ Neue Liste": a button that turns into a name field; with a parent the
// new list is a sublist of it ("Urlaub" + "2026" = "Urlaub/2026")
export function NewListInline({
  onCreated,
  initialOpen = false,
  parent,
  className,
}: {
  onCreated: (list: ReadingList) => void
  initialOpen?: boolean
  parent?: string
  className?: string
}) {
  const [open, setOpen] = useState(initialOpen)
  const [name, setName] = useState("")
  const create = useCreateList()
  if (!open) {
    return (
      <Button type="button" variant="ghost" className={cn("justify-start", className)} onClick={() => setOpen(true)}>
        <ListPlus /> {parent ? t("list.newSub") : t("list.new")}
      </Button>
    )
  }
  const submit = (e: FormEvent) => {
    e.preventDefault()
    if (!name.trim()) return
    create.mutate(
      { name: parent ? `${parent}/${name.trim()}` : name.trim() },
      {
        onSuccess: (l) => {
          setName("")
          setOpen(false)
          onCreated(l)
        },
      },
    )
  }
  const taken = create.error instanceof ApiError && create.error.status === 409
  return (
    <form onSubmit={submit} className={cn("space-y-1", parent && className)}>
      <div className="flex gap-2">
        <Input
          autoFocus
          value={name}
          onChange={(e) => setName(e.target.value)}
          aria-label={parent ? t("list.newSubName", { name: listLabel(parent) }) : t("list.newName")}
          placeholder={parent ? t("list.newSub") : t("list.newName")}
          maxLength={120}
        />
        <Button type="submit" disabled={!name.trim() || create.isPending}>
          {t("list.create")}
        </Button>
      </div>
      {create.error && (
        <p role="alert" className="text-xs text-destructive eink:font-bold eink:text-black">
          {taken ? t("list.taken") : create.error instanceof ApiError ? create.error.message : String(create.error)}
        </p>
      )}
    </form>
  )
}

// Up to four covers of the books added last
export function Mosaic({ list, className }: { list: ReadingList; className?: string }) {
  const ids = list.coverBookIds.slice(0, 4)
  return (
    <div
      role="img"
      aria-label={t("list.mosaic")}
      className={cn("grid aspect-[3/4] w-24 shrink-0 grid-cols-2 grid-rows-2 gap-0.5 overflow-hidden rounded-md bg-muted sm:w-32 eink:border-2 eink:border-black", className)}
    >
      {ids.length === 0 ? (
        <Bookmark className="col-span-2 row-span-2 m-auto size-8 text-muted-foreground eink:text-black" aria-hidden />
      ) : (
        Array.from({ length: 4 }, (_, i) =>
          ids[i] != null ? (
            <img
              key={ids[i]}
              src={coverUrl(ids[i])}
              alt=""
              loading="lazy"
              // a book without a cover leaves its tile empty
              onError={(e) => (e.currentTarget.style.visibility = "hidden")}
              className={cn("h-full w-full object-cover", ids.length === 1 && "col-span-2 row-span-2")}
            />
          ) : ids.length > 1 ? (
            <span key={`e${i}`} className="bg-muted" />
          ) : null,
        )
      )}
    </div>
  )
}

// The levels above a list, each one opens its page: "Urlaub › 2026"
function ListTrail({ trail, user }: { trail: ListNode[]; user?: string }) {
  if (trail.length < 2) return null
  const above = trail.slice(0, -1)
  return (
    <nav aria-label={t("list.trail")} className="-mb-1 flex flex-wrap items-center gap-x-1 text-sm text-muted-foreground eink:text-base eink:text-black">
      {above.map((n) => (
        <span key={n.key} className="flex items-center gap-1">
          <LibraryLink
            search={withFilter({}, nodeSearch(n, user))}
            className="rounded-sm underline-offset-2 hover:underline eink:inline-flex eink:min-h-11 eink:items-center touch:inline-flex touch:min-h-11 touch:items-center"
          >
            {n.name}
          </LibraryLink>
          <ChevronRight className="size-3.5" aria-hidden />
        </span>
      ))}
      <span aria-current="page" className="sr-only">
        {trail.at(-1)!.name}
      </span>
    </nav>
  )
}

// "Nur direkt": a list with sublists shows theirs too unless this is on
function DirectToggle({ search }: { search: LibrarySearch }) {
  const navigate = useNavigate()
  return (
    <Button
      variant="outline"
      size="sm"
      aria-pressed={!!search.direct}
      title={t("list.directHint")}
      onClick={() => navigate({ to: "/", search: withFilter(search, { direct: search.direct ? undefined : true }) })}
    >
      <ListTree /> {t("list.direct")}
    </Button>
  )
}

const subListCount = (n?: ListNode) => {
  const count = n ? flattenListTree(n.children).filter((c) => c.list).length : 0
  return count === 1 ? t("list.oneSubList") : t("list.subLists", { count: formatNumber(count) })
}

// Top of a level of the list tree without a list of its own ("Reise" above
// "Reise/Meer"): the path, its name and the sublists' books below
export function ListNodeHeader({ node, tree, user }: { node: ListNode; tree: ListNode[]; user?: string }) {
  return (
    <header className="flex gap-4 sm:gap-5">
      <div className="flex aspect-[3/4] w-24 shrink-0 items-center justify-center rounded-md bg-muted sm:w-32 eink:border-2 eink:border-black">
        <Folder className="size-8 text-muted-foreground eink:text-black" aria-hidden />
      </div>
      <div className="min-w-0 flex-1 space-y-2">
        <ListTrail trail={nodeTrail(tree, node)} user={user} />
        <h1 className="text-xl leading-tight font-semibold text-balance sm:text-2xl">{node.name}</h1>
        <p className="flex flex-wrap items-center gap-2 text-sm">
          <span>{t("list.folder")}</span>
          <span aria-hidden>·</span>
          <span>{subListCount(node)}</span>
        </p>
      </div>
    </header>
  )
}

// Top of a list's page: covers, path above it, name, description, count
// and what can be done with the list
export function ListHeader({ list, node, tree, user, search }: { list: ReadingList; node?: ListNode; tree?: ListNode[]; user?: string; search: LibrarySearch }) {
  const update = useUpdateList()
  const [editing, setEditing] = useState(false)
  const hasSub = !!node?.children.length
  const total = list.totalCount ?? list.count
  const { data: session } = useQuery(sessionQuery)
  const configure = mayConfigureList(session, list)
  return (
    <header className="flex gap-4 sm:gap-5">
      <Mosaic list={list} />
      <div className="min-w-0 flex-1 space-y-2">
        {node && tree && <ListTrail trail={nodeTrail(tree, node)} user={user} />}
        <h1 className="text-xl leading-tight font-semibold text-balance sm:text-2xl">{listLeaf(list)}</h1>
        {list.description && <p className="text-sm whitespace-pre-line text-muted-foreground eink:text-base eink:text-black">{list.description}</p>}
        {list.rule && <RuleLine rule={list.rule} error={list.queryError} />}
        <p className="flex flex-wrap items-center gap-2 text-sm">
          <span className="tabular-nums">{list.count === 1 ? t("list.oneBook") : t("list.books", { count: formatNumber(list.count) })}</span>
          {hasSub && <span className="tabular-nums">{t("list.withSub", { count: formatNumber(total) })}</span>}
          {list.rule && <Badge variant="secondary">{t("shelf.label")}</Badge>}
          {list.isDefault && <Badge variant="secondary">{t("list.defaultShort")}</Badge>}
          {list.sync && <Badge variant="secondary">{t("list.syncShort")}</Badge>}
          {list.visibility !== "private" && <Badge variant="outline">{t(`list.visibility.${list.visibility}`)}</Badge>}
          {!list.editable && <Badge variant="outline">{t("list.readOnly")}</Badge>}
        </p>
        {(configure || hasSub) && (
          <div className="flex flex-wrap gap-2">
            {hasSub && <DirectToggle search={search} />}
            {configure && (
              <>
                <Button
                  variant="outline"
                  size="sm"
                  aria-pressed={list.favorite}
                  onClick={() => update.mutate({ id: list.id, patch: { favorite: !list.favorite } })}
                >
                  <Star className={cn(list.favorite && "fill-current")} /> {t("list.favoriteShort")}
                </Button>
                <Button variant="outline" size="sm" onClick={() => setEditing(true)}>
                  <Pencil /> {t(list.rule ? "shelf.edit" : "list.edit")}
                </Button>
              </>
            )}
          </div>
        )}
      </div>
      {editing && <ListEditDialog list={list} hasSublists={hasSub} onClose={() => setEditing(false)} />}
    </header>
  )
}

// Name, description, flags and visibility; delete (asks first). Opened on
// the delete question from the overview's "Löschen". Deleting leaves the
// list's page for the library unless onDeleted says otherwise.
export function ListEditDialog({
  list,
  onClose,
  startWithDelete = false,
  onDeleted,
  hasSublists = false,
}: {
  list: ReadingList
  onClose: () => void
  startWithDelete?: boolean
  onDeleted?: () => void
  // deleting leaves them; renaming takes them along
  hasSublists?: boolean
}) {
  const update = useUpdateList()
  const del = useDeleteList()
  const navigate = useNavigate()
  const [name, setName] = useState(list.name)
  const [description, setDescription] = useState(list.description)
  const [sync, setSync] = useState(list.sync)
  const [favorite, setFavorite] = useState(list.favorite)
  const [isDefault, setDefault] = useState(list.isDefault)
  const [visibility, setVisibility] = useState<Visibility>(list.visibility)
  // a magic shelf: its rule instead of default list and sync
  const [rule, setRule] = useState<ShelfRule | null>(() => (list.rule ? toForm(list.rule) : null))
  const [confirmDelete, setConfirmDelete] = useState(startWithDelete)
  const { data: session } = useQuery(sessionQuery)
  // only the owner deletes a list
  const owner = session?.user === list.owner
  const submit = (e: FormEvent) => {
    e.preventDefault()
    const patch: ListPatch = rule
      ? { name: name.trim(), description, favorite, visibility, rule: fromForm(rule) }
      : { name: name.trim(), description, ...(sync !== list.sync ? { sync } : {}), favorite, isDefault, visibility }
    update.mutate({ id: list.id, patch }, { onSuccess: onClose })
  }
  const error = update.error ?? del.error
  const check = "flex items-center gap-3 text-sm eink:min-h-11 touch:min-h-11 eink:text-base"
  const shelf = !!list.rule
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className={cn(shelf && !confirmDelete && "sm:max-w-xl")} {...(confirmDelete ? {} : { "aria-describedby": undefined })}>
        <DialogTitle className="text-lg font-semibold">{confirmDelete ? t(shelf ? "shelf.delete" : "list.delete") : t(shelf ? "shelf.edit" : "list.edit")}</DialogTitle>
        {confirmDelete ? (
          <>
            <DialogDescription>
              {t(shelf ? "shelf.deleteText" : "list.deleteText", { name: listLabel(list) })}
              {hasSublists && ` ${t("list.deleteKeepsSub")}`}
            </DialogDescription>
            <div className="flex justify-end gap-2">
              <Button variant="outline" onClick={() => (startWithDelete ? onClose() : setConfirmDelete(false))}>
                {t("edit.cancel")}
              </Button>
              <Button
                variant="destructive"
                disabled={del.isPending}
                onClick={() =>
                  del.mutate(list.id, {
                    onSuccess: () => {
                      if (onDeleted) {
                        onClose()
                        return onDeleted()
                      }
                      const left = leaveOverlays()
                      onClose()
                      left.then(() => navigate({ to: "/", search: {}, replace: true }))
                    },
                  })
                }
              >
                <Trash2 /> {t(shelf ? "shelf.deleteConfirm" : "list.deleteConfirm")}
              </Button>
            </div>
          </>
        ) : (
          <form onSubmit={submit} className="space-y-4">
            <label className="block space-y-1 text-sm">
              <span className="font-medium">{t("list.name")}</span>
              <Input value={name} onChange={(e) => setName(e.target.value)} required maxLength={120} />
              <span className="block text-xs text-muted-foreground eink:text-black">{t("list.nameHint")}</span>
            </label>

            <label className="block space-y-1 text-sm">
              <span className="font-medium">{t("list.description")}</span>
              <textarea
                value={description}
                onChange={(e) => setDescription(e.target.value)}
                rows={3}
                className="w-full rounded-md border bg-transparent px-3 py-2 text-sm eink:border-2 eink:text-base"
              />
            </label>
            {rule && <RuleEditor rule={rule} onChange={setRule} />}
            <div className="space-y-1">
              <label className={check}>
                <input type="checkbox" checked={favorite} onChange={(e) => setFavorite(e.target.checked)} className="size-4 eink:size-6" />
                {t("list.favorite")}
              </label>
              {!rule && (
                <>
                  <label className={check}>
                    <input type="checkbox" checked={isDefault} onChange={(e) => setDefault(e.target.checked)} className="size-4 eink:size-6" />
                    {t("list.default")}
                  </label>
                  {/* the reader folder is the admin's e-reader */}
                  {isAdmin(session) && (
                    <label className={check}>
                      <input type="checkbox" checked={sync} onChange={(e) => setSync(e.target.checked)} className="size-4 eink:size-6" />
                      {t("list.sync")}
                    </label>
                  )}
                </>
              )}
            </div>
            <label className="block space-y-1 text-sm">
              <span className="font-medium">{t("list.visibility")}</span>
              <select
                value={visibility}
                onChange={(e) => setVisibility(e.target.value as Visibility)}
                className="h-9 w-full rounded-md border bg-background px-2 text-sm eink:h-12 touch:h-11 eink:border-2 eink:text-base"
              >
                {VISIBILITIES.map((v) => (
                  <option key={v} value={v}>
                    {t(`list.visibility.${v}`)}
                  </option>
                ))}
              </select>
              <span className="block text-xs text-muted-foreground eink:text-black">{t("list.visibilityHint")}</span>
            </label>
            {error && (
              <p role="alert" className="text-sm text-destructive">
                {error instanceof ApiError && error.status === 409 ? t("list.taken") : error instanceof ApiError ? error.message : String(error)}
              </p>
            )}
            <div className="flex flex-wrap justify-between gap-2">
              {owner && (
                <Button type="button" variant="outline" className="text-destructive hover:text-destructive eink:text-black" onClick={() => setConfirmDelete(true)}>
                  <Trash2 /> {t("list.delete")}
                </Button>
              )}
              <div className="ml-auto flex gap-2">
                <Button type="button" variant="outline" onClick={onClose}>
                  {t("edit.cancel")}
                </Button>
                <Button type="submit" disabled={!name.trim() || (!!rule && !ruleComplete(rule)) || update.isPending}>
                  {t("edit.save")}
                </Button>
              </div>
            </div>
          </form>
        )}
      </DialogContent>
    </Dialog>
  )
}
