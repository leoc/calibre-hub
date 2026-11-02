import { useEffect, useRef, useState } from "react"
import { Outlet } from "@tanstack/react-router"
import { useQueryClient } from "@tanstack/react-query"
import { BookOpen, LogOut, Menu, Search, X } from "lucide-react"
import { api } from "@/lib/api"
import { useDesktop } from "@/lib/use-media"
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
  const [menuOpen, setMenuOpen] = useState(false)
  const [paletteOpen, setPaletteOpen] = useState(false)

  // Ctrl/Cmd+K anywhere, "/" outside text fields
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const typing = e.target instanceof HTMLElement && (e.target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(e.target.tagName))
      if ((e.key === "k" && (e.ctrlKey || e.metaKey)) || (e.key === "/" && !typing && !e.ctrlKey && !e.metaKey && !e.altKey)) {
        e.preventDefault()
        setPaletteOpen((o) => !o)
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
        <HeaderSearch value={search.q ?? ""} onOpenPalette={() => setPaletteOpen(true)} />
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
      {paletteOpen && <CommandPalette open onOpenChange={setPaletteOpen} />}
    </div>
  )
}

// Live search: updates the URL 300 ms after typing stops.
function HeaderSearch({ value, onOpenPalette }: { value: string; onOpenPalette: () => void }) {
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
    setText(next)
    clearTimeout(timer.current)
    timer.current = setTimeout(() => {
      // one history entry per search, refinements replace it
      go(withFilter(search, { q: next || undefined }), { replace: !!search.q && !!next })
    }, 300)
  }

  return (
    <div className="relative flex max-w-xl flex-1 items-center">
      <Search className="pointer-events-none absolute left-2.5 size-4 text-muted-foreground eink:text-black" aria-hidden />
      <input
        type="search"
        value={text}
        onChange={(e) => change(e.target.value)}
        placeholder={t("search.placeholder")}
        aria-label={t("search.placeholder")}
        className="h-9 w-full rounded-md border bg-transparent pr-16 pl-8 text-base outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50 md:text-sm eink:h-12 eink:border-2 eink:text-lg [&::-webkit-search-cancel-button]:hidden"
      />
      <div className="absolute right-1 flex items-center">
        {text && (
          <button onClick={() => change("")} aria-label={t("search.clear")} className="rounded-sm p-1.5 hover:bg-accent eink:p-2.5">
            <X className="size-4" />
          </button>
        )}
        <button
          onClick={onOpenPalette}
          aria-label={t("palette.open")}
          className="hidden rounded-sm border px-1.5 text-xs text-muted-foreground hover:bg-accent sm:block eink:text-black"
        >
          ⌘K
        </button>
      </div>
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
