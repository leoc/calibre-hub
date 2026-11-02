import { useEffect, useRef, useState } from "react"
import { Outlet } from "@tanstack/react-router"
import { useQueryClient } from "@tanstack/react-query"
import { BookOpen, Command, LogOut, Menu, Search, X } from "lucide-react"
import { api } from "@/lib/api"
import { useDesktop, useMedia } from "@/lib/use-media"
import { parseInput } from "@/lib/palette"
import { cn } from "@/lib/utils"
import { useGoLibrary, useLibrarySearch } from "@/lib/use-library"
import { withFilter } from "@/lib/search"
import { t } from "@/i18n"
import { Button } from "./ui/button"
import { Sheet, SheetContent, SheetTitle } from "./ui/sheet"
import { Sidebar } from "./sidebar"
import { CommandPalette } from "./command-palette"
import { EinkSuggestion } from "./theme-switch"
import { UploadButton, UploadHost } from "./upload"
import { LibraryLink } from "@/components/library-link"

export function AppShell() {
  const desktop = useDesktop()
  const search = useLibrarySearch()
  const searchRef = useRef(search)
  useEffect(() => {
    searchRef.current = search
  })
  const [menuOpen, setMenuOpen] = useState(false)
  // null = closed, otherwise the text the palette starts with
  const [palette, setPaletteState] = useState<string | null>(null)
  // focus goes back where it came from (e.g. the search bar after a prefix)
  const returnFocus = useRef<HTMLElement | null>(null)
  const setPalette = (next: string | null | ((p: string | null) => string | null)) =>
    setPaletteState((prev) => {
      const value = typeof next === "function" ? next(prev) : next
      if (prev === null && value !== null) returnFocus.current = document.activeElement as HTMLElement | null
      return value
    })
  const closePalette = () => {
    setPaletteState(null)
    const el = returnFocus.current
    // after the dialog has unmounted
    setTimeout(() => el?.isConnected && el.focus(), 0)
  }

  // Ctrl/Cmd+K anywhere, "/" outside text fields
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const typing = e.target instanceof HTMLElement && (e.target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(e.target.tagName))
      if ((e.key === "k" && (e.ctrlKey || e.metaKey)) || (e.key === "/" && !typing && !e.ctrlKey && !e.metaKey && !e.altKey)) {
        e.preventDefault()
        setPalette((p) => (p === null ? (searchRef.current.q ?? "") : null))
      }
    }
    window.addEventListener("keydown", onKey)
    return () => window.removeEventListener("keydown", onKey)
  }, [])

  return (
    <div className="flex min-h-full flex-col">
      <EinkSuggestion />
      <header className="sticky top-0 z-30 flex h-14 shrink-0 items-center gap-2 border-b bg-background px-3 eink:h-16 eink:border-b-2">
        {!desktop && (
          <Button variant="ghost" size="icon" onClick={() => setMenuOpen(true)} aria-label={t("nav.menu")}>
            <Menu className="size-5" />
          </Button>
        )}
        <LibraryLink search={{}} className="hidden items-center gap-2 font-semibold sm:flex lg:w-60" aria-label={t("app.title")}>
          <BookOpen className="size-5" aria-hidden />
          <span className="hidden sm:inline">{t("app.title")}</span>
        </LibraryLink>
        <HeaderSearch value={search.q ?? ""} onOpenPalette={setPalette} />
        <UploadButton />
        <LogoutButton />
      </header>
      <div className="flex flex-1">
        {desktop ? (
          <aside className="sticky top-14 h-[calc(100dvh-3.5rem)] w-64 shrink-0 border-r bg-sidebar eink:top-16 eink:h-[calc(100dvh-4rem)] eink:border-r-2">
            <Sidebar search={search} />
          </aside>
        ) : (
          <Sheet open={menuOpen} onOpenChange={setMenuOpen}>
            <SheetContent side="left" aria-describedby={undefined}>
              <SheetTitle className="sr-only">{t("nav.menu")}</SheetTitle>
              <div className="h-full pt-10">
                <Sidebar search={search} onNavigate={() => setMenuOpen(false)} />
              </div>
            </SheetContent>
          </Sheet>
        )}
        <main className="min-w-0 flex-1" id="main">
          <Outlet />
        </main>
      </div>
      <UploadHost />
      {/* mounted only while open, so the input starts empty each time */}
      {palette !== null && <CommandPalette initialInput={palette} onClose={closePalette} />}
    </div>
  )
}

