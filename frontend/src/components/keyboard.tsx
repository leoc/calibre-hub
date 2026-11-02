import { useEffect, useMemo, useRef } from "react"
import { useNavigate } from "@tanstack/react-router"
import { Keyboard } from "lucide-react"
import type { Book } from "@/lib/api"
import { defaultBindings, eventToken, KeyEngine, MODES } from "@/lib/keymap"
import { activateWhenLoaded, bookElement, keyboard, registerList, runListAction, useKeyboard } from "@/lib/keyboard"
import type { LibrarySearch } from "@/lib/search"
import { selection, useSelection } from "@/lib/selection"
import { t } from "@/i18n"
import { cn } from "@/lib/utils"

// Keys only act outside text fields and while no dialog is open; the book
// detail panel lets them through (j/k go to the next book there).
const isTyping = (el: EventTarget | null) =>
  el instanceof HTMLElement && (el.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName))
const dialogOpen = () => !!document.querySelector('[role="dialog"]:not([data-keys="pass"]), [role="alertdialog"]')
// Enter and Space keep their own meaning on buttons and links, except on the books
const ACTIVATING = new Set(["<Enter>", "<Space>"])
const onControl = (el: EventTarget | null) =>
  el instanceof Element &&
  !el.closest("[data-book-id]") &&
  !!el.closest('a, button, summary, label, [role="button"], [role="checkbox"], [role="radio"], [role="option"], [role="tab"], [role="menuitem"], [role="switch"]')

// The one keydown listener for the app: turns keys into actions, global
// ones here, the list's in the library page (useListKeys).
export function KeyboardHost({ onSearch, onCommands }: { onSearch: () => void; onCommands: () => void }) {
  const { mode, visual, pending } = useKeyboard()
  const engine = useMemo(() => new KeyEngine(defaultBindings(mode), mode === "vim"), [mode])
  const handlers = useRef({ onSearch, onCommands })
  useEffect(() => {
    handlers.current = { onSearch, onCommands }
  })

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.defaultPrevented || e.isComposing || isTyping(e.target) || dialogOpen()) return
      const token = eventToken(e)
      if (!token) return
      if (ACTIVATING.has(token) && onControl(e.target)) return
      if (token === "<Esc>") {
        // Escape drops a half-typed command first
        const dropped = !!engine.pending
        engine.reset()
        keyboard.setPending("")
        if (dropped || runListAction("escape", null, e)) e.preventDefault()
        return
      }
      const r = engine.feed(token)
      keyboard.setPending(engine.pending)
      if (r.type === "pending") return e.preventDefault()
      if (r.type === "none") return
      const done = (() => {
        switch (r.action) {
          case "search":
            handlers.current.onSearch()
            return true
          case "commands":
            handlers.current.onCommands()
            return true
          default:
            return runListAction(r.action, r.count, e)
        }
      })()
      if (done) e.preventDefault()
    }
    window.addEventListener("keydown", onKey)
    return () => window.removeEventListener("keydown", onKey)
  }, [engine])

  // drop a half-typed command when the mode changes
  useEffect(() => () => void keyboard.setPending(""), [engine])

  if (mode !== "vim" || (!visual && !pending)) return null
  return (
    // top right under the header, clear of the bulk bar at the bottom
    <div
      role="status"
      aria-label={t("keys.status")}
      className="fixed top-[4.25rem] right-4 z-40 rounded-md border bg-background px-3 py-1.5 font-mono text-sm shadow-md eink:border-2 eink:border-black eink:text-base eink:shadow-none"
    >
      {visual && <span className="font-semibold">{t("keys.visual")}</span>}
      {visual && pending && " "}
      {pending}
    </div>
  )
}

// --- the library's keys -----------------------------------------------------------

// Books per row: the ones on the first row's line (1 in the list view).
function layout() {
  const els = [...document.querySelectorAll<HTMLElement>("main [data-book-id]")]
  if (els.length < 2) return { cols: 1, rows: 1 }
  const top = els[0].getBoundingClientRect().top
  let cols = 0
  while (cols < els.length && Math.abs(els[cols].getBoundingClientRect().top - top) < 4) cols++
  const rowHeight = cols < els.length ? els[cols].getBoundingClientRect().top - top : els[0].offsetHeight
  return { cols: Math.max(1, cols), rows: Math.max(1, Math.floor(window.innerHeight / Math.max(1, rowHeight))) }
}

// Bring the active book into view and give it the focus, after React has
// rendered (selection mode swaps links for checkboxes).
function showActive() {
  requestAnimationFrame(() => {
    const id = keyboard.get().active
    const el = id != null ? bookElement(id) : null
    if (!el || dialogOpen()) return
    el.focus()
  })
}

interface ListProps {
  books: Book[] | undefined
  search: LibrarySearch
  page: number
  pages: number
}

