import { useEffect, useMemo, useRef, useState, type ReactNode } from "react"
import { useQuery, useQueryClient } from "@tanstack/react-query"
import { useNavigate } from "@tanstack/react-router"
import { ArrowDownUp, Bookmark, Palette, Pencil, X, BookText, FolderTree, LayoutGrid, LibraryBig, List, LogOut, Search, Sparkles, Tag, Trash2, User } from "lucide-react"
import { api, coverUrl, DEFAULT_CONFIG, SORTS, type Book, type Sort } from "@/lib/api"
import { booksQuery, categoriesQuery, configQuery } from "@/lib/queries"
import { useToggleTag } from "@/lib/mutations"
import { matchNamed, parseInput, type Scope } from "@/lib/palette"
import { categorySuggestions } from "@/lib/kategorie"
import { defaultOrder, toggleTag, withFilter } from "@/lib/search"
import { useLibrarySearch } from "@/lib/use-library"
import { setView } from "@/lib/prefs"
import { THEMES, useTheme } from "@/lib/theme"
import { useDesktop } from "@/lib/use-media"
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
  const wants = (s: Scope) => scope === "all" || scope === s
  const books = useQuery({
    ...booksQuery({ q: debounced, limit: 8, sort: "title" }),
    enabled: open && wants("books") && debounced.length > 1,
  })

  const close = onClose
  const go = (s: Parameters<typeof withFilter>[0]) => {
    close()
    navigate({ to: "/", search: s })
  }

  const { data: config = DEFAULT_CONFIG } = useQuery(configQuery)
  const toggleFast = useToggleTag()
  // the book open in the detail, if any
  const openBook = search.book != null ? queryClient.getQueryData<Book>(["book", search.book]) : undefined
  const bookActions: Action[] = openBook
    ? [
        ...config.fastTags.map((tag) => {
          const on = openBook.tags.includes(tag)
          return {
            id: `fast-${tag}`,
            label: on ? t("fast.remove", { tag }) : t("fast.add", { tag }),
            icon: <Bookmark />,
            run: () => {
              toggleFast.mutate({ book: openBook, tag, on: !on })
              close()
            },
          }
        }),
        { id: "edit", label: `${t("book.edit")}: ${openBook.title}`, icon: <Pencil />, run: () => go({ ...search, edit: true }) },
      ]
    : []

  const actions: Action[] = useMemo(
    () => [
      { id: "all", label: t("nav.all"), icon: <LibraryBig />, run: () => go({}) },
      { id: "trash", label: t("trash.title"), icon: <Trash2 />, run: () => (close(), navigate({ to: "/trash" })) },
      ...(config.classify
        ? [{ id: "suggestions", label: t("suggest.title"), icon: <Sparkles />, run: () => (close(), navigate({ to: "/suggestions" })) }]
        : []),
      { id: "grid", label: t("view.grid"), icon: <LayoutGrid />, run: () => (setView("grid"), close()) },
      { id: "list", label: t("view.list"), icon: <List />, run: () => (setView("list"), close()) },
      ...THEMES.map((th) => ({ id: `theme-${th}`, label: `${t("theme.label")}: ${t(`theme.${th}`)}`, icon: <Palette />, run: () => (setTheme(th), close()) })),
      ...SORTS.map((s: Sort) => ({
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
    [search, config.classify],
  )

  const limit = scope === "all" ? 5 : 30
  const authors = cats && wants("authors") ? matchNamed(cats.authors, text, limit) : []
  const series = cats && wants("series") ? matchNamed(cats.series, text, limit) : []
  const tags = cats && wants("tags") ? matchNamed(cats.tags, text, limit) : []
  // shown and matched as "A/B"
  const kategorien = cats && wants("kategorie") ? matchNamed(categorySuggestions(cats.kategorie), text, limit) : []
  const matchedActions =
    scope === "actions" || (scope === "all" && text)
      ? [...bookActions, ...actions].filter((a) => a.label.toLowerCase().includes(text.toLowerCase())).slice(0, scope === "all" ? 4 : undefined)
      : []
  const showFulltext = (scope === "all" || scope === "books") && text.length > 0

  const fulltext = (
    <CommandGroup>
      <CommandItem value="fulltext" onSelect={() => go(withFilter({}, { q: text }))}>
        <Search />
        {t("palette.fulltext", { q: text })}
      </CommandItem>
    </CommandGroup>
  )

  const named = <T extends { name: string; count: number }>(items: T[], icon: ReactNode, onPick: (i: T) => void, prefix: string) =>
    items.map((i) => (
      <CommandItem key={`${prefix}:${i.name}`} value={`${prefix}:${i.name}`} onSelect={() => onPick(i)}>
        {icon}
        <span className="truncate">{i.name}</span>
        <CommandShortcut>{formatNumber(i.count)}</CommandShortcut>
      </CommandItem>
    ))

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent
        className="top-0 h-dvh w-full max-w-none translate-x-[-50%] overflow-hidden rounded-none border-0 p-0 sm:top-[10vh] sm:h-auto sm:w-[calc(100%-2rem)] sm:max-w-2xl sm:rounded-lg sm:border"
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
        <Command shouldFilter={false} loop>
          <div className="flex items-center border-b eink:border-b-2">
            <CommandInput
              ref={inputRef}
              value={input}
              onValueChange={setInput}
              placeholder={desktop ? t("palette.placeholder") : t("search.placeholder")}
              className="min-w-0"
              wrapperClassName="min-w-0 flex-1 border-b-0 eink:border-b-0"
            />
            {!desktop && (
              <button type="button" onClick={close} aria-label={t("book.close")} className="mr-1 shrink-0 rounded-md p-2 hover:bg-accent eink:p-3">
                <X className="size-5" />
              </button>
            )}
          </div>
          <ScopeChips scope={scope} text={text} onChange={setInput} />
          <CommandList className="max-h-none flex-1 sm:max-h-[60vh] sm:flex-none">
            <CommandEmpty>{t("palette.empty")}</CommandEmpty>
            {/* without a prefix, Enter searches the library: full text first */}
            {showFulltext && scope === "all" && fulltext}
            {!!books.data?.books.length && wants("books") && text.length > 1 && (
              <CommandGroup heading={t("palette.books")}>
                {books.data.books.map((b) => (
                  <CommandItem
                    key={`b:${b.id}`}
                    value={`b:${b.id}`}
                    onSelect={() => {
                      close()
                      if (desktop) navigate({ to: "/", search: { ...search, book: b.id } })
                      else navigate({ to: "/books/$id", params: { id: b.id } })
                    }}
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
            {!!tags.length && <CommandGroup heading={t("palette.tags")}>{named(tags, <Tag />, (i) => go(toggleTag({}, i.name)), "t")}</CommandGroup>}
            {!!matchedActions.length && (
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
            className="shrink-0 rounded-full border px-3 py-1 text-sm whitespace-nowrap hover:bg-accent aria-pressed:bg-primary aria-pressed:text-primary-foreground eink:min-h-11 eink:border-2 eink:px-4"
          >
            {t(s.label)}
            <span className="ml-1.5 text-xs opacity-60 eink:opacity-100">{s.prefix.trim()}</span>
          </button>
        )
      })}
    </div>
  )
}