// Wide screens: a real search field that filters the library live; a
// prefix ("a ", "s ", ">" …) at the start hands the text to the palette.
// Narrow screens: looks like a search field, opens the palette.
function HeaderSearch({ value, onOpenPalette }: { value: string; onOpenPalette: (input: string) => void }) {
  const wide = useMedia("(min-width: 640px)")
  return wide ? <WideSearch value={value} onOpenPalette={onOpenPalette} /> : <NarrowSearch value={value} onOpenPalette={onOpenPalette} />
}

const searchBox =
  "h-9 w-full rounded-md border bg-transparent pl-8 text-base outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50 md:text-sm eink:h-12 eink:border-2 eink:text-lg"

function WideSearch({ value, onOpenPalette }: { value: string; onOpenPalette: (input: string) => void }) {
  const [text, setText] = useState(value)
  const [shown, setShown] = useState(value)
  const go = useGoLibrary()
  const search = useLibrarySearch()
  const timer = useRef<ReturnType<typeof setTimeout>>(undefined)

  // follow URL changes from elsewhere (back button, palette, chips)
  if (value !== shown) {
    setShown(value)
    setText(value)
  }

  useEffect(() => () => clearTimeout(timer.current), [])

  const change = (next: string) => {
    clearTimeout(timer.current)
    if (parseInput(next).scope !== "all") {
      // the prefix never reaches the library search; Escape in the palette
      // comes back to the field as it was
      setText(value)
      onOpenPalette(next)
      return
    }
    setText(next)
    timer.current = setTimeout(() => {
      // one history entry per search, refinements replace it
      go(withFilter(search, { q: next || undefined }), { replace: !!search.q && !!next })
    }, 300)
  }

  return (
    <div className="relative flex max-w-xl min-w-0 flex-1 items-center">
      <Search className="pointer-events-none absolute left-2.5 size-4 text-muted-foreground eink:text-black" aria-hidden />
      <input
        type="search"
        value={text}
        onChange={(e) => change(e.target.value)}
        placeholder={t("search.placeholder")}
        aria-label={t("search.placeholder")}
        className={cn(searchBox, "pr-20 [&::-webkit-search-cancel-button]:hidden")}
      />
      <div className="absolute right-1 flex items-center gap-0.5">
        {text && (
          <button onClick={() => change("")} aria-label={t("search.clear")} className="rounded-sm p-1.5 hover:bg-accent eink:p-2.5">
            <X className="size-4" />
          </button>
        )}
        <button
          onClick={() => onOpenPalette(text)}
          aria-label={t("palette.button")}
          title={t("palette.button")}
          className="flex items-center gap-1 rounded-sm border px-1.5 py-0.5 text-xs text-muted-foreground hover:bg-accent eink:border-2 eink:px-2.5 eink:py-1.5 eink:text-sm eink:text-black"
        >
          <Command className="size-3.5" aria-hidden />K
        </button>
      </div>
    </div>
  )
}

function NarrowSearch({ value, onOpenPalette }: { value: string; onOpenPalette: (input: string) => void }) {
  const go = useGoLibrary()
  const search = useLibrarySearch()
  return (
    <div className="relative flex min-w-0 flex-1 items-center">
      <button
        type="button"
        onClick={() => onOpenPalette(value)}
        aria-label={t("search.placeholder")}
        aria-haspopup="dialog"
        className={cn(searchBox, "flex min-w-0 items-center pr-10 text-left")}
      >
        <Search className="pointer-events-none absolute left-2.5 size-4 text-muted-foreground eink:text-black" aria-hidden />
        <span className={value ? "truncate" : "truncate text-muted-foreground"}>{value || t("search.placeholder")}</span>
      </button>
      {value && (
        <button onClick={() => go(withFilter(search, { q: undefined }))} aria-label={t("search.clear")} className="absolute right-1 rounded-sm p-1.5 hover:bg-accent eink:p-2.5">
          <X className="size-4" />
        </button>
      )}
    </div>
  )
}

function LogoutButton() {
  const queryClient = useQueryClient()
  return (
    <Button
      variant="ghost"
      size="icon"
      aria-label={t("logout")}
      title={t("logout")}
      onClick={async () => {
        await api.logout().catch(() => undefined)
        queryClient.clear()
        window.location.href = "/login"
      }}
    >
      <LogOut className="size-5" />
    </Button>
  )
}