export function useListKeys(props: ListProps) {
  const navigate = useNavigate()
  const latest = useRef(props)
  useEffect(() => {
    latest.current = props
  })
  // ending the selection (bulk bar X) ends visual mode too
  const { active: selecting } = useSelection()
  useEffect(() => {
    if (!selecting && keyboard.get().visual) keyboard.setVisual(null)
  }, [selecting])

  useEffect(
    () =>
      registerList((action, count) => {
        const { books, search, page, pages } = latest.current
        const detailOpen = search.book != null
        // the edit form owns the keys
        if (search.edit) return false
        const n = count ?? 1

        if (action === "nextPage" || action === "prevPage") {
          const to = Math.min(pages, Math.max(1, page + (action === "nextPage" ? n : -n)))
          if (to === page) return true
          keyboard.setVisual(null)
          activateWhenLoaded({ at: "first", focus: true, when: (s) => (s.page ?? 1) === to })
          navigate({ to: "/", search: { ...search, page: to > 1 ? to : undefined, book: undefined, edit: undefined } })
          return true
        }
        if (!books?.length) return false
        const ids = books.map((b) => b.id)
        const kb = keyboard.get()
        const sel = selection.get()
        const cur = kb.active != null ? ids.indexOf(kb.active) : -1
        const activate = (i: number) => {
          const id = ids[i]
          keyboard.setActive(id)
          const visual = keyboard.get().visual
          if (visual) {
            const [a, b] = [ids.indexOf(visual.anchor), i].sort((x, y) => x - y)
            selection.replace([...new Set([...visual.base, ...(a < 0 ? [id] : ids.slice(a, b + 1))])])
          }
          // the open detail follows the active book
          if (detailOpen) navigate({ to: "/", search: { ...search, book: id }, replace: true })
          else showActive()
        }

        switch (action) {
          case "escape":
            if (detailOpen) return false
            if (kb.visual) keyboard.setVisual(null)
            else if (sel.ids.size || sel.all) selection.clear()
            else if (sel.active) selection.stop()
            else return false
            showActive()
            return true
          case "selectAll":
            selection.start()
            selection.addPage(ids)
            showActive()
            return true
        }

        // everything else starts from the active book; the first key press picks one
        if (cur < 0) {
          activate(action === "last" ? ids.length - 1 : 0)
          if (action === "toggleSelect") {
            selection.start()
            selection.toggle(ids[0], false, ids)
          }
          return true
        }

        // in the open detail the books follow one another: j/k is next/previous
        const { cols, rows } = detailOpen ? { cols: 1, rows: 2 } : layout()
        // up/down: as many rows as there are, never sideways out of the column
        const vertical = (step: number) => {
          for (let k = n; k > 0; k--) {
            const to = cur + step * k
            if (to >= 0 && to < ids.length) return to
            // a shorter last row: its last book
            if (step > 0 && Math.floor((ids.length - 1) / cols) > Math.floor(cur / cols) && k === 1) return ids.length - 1
          }
          return cur
        }
        const clamp = (i: number) => Math.min(ids.length - 1, Math.max(0, i))

        switch (action) {
          case "down":
          case "extendDown":
            activate(vertical(cols))
            break
          case "up":
          case "extendUp":
            activate(vertical(-cols))
            break
          case "left":
          case "extendLeft":
            activate(clamp(cur - n))
            break
          case "right":
          case "extendRight":
            activate(clamp(cur + n))
            break
          case "halfDown":
            activate(clamp(cur + cols * Math.max(1, Math.floor(rows / 2)) * n))
            break
          case "halfUp":
            activate(clamp(cur - cols * Math.max(1, Math.floor(rows / 2)) * n))
            break
          case "first":
            activate(0)
            break
          case "last":
            activate(ids.length - 1)
            break
          case "open":
            navigate({ to: "/", search: { ...search, book: ids[cur], edit: undefined } })
            return true
          case "toggleSelect":
            selection.start()
            selection.toggle(ids[cur], false, ids)
            showActive()
            return true
          case "visual":
            if (kb.visual) {
              keyboard.setVisual(null)
              return true
            }
            selection.start()
            keyboard.setVisual({ anchor: ids[cur], base: [...sel.ids] })
            selection.replace([...new Set([...sel.ids, ids[cur]])])
            showActive()
            return true
          default:
            return false
        }
        if (action.startsWith("extend")) {
          const anchor = sel.anchor != null && ids.includes(sel.anchor) ? sel.anchor : ids[cur]
          selection.start()
          selection.addRange(anchor, keyboard.get().active!, ids)
          showActive()
        }
        return true
      }),
    [navigate],
  )
}

// Segmented like the theme switch: App or Vim keys, per device.
export function KeyboardSwitch({ className }: { className?: string }) {
  const { mode } = useKeyboard()
  return (
    <div role="radiogroup" aria-label={t("keys.label")} className={cn("grid grid-cols-[auto_1fr_1fr] items-center gap-1 rounded-md border p-1 eink:border-2", className)}>
      <Keyboard className="mx-1.5 size-4" aria-hidden />
      {MODES.map((m) => (
        <button
          key={m}
          role="radio"
          aria-checked={mode === m}
          onClick={() => keyboard.setMode(m)}
          className="rounded-sm px-1 py-1 text-xs hover:bg-accent aria-checked:bg-primary aria-checked:text-primary-foreground eink:min-h-12 touch:min-h-11 eink:text-sm"
        >
          {t(`keys.${m}`)}
        </button>
      ))}
    </div>
  )
}
