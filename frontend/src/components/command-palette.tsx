import { useEffect, useMemo, useRef, useState, type ReactNode } from "react"
import { useQuery, useQueryClient } from "@tanstack/react-query"
import { useNavigate } from "@tanstack/react-router"
import { ArrowDownUp, ArrowLeft, BookmarkPlus, BookText, Check, CopyCheck, Folder, FolderTree, Import, Inbox, Keyboard, LayoutGrid, LibraryBig, List, ListFilter, ListIcon, ListPlus, LockKeyhole, LogOut, Palette, Pencil, Search, Sparkles, Tag, Trash2, User, WandSparkles, X } from "lucide-react"
import { api, coverUrl, DEFAULT_CONFIG, type Sort } from "@/lib/api"
import { booksQuery, categoriesQuery, configQuery } from "@/lib/queries"
import { flattenListTree, inList, lastUsedList, listLabel, nodeCount, nodeSearch, saveDialog, useListMembership, useListTree } from "@/lib/lists"
import { matchNamed, parseInput, type Scope } from "@/lib/palette"
import { categorySuggestions } from "@/lib/kategorie"
import { bookAction, commandLabel, needsConfirm, offeredActions, parseDirect, valueChoices, type ActionValue, type BookActionDef } from "@/lib/book-actions"
import { runAction } from "@/lib/run-action"
import { useActionTarget } from "@/lib/use-action-target"
import { toast } from "@/lib/toast"
import { defaultOrder, sortsFor, togglePrivateTag, toggleTag, withFilter } from "@/lib/search"
import { useIsAdmin } from "@/lib/session"
import { useLibrarySearch } from "@/lib/use-library"
import { useRouterState } from "@tanstack/react-router"
import { setView } from "@/lib/prefs"
import { keyboard } from "@/lib/keyboard"
import { MODES } from "@/lib/keymap"
import { THEMES, useTheme } from "@/lib/theme"
import { useDesktop } from "@/lib/use-media"
import { leaveOverlays } from "@/lib/back-to-close"
import { emptyCondition, nameFromRule, ruleFromSearch, shelfDialog } from "@/lib/shelves"
import { formatNumber, t } from "@/i18n"
import type { MessageKey } from "@/i18n/de"
import { Command, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList, CommandShortcut } from "./ui/command"
import { Dialog, DialogContent, DialogTitle } from "./ui/dialog"

interface Props {
  initialInput: string
  onClose: () => void
}

function useDebounced<T>(value: T, ms: number) {
  const [v, setV] = useState(value)
  useEffect(() => {
    const id = setTimeout(() => setV(value), ms)
    return () => clearTimeout(id)
  }, [value, ms])
  return v
}

// "Zu Liste: Urlaub" is found by "zu liste urlaub" too
const plain = (s: string) => s.toLowerCase().replace(/[:…]/g, " ").replace(/\s+/g, " ").trim()

interface Action {
  id: string
  label: string
  icon: ReactNode
  run: () => void
}

