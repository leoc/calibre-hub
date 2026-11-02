import { useEffect, useMemo, useState, type ReactNode } from "react"
import { useQuery, useQueryClient } from "@tanstack/react-query"
import { useNavigate } from "@tanstack/react-router"
import { ArrowDownUp, Palette, BookText, FolderTree, LayoutGrid, LibraryBig, List, LogOut, Search, Tag, User } from "lucide-react"
import { api, coverUrl, SORTS, type Sort } from "@/lib/api"
import { booksQuery, categoriesQuery } from "@/lib/queries"
import { flattenTree, matchNamed, parseInput, type Scope } from "@/lib/palette"
import { defaultOrder, toggleTag, withFilter } from "@/lib/search"
import { useLibrarySearch } from "@/lib/use-library"
import { setView } from "@/lib/prefs"
import { THEMES, useTheme } from "@/lib/theme"
import { useDesktop } from "@/lib/use-media"
import { formatNumber, t } from "@/i18n"
import { Command, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList, CommandShortcut } from "./ui/command"
import { Dialog, DialogContent, DialogTitle } from "./ui/dialog"

interface Props {
  open: boolean
  onOpenChange: (open: boolean) => void
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

export function CommandPalette({ open, onOpenChange }: Props) {
  const [input, setInput] = useState("")
  const { scope, text } = parseInput(input)
  const debounced = useDebounced(text, 200)
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const search = useLibrarySearch()
  const desktop = useDesktop()
  const { setTheme } = useTheme()
  const { data: cats } = useQuery({ ...categoriesQuery, enabled: open })
  const wants = (s: Scope) => scope === "all" || scope === s
  const books = useQuery({
    ...booksQuery({ q: debounced, limit: 8, sort: "title" }),
    enabled: open && wants("books") && debounced.length > 1,
  })

  const close = () => onOpenChange(false)
  const go = (s: Parameters<typeof withFilter>[0]) => {
    close()
    navigate({ to: "/", search: s })
  }

  const actions: Action[] = useMemo(
    () => [
      { id: "all", label: t("nav.all"), icon: <LibraryBig />, run: () => go({}) },
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
    [search],
  )

  const limit = scope === "all" ? 5 : 30
  const authors = cats && wants("authors") ? matchNamed(cats.authors, text, limit) : []
  const series = cats && wants("series") ? matchNamed(cats.series, text, limit) : []
  const tags = cats && wants("tags") ? matchNamed(cats.tags, text, limit) : []
  const kategorien = cats && wants("kategorie") ? matchNamed(flattenTree(cats.kategorie), text, limit) : []
  const matchedActions =
    scope === "actions" || (scope === "all" && text)
      ? actions.filter((a) => a.label.toLowerCase().includes(text.toLowerCase())).slice(0, scope === "all" ? 4 : undefined)
      : []
  const showFulltext = (scope === "all" || scope === "books") && text.length > 0

  const named = (items: { name: string; count: number }[], icon: ReactNode, onPick: (n: string) => void, prefix: string) =>
    items.map((i) => (
      <CommandItem key={`${prefix}:${i.name}`} value={`${prefix}:${i.name}`} onSelect={() => onPick(i.name)}>
        {icon}
        <span className="truncate">{i.name}</span>
        <CommandShortcut>{formatNumber(i.count)}</CommandShortcut>
      </CommandItem>
    ))

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="overflow-hidden p-0 sm:max-w-2xl" showClose={false} aria-describedby={undefined}>
        <DialogTitle className="sr-only">{t("palette.open")}</DialogTitle>
        <Command shouldFilter={false} loop>
          <CommandInput value={input} onValueChange={setInput} placeholder={t("palette.placeholder")} />
          <CommandList>
            <CommandEmpty>{t("palette.empty")}</CommandEmpty>
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
            {!!authors.length && <CommandGroup heading={t("palette.authors")}>{named(authors, <User />, (n) => go(withFilter({}, { author: n })), "a")}</CommandGroup>}
            {!!series.length && <CommandGroup heading={t("palette.series")}>{named(series, <BookText />, (n) => go(withFilter({}, { series: n })), "s")}</CommandGroup>}
            {!!kategorien.length && <CommandGroup heading={t("palette.kategorie")}>{named(kategorien, <FolderTree />, (n) => go(withFilter({}, { kategorie: n })), "k")}</CommandGroup>}
            {!!tags.length && <CommandGroup heading={t("palette.tags")}>{named(tags, <Tag />, (n) => go(toggleTag({}, n)), "t")}</CommandGroup>}
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
            {showFulltext && (
              <CommandGroup>
                <CommandItem value="fulltext" onSelect={() => go(withFilter({}, { q: text }))}>
                  <Search />
                  {t("palette.fulltext", { q: text })}
                </CommandItem>
              </CommandGroup>
            )}
          </CommandList>
        </Command>
      </DialogContent>
    </Dialog>
  )
}
