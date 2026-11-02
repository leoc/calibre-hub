import { useState, type FormEvent } from "react"
import { useQuery } from "@tanstack/react-query"
import { useNavigate } from "@tanstack/react-router"
import { Bookmark, BookmarkCheck, BookmarkPlus, ListPlus, Pencil, RefreshCw, Star, Trash2 } from "lucide-react"
import { ApiError, coverUrl, VISIBILITIES, type Book, type ReadingList, type Visibility } from "@/lib/api"
import { bookQuery, sessionQuery } from "@/lib/queries"
import {
  defaultList,
  inList,
  lastUsedList,
  listsQuery,
  saveDialog,
  useCreateList,
  useDeleteList,
  useListMembership,
  useLongPress,
  useSaveDialog,
  useUpdateList,
} from "@/lib/lists"
import { leaveOverlays } from "@/lib/back-to-close"
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
  const label = target ? (on ? t("list.remove", { name: target.name }) : t("list.add", { name: target.name })) : t("list.saveTo")
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
          {target.name}
        </Button>
      )}
      {last && last.id !== target?.id && !inList(book, last.id) && (
        <Button type="button" variant="outline" title={t("list.quickHint")} onClick={() => membership.mutate({ list: last, bookIds: [book.id], on: true })}>
          <BookmarkPlus /> {t("list.quick", { name: last.name })}
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

// "Speichern": a checkbox per list, like a playlist dialog, and a new list
// with its name typed in place
function SaveDialog({ book, onClose }: { book: Book; onClose: () => void }) {
  const { data: lists, isPending } = useQuery(listsQuery)
  // the cached book follows the toggles (optimistic)
  const { data: current = book } = useQuery({ ...bookQuery(book.id), placeholderData: book })
  const membership = useListMembership()
  const editable = lists?.filter((l) => l.editable) ?? []
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
            {editable.map((l) => {
              const on = inList(current, l.id)
              return (
                <li key={l.id}>
                  <label className="flex min-h-9 cursor-pointer items-center gap-3 rounded-sm px-2 py-1 hover:bg-accent eink:min-h-12 touch:min-h-11">
                    <input type="checkbox" checked={on} onChange={() => membership.mutate({ list: l, bookIds: [book.id], on: !on })} className="size-4 eink:size-6" />
                    <span className="min-w-0 flex-1 truncate">{l.name}</span>
                    {l.isDefault && <Bookmark className="size-3.5 shrink-0 text-muted-foreground eink:text-black" aria-label={t("list.defaultShort")} />}
                    {l.sync && <RefreshCw className="size-3.5 shrink-0 text-muted-foreground eink:text-black" aria-label={t("list.syncShort")} />}
                  </label>
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

// "+ Neue Liste": a button that turns into a name field
export function NewListInline({ onCreated, initialOpen = false, className }: { onCreated: (list: ReadingList) => void; initialOpen?: boolean; className?: string }) {
  const [open, setOpen] = useState(initialOpen)
  const [name, setName] = useState("")
  const create = useCreateList()
  if (!open) {
    return (
      <Button type="button" variant="ghost" className={cn("justify-start", className)} onClick={() => setOpen(true)}>
        <ListPlus /> {t("list.new")}
      </Button>
    )
  }
  const submit = (e: FormEvent) => {
    e.preventDefault()
    if (!name.trim()) return
    create.mutate(
      { name: name.trim() },
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
    <form onSubmit={submit} className="space-y-1">
      <div className="flex gap-2">
        <Input autoFocus value={name} onChange={(e) => setName(e.target.value)} aria-label={t("list.newName")} placeholder={t("list.newName")} maxLength={120} />
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
function Mosaic({ list }: { list: ReadingList }) {
  const ids = list.coverBookIds.slice(0, 4)
  return (
    <div role="img" aria-label={t("list.mosaic")} className="grid aspect-[3/4] w-24 shrink-0 grid-cols-2 grid-rows-2 gap-0.5 overflow-hidden rounded-md bg-muted sm:w-32 eink:border-2 eink:border-black">
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

// Top of a list's page: covers, name, description, count and what can be
// done with the list
export function ListHeader({ list }: { list: ReadingList }) {
  const update = useUpdateList()
  const [editing, setEditing] = useState(false)
  return (
    <header className="flex gap-4 sm:gap-5">
      <Mosaic list={list} />
      <div className="min-w-0 flex-1 space-y-2">
        <h1 className="text-xl leading-tight font-semibold text-balance sm:text-2xl">{list.name}</h1>
        {list.description && <p className="text-sm whitespace-pre-line text-muted-foreground eink:text-base eink:text-black">{list.description}</p>}
        <p className="flex flex-wrap items-center gap-2 text-sm">
          <span className="tabular-nums">{list.count === 1 ? t("list.oneBook") : t("list.books", { count: formatNumber(list.count) })}</span>
          {list.isDefault && <Badge variant="secondary">{t("list.defaultShort")}</Badge>}
          {list.sync && <Badge variant="secondary">{t("list.syncShort")}</Badge>}
          {list.visibility !== "private" && <Badge variant="outline">{t(`list.visibility.${list.visibility}`)}</Badge>}
          {!list.editable && <Badge variant="outline">{t("list.readOnly")}</Badge>}
        </p>
        {list.editable && (
          <div className="flex flex-wrap gap-2">
            <Button
              variant="outline"
              size="sm"
              aria-pressed={list.favorite}
              onClick={() => update.mutate({ id: list.id, patch: { favorite: !list.favorite } })}
            >
              <Star className={cn(list.favorite && "fill-current")} /> {t("list.favoriteShort")}
            </Button>
            <Button variant="outline" size="sm" onClick={() => setEditing(true)}>
              <Pencil /> {t("list.edit")}
            </Button>
          </div>
        )}
      </div>
      {editing && <ListEditDialog list={list} onClose={() => setEditing(false)} />}
    </header>
  )
}

function ListEditDialog({ list, onClose }: { list: ReadingList; onClose: () => void }) {
  const update = useUpdateList()
  const del = useDeleteList()
  const navigate = useNavigate()
  const [name, setName] = useState(list.name)
  const [description, setDescription] = useState(list.description)
  const [sync, setSync] = useState(list.sync)
  const [favorite, setFavorite] = useState(list.favorite)
  const [isDefault, setDefault] = useState(list.isDefault)
  const [visibility, setVisibility] = useState<Visibility>(list.visibility)
  const [confirmDelete, setConfirmDelete] = useState(false)
  const { data: session } = useQuery(sessionQuery)
  // only the owner deletes a list
  const owner = session?.user === list.owner
  const submit = (e: FormEvent) => {
    e.preventDefault()
    update.mutate({ id: list.id, patch: { name: name.trim(), description, sync, favorite, isDefault, visibility } }, { onSuccess: onClose })
  }
  const error = update.error ?? del.error
  const check = "flex items-center gap-3 text-sm eink:min-h-11 touch:min-h-11 eink:text-base"
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent {...(confirmDelete ? {} : { "aria-describedby": undefined })}>
        <DialogTitle className="text-lg font-semibold">{confirmDelete ? t("list.delete") : t("list.edit")}</DialogTitle>
        {confirmDelete ? (
          <>
            <DialogDescription>{t("list.deleteText", { name: list.name })}</DialogDescription>
            <div className="flex justify-end gap-2">
              <Button variant="outline" onClick={() => setConfirmDelete(false)}>
                {t("edit.cancel")}
              </Button>
              <Button
                variant="destructive"
                disabled={del.isPending}
                onClick={() =>
                  del.mutate(list.id, {
                    onSuccess: () => {
                      const left = leaveOverlays()
                      onClose()
                      left.then(() => navigate({ to: "/", search: {}, replace: true }))
                    },
                  })
                }
              >
                <Trash2 /> {t("list.deleteConfirm")}
              </Button>
            </div>
          </>
        ) : (
          <form onSubmit={submit} className="space-y-4">
            <label className="block space-y-1 text-sm">
              <span className="font-medium">{t("list.name")}</span>
              <Input value={name} onChange={(e) => setName(e.target.value)} required maxLength={120} />
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
            <div className="space-y-1">
              <label className={check}>
                <input type="checkbox" checked={favorite} onChange={(e) => setFavorite(e.target.checked)} className="size-4 eink:size-6" />
                {t("list.favorite")}
              </label>
              <label className={check}>
                <input type="checkbox" checked={isDefault} onChange={(e) => setDefault(e.target.checked)} className="size-4 eink:size-6" />
                {t("list.default")}
              </label>
              <label className={check}>
                <input type="checkbox" checked={sync} onChange={(e) => setSync(e.target.checked)} className="size-4 eink:size-6" />
                {t("list.sync")}
              </label>
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
                <Button type="submit" disabled={!name.trim() || update.isPending}>
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