// Mounted only while open, so state starts fresh each time.
export function CommandPalette({ initialInput, onClose }: Props) {
  const open = true
  const search = useLibrarySearch()
  const [input, setInput] = useState(initialInput)
  const inputRef = useRef<HTMLInputElement>(null)
  const { scope, text } = parseInput(input)
  const debounced = useDebounced(text, 200)
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const desktop = useDesktop()
  const { setTheme } = useTheme()
  const { data: cats } = useQuery({ ...categoriesQuery, enabled: open })
  // a command's second step or its question: only that
  const [step, setStep] = useState<BookActionDef | null>(null)
  // from: the entry that asked, selected again on "Abbrechen"
  const [confirm, setConfirm] = useState<{ def: BookActionDef; value?: ActionValue; from: string } | null>(null)
  // the selected entry; switching to the question selects "Ja"
  const [selected, setSelected] = useState("")
  const wants = (s: Scope) => !step && !confirm && (scope === "all" || scope === s)
  const books = useQuery({
    ...booksQuery({ q: debounced, limit: 8, sort: "title" }),
    enabled: open && wants("books") && debounced.length > 1,
  })

  const close = onClose
  // navigate once the palette's history entry (back button) is gone, so
  // Back afterwards returns to where the palette was opened
  const closeThen = (next: () => void) => {
    const left = leaveOverlays()
    close()
    left.then(next)
  }
  const go = (s: Parameters<typeof withFilter>[0]) => closeThen(() => navigate({ to: "/", search: s }))

  const { data: config = DEFAULT_CONFIG } = useQuery(configQuery)
  const onLibrary = useRouterState({ select: (s) => s.location.pathname }) === "/"
  const { lists, tree, user } = useListTree(open)
  const membership = useListMembership()
  // what commands on books act on: the selection, the active book or the detail
  const target = useActionTarget(open)
  const openBook = target?.book
  const last = lastUsedList(lists)
  // one book: the save dialog, the list used last, editing
  const bookExtras: Action[] = openBook
    ? [
        ...(last && !inList(openBook, last.id)
          ? [{ id: "list-last", label: t("list.quick", { name: listLabel(last) }), icon: <BookmarkPlus />, run: () => (membership.mutate({ list: last, bookIds: [openBook.id], on: true }), close()) }]
          : []),
        { id: "list-dialog", label: `${t("list.saveTitle")}: ${openBook.title}`, icon: <ListPlus />, run: () => closeThen(() => saveDialog.open(openBook)) },
        ...(onLibrary ? [{ id: "edit", label: `${t("book.edit")}: ${openBook.title}`, icon: <Pencil />, run: () => go({ ...search, book: openBook.id, edit: true }) }] : []),
      ]
    : []

  // commands on books (src/lib/book-actions.ts): as typed ("tag krimi"), or
  // a second step that picks the value ("Tag hinzufügen" -> the tags)
  // a reader: only what changes their own things (lists, private tags)
  const admin = useIsAdmin()
  const defs = target ? offeredActions(target, config, admin) : [bookAction("newList")]
  const sources = { cats, lists, book: openBook }
  const ctx = { qc: queryClient, navigate }
  const runNow = (def: BookActionDef, value?: ActionValue) => {
    const on = target ?? { bulk: { ids: [] }, count: 0, ordered: false }
    closeThen(() => {
      if (def.changes) toast.show(t("actions.running", { label: commandLabel(def, target, value && { ...value, isNew: false }) }))
      void runAction(ctx, def, on, value)
    })
  }
  const start = (def: BookActionDef, value?: ActionValue) => {
    if (!target || !needsConfirm(def, target)) return runNow(def, value)
    setConfirm({ def, value, from: selected })
    setSelected("confirm-yes")
  }
  const back = () => {
    if (confirm) {
      setSelected(confirm.from)
      setConfirm(null)
    } else {
      setStep(null)
      setInput(">")
    }
  }
  const pick = (def: BookActionDef) => {
    setStep(def)
    setInput("")
  }
  const commandItems: Action[] = (target ? defs : []).map((def) => {
    const Icon = def.icon
    return { id: `cmd-${def.id}`, label: commandLabel(def, target), icon: <Icon />, run: () => (def.value ? pick(def) : start(def)) }
  })
  const valueItem = (def: BookActionDef, v: ActionValue): Action => {
    const Icon = def.icon
    return { id: `val-${def.id}-${v.isNew ? "new" : ""}${v.value}`, label: commandLabel(def, target, v), icon: <Icon />, run: () => start(def, v) }
  }
  const directItems: Action[] =
    scope === "actions"
      ? parseDirect(text, defs).flatMap(({ def, rest }) =>
          valueChoices(def, sources, rest, 5)
            .filter((v) => !v.clear)
            .map((v) => valueItem(def, v)),
        )
      : []

  // magic shelves: the library's filters as one ("Als Regal speichern"), or an empty one
  const searchRule = onLibrary ? ruleFromSearch(search, config.categoryColumn) : null
  const shelfActions: Action[] = [
    ...(searchRule
      ? [{ id: "shelf-search", label: t("shelf.fromSearch"), icon: <ListFilter />, run: () => closeThen(() => shelfDialog.open({ rule: searchRule, name: nameFromRule(searchRule) })) }]
      : []),
    { id: "shelf-new", label: t("shelf.new"), icon: <ListFilter />, run: () => closeThen(() => shelfDialog.open({ rule: { match: "all", conditions: [emptyCondition()] } })) },
  ]

  const actions: Action[] = useMemo(
    () => [
      { id: "all", label: t("nav.all"), icon: <LibraryBig />, run: () => go({}) },
      { id: "lists", label: t("nav.lists"), icon: <ListIcon />, run: () => closeThen(() => navigate({ to: "/lists" })) },
      // the library's upkeep is the admin's
      ...(admin
        ? [
            { id: "trash", label: t("trash.title"), icon: <Trash2 />, run: () => closeThen(() => navigate({ to: "/trash" })) },
            { id: "duplicates", label: t("dup.title"), icon: <CopyCheck />, run: () => closeThen(() => navigate({ to: "/duplicates" })) },
            { id: "import", label: t("import.page"), icon: <Import />, run: () => closeThen(() => navigate({ to: "/import" })) },
            { id: "intake", label: t("intake.title"), icon: <Inbox />, run: () => closeThen(() => navigate({ to: "/eingang" })) },
          ]
        : []),
      ...(config.classify && admin
        ? [{ id: "suggestions", label: t("suggest.title"), icon: <Sparkles />, run: () => closeThen(() => navigate({ to: "/suggestions" })) }]
        : []),
      ...(config.metadata && admin
        ? [{ id: "metadata", label: t("meta.title"), icon: <WandSparkles />, run: () => closeThen(() => navigate({ to: "/metadata" })) }]
        : []),
      { id: "grid", label: t("view.grid"), icon: <LayoutGrid />, run: () => (setView("grid"), close()) },
      { id: "list", label: t("view.list"), icon: <List />, run: () => (setView("list"), close()) },
      ...THEMES.map((th) => ({ id: `theme-${th}`, label: `${t("theme.label")}: ${t(`theme.${th}`)}`, icon: <Palette />, run: () => (setTheme(th), close()) })),
      ...MODES.map((m) => ({ id: `keys-${m}`, label: `${t("keys.label")}: ${t(`keys.${m}`)}`, icon: <Keyboard />, run: () => (keyboard.setMode(m), close()) })),
      { id: "keys-help", label: t("keys.help"), icon: <Keyboard />, run: () => closeThen(() => keyboard.setPanel("help")) },
      { id: "keys-settings", label: t("keys.settings"), icon: <Keyboard />, run: () => closeThen(() => keyboard.setPanel("settings")) },
      ...sortsFor(search).map((s: Sort) => ({
        id: `sort-${s}`,
        label: `${t("sort.label")}: ${t(`sort.${s}`)}`,
        icon: <ArrowDownUp />,
        run: () => go({ ...search, sort: s, order: defaultOrder(s), page: undefined }),
      })),
      {
        id: "logout",
        label: t("logout"),
        icon: <LogOut />,
        run: async () => {
          await api.logout().catch(() => undefined)
          queryClient.clear()
          window.location.href = "/login"
        },
      },
    ],
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [search, config.classify, config.metadata, admin],
  )

  const limit = scope === "all" ? 5 : 30
  const authors = cats && wants("authors") ? matchNamed(cats.authors, text, limit) : []
  const series = cats && wants("series") ? matchNamed(cats.series, text, limit) : []
  const tags = cats && wants("tags") ? matchNamed(cats.tags, text, limit) : []
  // the user's own tags, in the same scope ("t ")
  const privateTags = cats && wants("tags") ? matchNamed(cats.privateTags ?? [], text, limit) : []
  // shown and matched as "A/B"
  const kategorien = cats && wants("kategorie") ? matchNamed(categorySuggestions(cats.kategorie), text, limit) : []
  // every level of the tree as a path ("Urlaub/2026"), also one without a
  // list of its own; matched and shown as the path
  const listItems =
    tree && wants("lists")
      ? matchNamed(
          flattenListTree(tree).map((n) => ({ node: n, name: listLabel(n.path), count: nodeCount(n) ?? 0 })),
          text,
          limit,
        )
      : []
  // a new name typed in the lists scope ("> Neue Liste: Name" is a direct command)
  const offerNew = scope === "lists" && !!text && !lists?.some((l) => listLabel(l).toLowerCase() === listLabel(text).toLowerCase())
  const newListItem = offerNew ? valueItem(bookAction("newList"), { value: listLabel(text), label: listLabel(text), isNew: true }) : null
  const matchedActions = [
    ...(newListItem ? [newListItem] : []),
    ...directItems,
    ...(scope === "actions" || (scope === "all" && text)
      ? [...commandItems, ...bookExtras, ...shelfActions, ...actions].filter((a) => plain(a.label).includes(plain(text))).slice(0, scope === "all" ? 4 : undefined)
      : []),
  ]
  // the second step: the values of one command
  const stepItems = step ? valueChoices(step, sources, input, 200) : []
  const showFulltext = !step && !confirm && (scope === "all" || scope === "books") && text.length > 0

  const fulltext = (
    <CommandGroup>
      <CommandItem value="fulltext" onSelect={() => go(withFilter({}, { q: text }))}>
        <Search />
        {t("palette.fulltext", { q: text })}
      </CommandItem>
    </CommandGroup>
  )

  // hide: no count (a level of the list tree without a list)
  const named = <T extends { name: string; count: number }>(items: T[], icon: ReactNode | ((i: T) => ReactNode), onPick: (i: T) => void, prefix: string, hide?: (i: T) => boolean) =>
    items.map((i) => (
      <CommandItem key={`${prefix}:${i.name}`} value={`${prefix}:${i.name}`} onSelect={() => onPick(i)}>
        {typeof icon === "function" ? icon(i) : icon}
        <span className="truncate">{i.name}</span>
        {!hide?.(i) && <CommandShortcut>{formatNumber(i.count)}</CommandShortcut>}
      </CommandItem>
    ))

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent
        className="top-0 h-dvh max-h-none w-full max-w-none translate-x-[-50%] overflow-hidden rounded-none border-0 p-0 pt-[env(safe-area-inset-top)] pb-[env(safe-area-inset-bottom)] sm:pt-0 sm:pb-0 sm:top-[10vh] sm:h-auto sm:w-[calc(100%-2rem)] sm:max-w-2xl sm:rounded-lg sm:border"
        showClose={false}
        aria-describedby={undefined}
        // Radix would select the text; keep the cursor at the end so typing
        // on after a prefix from the search bar continues it
        onOpenAutoFocus={(e) => {
          e.preventDefault()
          const el = inputRef.current
          el?.focus()
          el?.setSelectionRange(el.value.length, el.value.length)
        }}
      >
        <DialogTitle className="sr-only">{t("palette.open")}</DialogTitle>
        {/* icons get the width of the book covers (24 px), so all rows start their text at one x */}
        <Command shouldFilter={false} loop value={selected} onValueChange={setSelected} className="[&_[cmdk-item]>svg]:mx-1">
          <div className="flex items-center border-b eink:border-b-2">
            <CommandInput
              ref={inputRef}
              value={input}
              onValueChange={setInput}
              // the second step: Backspace in the empty input goes back to the commands
              onKeyDown={(e) => {
                if (e.key === "Backspace" && !input && (step || confirm)) {
                  e.preventDefault()
                  back()
                }
              }}
              placeholder={step ? t("actions.pick", { label: commandLabel(step, target) }) : desktop ? t("palette.placeholder") : t("search.placeholder")}
              className="min-w-0"
              wrapperClassName="min-w-0 flex-1 border-b-0 eink:border-b-0"
            />
            {!desktop && (
              <button type="button" onClick={close} aria-label={t("book.close")} className="mr-1 flex size-11 shrink-0 items-center justify-center rounded-md hover:bg-accent eink:size-12">
                <X className="size-5" />
              </button>
            )}
          </div>
          {step || confirm ? (
            <div className="flex items-center gap-2 border-b px-1 py-1 text-sm font-medium eink:border-b-2 eink:text-base">
              <button
                type="button"
                onClick={back}
                onMouseDown={(e) => e.preventDefault()}
                aria-label={t("actions.back")}
                title={t("actions.back")}
                className="flex size-9 shrink-0 items-center justify-center rounded-md hover:bg-accent eink:size-12 touch:size-11"
              >
                <ArrowLeft className="size-4" />
              </button>
              <span className="min-w-0 truncate">{confirm ? commandLabel(confirm.def, target, confirm.value) : commandLabel(step!, target)}</span>
            </div>
          ) : (
            <ScopeChips scope={scope} text={text} onChange={setInput} />
          )}
          <CommandList className="max-h-none flex-1 sm:max-h-[60vh] sm:flex-none">
            <CommandEmpty>{t("palette.empty")}</CommandEmpty>
            {confirm && target && (
              <CommandGroup heading={t("actions.confirmTitle")}>
                {confirm.def.id === "delete" && <p className="px-2 pb-2 text-sm text-muted-foreground eink:text-black">{t("bulk.deleteText")}</p>}
                <CommandItem value="confirm-yes" onSelect={() => runNow(confirm.def, confirm.value)}>
                  {confirm.def.id === "delete" ? <Trash2 /> : <Check />}
                  {confirm.def.id === "delete"
                    ? target.book
                      ? t("actions.confirmDeleteOne", { title: target.book.title })
                      : t("actions.confirmDelete", { count: formatNumber(target.count) })
                    : t("actions.confirmRun", { count: formatNumber(target.count) })}
                </CommandItem>
                <CommandItem value="confirm-no" onSelect={back}>
                  <X />
                  {t("actions.cancel")}
                </CommandItem>
              </CommandGroup>
            )}
            {step && !confirm && !!stepItems.length && (
              <CommandGroup heading={t("actions.values")}>
                {stepItems.map((v) => {
                  const Icon = step.icon
                  return (
                    <CommandItem key={`${v.isNew ? "new:" : v.clear ? "clear:" : ""}${v.value}`} value={`v:${v.isNew ? "new:" : v.clear ? "clear:" : ""}${v.value}`} onSelect={() => start(step, v)}>
                      <Icon />
                      <span className="truncate" style={v.depth ? { paddingLeft: `${v.depth * 1.25}rem` } : undefined}>
                        {v.isNew && !step.free ? t("actions.new", { label: v.label }) : v.label}
                      </span>
                      {v.count != null && v.count > 0 && <CommandShortcut>{formatNumber(v.count)}</CommandShortcut>}
                    </CommandItem>
                  )
                })}
              </CommandGroup>
            )}
            {/* without a prefix, Enter searches the library: full text first */}
            {showFulltext && scope === "all" && fulltext}
            {!!books.data?.books.length && wants("books") && text.length > 1 && (
              <CommandGroup heading={t("palette.books")}>
                {books.data.books.map((b) => (
                  <CommandItem
                    key={`b:${b.id}`}
                    value={`b:${b.id}`}
                    onSelect={() =>
                      closeThen(() => (desktop ? navigate({ to: "/", search: { ...search, book: b.id } }) : navigate({ to: "/books/$id", params: { id: b.id } })))
                    }
                  >
                    <img src={coverUrl(b.id, true, b.lastModified)} alt="" loading="lazy" width={24} height={32} className="h-8 w-6 shrink-0 rounded-xs bg-muted object-cover" />
                    <span className="min-w-0 truncate">
                      {b.title}
                      <span className="text-muted-foreground eink:text-inherit"> · {b.authors.join(", ")}</span>
                    </span>
                  </CommandItem>
                ))}
              </CommandGroup>
            )}
            {!!authors.length && <CommandGroup heading={t("palette.authors")}>{named(authors, <User />, (i) => go(withFilter({}, { author: i.name })), "a")}</CommandGroup>}
            {!!series.length && <CommandGroup heading={t("palette.series")}>{named(series, <BookText />, (i) => go(withFilter({}, { series: i.name })), "s")}</CommandGroup>}
            {!!kategorien.length && <CommandGroup heading={t("palette.kategorie")}>{named(kategorien, <FolderTree />, (i) => go(withFilter({}, { kategorie: i.path })), "k")}</CommandGroup>}
            {!!privateTags.length && <CommandGroup heading={t("palette.privateTags")}>{named(privateTags, <LockKeyhole />, (i) => go(togglePrivateTag({}, i.name)), "p")}</CommandGroup>}
            {!!tags.length && <CommandGroup heading={t("palette.tags")}>{named(tags, <Tag />, (i) => go(toggleTag({}, i.name)), "t")}</CommandGroup>}
            {!!listItems.length && (
              <CommandGroup heading={t("palette.lists")}>
                {named(
                  listItems,
                  (i) => (i.node.list?.rule ? <ListFilter /> : i.node.list ? <ListIcon /> : <Folder />),
                  (i) => go(withFilter({}, nodeSearch(i.node, user))),
                  "l",
                  (i) => !i.node.list,
                )}
              </CommandGroup>
            )}

            {!step && !confirm && !!matchedActions.length && (
              <CommandGroup heading={t("palette.actions")}>
                {matchedActions.map((a) => (
                  <CommandItem key={a.id} value={`>${a.id}`} onSelect={a.run}>
                    {a.icon}
                    {a.label}
                  </CommandItem>
                ))}
              </CommandGroup>
            )}
            {showFulltext && scope !== "all" && fulltext}
          </CommandList>
        </Command>
      </DialogContent>
    </Dialog>
  )
}

const SCOPES: { scope: Scope; prefix: string; label: MessageKey }[] = [
  { scope: "books", prefix: "b ", label: "palette.books" },
  { scope: "authors", prefix: "a ", label: "palette.authors" },
  { scope: "series", prefix: "s ", label: "palette.series" },
  { scope: "tags", prefix: "t ", label: "palette.tags" },
  { scope: "kategorie", prefix: "k ", label: "palette.kategorie" },
  { scope: "lists", prefix: "l ", label: "palette.lists" },
  { scope: "actions", prefix: ">", label: "palette.actions" },
]

// Tappable prefixes: same as typing "a ", "s " … (handy on phones and E-Ink)
function ScopeChips({ scope, text, onChange }: { scope: Scope; text: string; onChange: (input: string) => void }) {
  return (
    <div className="flex gap-1.5 overflow-x-auto border-b px-3 py-2 eink:border-b-2" role="toolbar" aria-label={t("palette.scopes")}>
      {SCOPES.map((s) => {
        const on = scope === s.scope
        return (
          <button
            key={s.scope}
            type="button"
            aria-pressed={on}
            onClick={() => onChange(on ? text : `${s.prefix}${text}`)}
            onMouseDown={(e) => e.preventDefault()}
            className="shrink-0 rounded-full border px-3 py-1 text-sm whitespace-nowrap hover:bg-accent aria-pressed:bg-primary aria-pressed:text-primary-foreground eink:min-h-11 touch:min-h-11 eink:border-2 eink:px-4"
          >
            {t(s.label)}
            <span className="ml-1.5 text-xs opacity-60 eink:opacity-100">{s.prefix.trim()}</span>
          </button>
        )
      })}
    </div>
  )
}
