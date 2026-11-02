import { useEffect, useMemo, useRef, useState, type ReactNode } from "react"
import { useNavigate } from "@tanstack/react-router"
import { useQuery, useQueryClient } from "@tanstack/react-query"
import { Keyboard, Settings2 } from "lucide-react"
import { DEFAULT_CONFIG, downloadUrl, type Book, type ReadingList } from "@/lib/api"
import { configQuery } from "@/lib/queries"
import { defaultList, inList, lastUsedList, listLabel, listsQuery, offerUndoRemove, saveDialog, useBulkList, useListMembership } from "@/lib/lists"
import { eventToken, KeyEngine, MODES, type Action } from "@/lib/keymap"
import { activateWhenLoaded, bookElement, focusActive, keyboard, registerList, runListAction, useKeyboard } from "@/lib/keyboard"
import { bulkTarget, type LibrarySearch } from "@/lib/search"
import { requestBulk, selection, useSelection } from "@/lib/selection"
import { formatNumber, t } from "@/i18n"
import { cn } from "@/lib/utils"
import { sortFormats } from "./book-detail"
import { DeleteBookDialog } from "./delete-book"
import { collectHints, HelpPanel, HintLayer, SettingsPanel, type Hints } from "./keyboard-panels"

// Keys only act outside text fields and while no dialog is open; the book
// detail panel lets them through (j/k go to the next book there).
const isTyping = (el: EventTarget | null) =>
  el instanceof HTMLElement && (el.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName))
export const dialogOpen = () => !!document.querySelector('[role="dialog"]:not([data-keys="pass"]), [role="alertdialog"]')
// Enter and Space keep their own meaning on buttons and links, except on the books
const ACTIVATING = new Set(["<Enter>", "<Space>"])
const onControl = (el: EventTarget | null) =>
  el instanceof Element &&
  !el.closest("[data-book-id]") &&
  !!el.closest('a, button, summary, label, [role="button"], [role="checkbox"], [role="radio"], [role="option"], [role="tab"], [role="menuitem"], [role="switch"]')

// The one keydown listener for the app: turns keys into actions, global
// ones here, the list's in the library page (useListKeys).
export function KeyboardHost({ onSearch, onCommands }: { onSearch: () => void; onCommands: () => void }) {
  const { mode, visual, pending, overrides, panel, flash } = useKeyboard()
  const navigate = useNavigate()
  const { data: config = DEFAULT_CONFIG } = useQuery(configQuery)
  const engine = useMemo(
    () => new KeyEngine(keyboard.bindings(mode), mode === "vim"),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [mode, overrides],
  )
  const [hints, setHints] = useState<Hints | null>(null)
  const latest = useRef({ onSearch, onCommands, navigate, config, hints })
  useEffect(() => {
    latest.current = { onSearch, onCommands, navigate, config, hints }
  })

  // hint mode ends when the page moves under the labels
  useEffect(() => {
    if (!hints) return
    const cancel = () => setHints(null)
    window.addEventListener("scroll", cancel, true)
    window.addEventListener("resize", cancel)
    return () => {
      window.removeEventListener("scroll", cancel, true)
      window.removeEventListener("resize", cancel)
    }
  }, [hints])

  useEffect(() => {
    const global = (action: Action, count: number | null, e: KeyboardEvent): boolean => {
      const { navigate, config } = latest.current
      switch (action) {
        case "search":
          latest.current.onSearch()
          return true
        case "commands":
          latest.current.onCommands()
          return true
        case "help":
          keyboard.setPanel("help")
          return true
        case "back":
          history.back()
          return true
        case "forward":
          history.forward()
          return true
        case "goLibrary":
          navigate({ to: "/" })
          return true
        case "goTrash":
          navigate({ to: "/trash" })
          return true
        case "goMetadata":
          if (!config.metadata) return false
          navigate({ to: "/metadata" })
          return true
        case "goSuggestions":
          if (!config.classify) return false
          navigate({ to: "/suggestions" })
          return true
        case "goCategories":
          return focusTree()
        case "goLists":
          navigate({ to: "/lists" })
          return true
        case "saveLast":
        case "saveDialog":
          // never the browser's "save page", also where there are no books
          if (!runListAction(action, count, e)) keyboard.flash(t("keys.noBook"))
          return true
        case "hints":
        case "hintsSelect": {
          const list = collectHints()
          if (!list.length) return false
          setHints({ list, typed: "", select: action === "hintsSelect" })
          return true
        }
        default:
          return runListAction(action, count, e)
      }
    }

    const onKey = (e: KeyboardEvent) => {
      if (latest.current.hints) return hintKey(e)
      if (e.defaultPrevented || e.isComposing || isTyping(e.target) || dialogOpen()) return
      const token = eventToken(e)
      if (!token) return
      if (ACTIVATING.has(token) && onControl(e.target)) return
      if (token === "<Esc>") {
        // Escape drops a half-typed command first, then leaves the tree, then the list's turn
        const dropped = !!engine.pending
        engine.reset()
        keyboard.setPending("")
        if (dropped || leaveTree(e.target) || runListAction("escape", null, e)) e.preventDefault()
        return
      }
      const r = engine.feed(token)
      keyboard.setPending(engine.pending)
      if (r.type === "pending") return e.preventDefault()
      if (r.type === "none") return
      const done = treeKey(r.action, e.target) || global(r.action, r.count, e)
      if (done) e.preventDefault()
    }

    // Hint mode takes every key: letters narrow the labels down, Backspace
    // takes one back, anything else (Escape) ends it.
    const hintKey = (e: KeyboardEvent) => {
      const h = latest.current.hints!
      if (e.ctrlKey || e.metaKey || e.altKey || /^(Shift|Control|Alt|Meta|CapsLock)$/.test(e.key)) return
      e.preventDefault()
      e.stopPropagation()
      if (e.key === "Backspace") return setHints({ ...h, typed: h.typed.slice(0, -1) })
      const typed = h.typed + e.key.toLowerCase()
      const left = e.key.length === 1 ? h.list.filter((x) => x.label.startsWith(typed)) : []
      if (!left.length) return setHints(null)
      const hit = left.find((x) => x.label === typed)
      if (!hit) return setHints({ ...h, typed })
      setHints(null)
      if (hit.book != null) {
        keyboard.setActive(hit.book)
        runListAction(h.select ? "toggleSelect" : "open", null, e)
      } else if (h.select && hit.el instanceof HTMLAnchorElement && hit.el.href) {
        window.open(hit.el.href, "_blank", "noopener")
      } else {
        hit.el.focus()
        hit.el.click()
      }
    }

    window.addEventListener("keydown", onKey)
    return () => window.removeEventListener("keydown", onKey)
  }, [engine])

  // drop a half-typed command when the bindings change
  useEffect(() => () => void keyboard.setPending(""), [engine])

  const status: ReactNode = hints ? (
    <>
      {t("keys.hints")} {hints.typed}
    </>
  ) : flash ? (
    flash
  ) : mode === "vim" && (visual || pending) ? (
    <>
      {visual && <span className="font-semibold">{t("keys.visual")}</span>}
      {visual && pending && " "}
      {pending}
    </>
  ) : null

  return (
    <>
      {status && (
        // top right under the header, clear of the bulk bar at the bottom
        <div
          role="status"
          aria-label={t("keys.status")}
          className="fixed top-[4.25rem] right-4 z-40 rounded-md border bg-background px-3 py-1.5 font-mono text-sm shadow-md eink:top-[4.5rem] eink:border-2 eink:border-black eink:text-base eink:shadow-none"
        >
          {status}
        </div>
      )}
      {hints && <HintLayer hints={hints} />}
      {panel === "help" && <HelpPanel onClose={() => keyboard.setPanel(null)} onCustomize={() => keyboard.setPanel("settings")} />}
      {panel === "settings" && <SettingsPanel onClose={() => keyboard.setPanel(null)} />}
    </>
  )
}

// --- the category tree (gc) ---------------------------------------------------------

const treeLinks = (tree: Element) => [...tree.querySelectorAll<HTMLElement>('[role="treeitem"] > div > a')]

function focusTree(): boolean {
  const tree = document.querySelector('[role="tree"]')
  if (!tree || !(tree as HTMLElement).offsetParent) return false
  const selected = tree.querySelector<HTMLElement>('[role="treeitem"][aria-selected="true"] > div > a')
  const target = selected ?? treeLinks(tree)[0]
  target?.focus()
  return !!target
}

// j/k (arrows) go along the visible categories, l opens, h closes or goes up;
// Enter follows the link as usual.
function treeKey(action: Action, target: EventTarget | null): boolean {
  if (!(target instanceof Element)) return false
  const tree = target.closest('[role="tree"]')
  const item = target.closest('[role="treeitem"]')
  if (!tree || !item) return false
  const links = treeLinks(tree)
  const link = item.querySelector<HTMLElement>(":scope > div > a")
  const i = link ? links.indexOf(link) : -1
  const toggle = item.querySelector<HTMLElement>(":scope > div > button")
  const go = (el: HTMLElement | undefined | null) => (el?.focus(), true)
  switch (action) {
    case "down":
      return go(links[Math.min(links.length - 1, i + 1)])
    case "up":
      return go(links[Math.max(0, i - 1)])
    case "first":
      return go(links[0])
    case "last":
      return go(links[links.length - 1])
    case "right":
      if (item.getAttribute("aria-expanded") === "false") toggle?.click()
      else if (item.getAttribute("aria-expanded") === "true") go(links[i + 1])
      return true
    case "left":
      if (item.getAttribute("aria-expanded") === "true") {
        toggle?.click()
        return go(link)
      }
      return go(item.parentElement?.closest('[role="treeitem"]')?.querySelector<HTMLElement>(":scope > div > a"))
    default:
      return false
  }
}

function leaveTree(target: EventTarget | null): boolean {
  if (!(target instanceof Element) || !target.closest('[role="tree"]')) return false
  if (!focusActive()) (target as HTMLElement).blur()
  return true
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

const savedText = (n: number, name: string) => (n === 1 ? t("list.savedOne", { name }) : t("list.savedMany", { count: formatNumber(n), name }))

function download(book: Book) {
  const format = sortFormats(book.formats)[0]
  if (!format) return false
  const a = document.createElement("a")
  a.href = downloadUrl(book.id, format)
  a.download = ""
  a.click()
  return true
}

interface ListProps {
  books: Book[] | undefined
  search: LibrarySearch
  page: number
  pages: number
}

// The library's part of the keys; returns the delete confirmation to render.
export function useListKeys(props: ListProps): ReactNode {
  const navigate = useNavigate()
  const { data: config = DEFAULT_CONFIG } = useQuery(configQuery)
  const { data: lists } = useQuery(listsQuery)
  const membership = useListMembership()
  const bulkList = useBulkList()
  const qc = useQueryClient()
  const [deleting, setDeleting] = useState<{ book: Book; next: number | null } | null>(null)
  const latest = useRef({ ...props, config, lists, membership, bulkList })
  useEffect(() => {
    latest.current = { ...props, config, lists, membership, bulkList }
  })
  // ending the selection (bulk bar X) ends visual mode too
  const { active: selecting } = useSelection()
  useEffect(() => {
    if (!selecting && keyboard.get().visual) keyboard.setVisual(null)
  }, [selecting])

  useEffect(() => {
    // Like the detail's button: into the list used last, or out of it again
    // when all of them are in it already (with an undo)
    const toggleLast = (list: ReadingList, ids: number[]) => {
      const { books, membership } = latest.current
      const known = (id: number) => books?.find((b) => b.id === id) ?? qc.getQueryData<Book>(["book", id])
      const allIn = ids.every((id) => {
        const b = known(id)
        return !!b && inList(b, list.id)
      })
      membership
        .mutateAsync({ list, bookIds: ids, on: !allIn })
        .then((r) => (allIn ? offerUndoRemove(qc, r.list, r.removed ?? ids) : keyboard.flash(savedText(r.added?.length ?? ids.length, listLabel(r.list)))))
        .catch(() => undefined)
    }
    return registerList((action, count) => {
      const { books, search, page, pages, lists, membership, bulkList, config } = latest.current
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
        case "delete":
          // with a selection: the bulk delete (it asks itself)
          if (sel.active && (sel.ids.size || sel.all)) {
            requestBulk("delete")
            return true
          }
          break
        case "saveLast":
          // with a selection: the selection, otherwise the active book (below)
          if (sel.active && (sel.ids.size || sel.all)) {
            const last = lastUsedList(lists)
            if (!last) keyboard.flash(t("list.noLast"))
            else if (sel.all) {
              // all matches: added, no toggle (that would need them all loaded)
              bulkList
                .mutateAsync({ listId: last.id, target: bulkTarget(search, config.categoryColumn) })
                .then((r) => keyboard.flash(savedText(r.added?.length ?? 0, listLabel(last))))
                .catch(() => undefined)
            } else toggleLast(last, [...sel.ids])
            return true
          }
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
      const book = books[cur]

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
          navigate({ to: "/", search: { ...search, book: book.id, edit: undefined } })
          return true
        case "edit":
          navigate({ to: "/", search: { ...search, book: book.id, edit: true } })
          return true
        case "toggleList": {
          // the default reading list; without one the save dialog
          const list = defaultList(lists)
          if (!list) {
            saveDialog.open(book)
            return true
          }
          membership.mutate({ list, bookIds: [book.id], on: !inList(book, list.id) })
          return true
        }
        case "saveLast": {
          const last = lastUsedList(lists)
          if (!last) saveDialog.open(book)
          else toggleLast(last, [book.id])
          return true
        }
        case "saveDialog":
          saveDialog.open(book)
          return true
        case "delete":
          setDeleting({ book, next: ids[cur + 1] ?? ids[cur - 1] ?? null })
          return true
        case "copyLink":
          navigator.clipboard
            .writeText(new URL(`/books/${book.id}`, location.origin).href)
            .then(() => keyboard.flash(t("keys.linkCopied")))
            .catch(() => keyboard.flash(t("keys.copyFailed")))
          return true
        case "download":
          return download(book)
        case "toggleSelect":
          selection.start()
          selection.toggle(book.id, false, ids)
          showActive()
          return true
        case "visual":
          if (kb.visual) {
            keyboard.setVisual(null)
            return true
          }
          selection.start()
          keyboard.setVisual({ anchor: book.id, base: [...sel.ids] })
          selection.replace([...new Set([...sel.ids, book.id])])
          showActive()
          return true
        default:
          return false
      }
      if (action.startsWith("extend")) {
        const anchor = sel.anchor != null && ids.includes(sel.anchor) ? sel.anchor : book.id
        selection.start()
        selection.addRange(anchor, keyboard.get().active!, ids)
        showActive()
      }
      return true
    })
  }, [navigate, qc])

  if (!deleting) return null
  return (
    <DeleteBookDialog
      book={deleting.book}
      onClose={() => setDeleting(null)}
      onDeleted={() => {
        // the neighbour takes over; an open detail of the book closes
        keyboard.setActive(deleting.next)
        const { search } = latest.current
        if (search.book === deleting.book.id) navigate({ to: "/", search: { ...search, book: undefined, edit: undefined }, replace: true })
        else showActive()
      }}
    />
  )
}

// Segmented like the theme switch: App or Vim keys, per device; the gear
// opens the own bindings.
export function KeyboardSwitch({ className }: { className?: string }) {
  const { mode } = useKeyboard()
  return (
    <div className={cn("grid grid-cols-[auto_1fr_auto] items-center gap-1 rounded-md border p-1 eink:border-2", className)}>
      <Keyboard className="mx-1.5 size-4" aria-hidden />
      <div role="radiogroup" aria-label={t("keys.label")} className="grid grid-cols-2 gap-1">
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
      <button
        type="button"
        onClick={() => keyboard.setPanel("settings")}
        aria-label={t("keys.settings")}
        title={t("keys.settings")}
        className="flex size-7 items-center justify-center rounded-sm hover:bg-accent eink:size-12 touch:size-11"
      >
        <Settings2 className="size-4" aria-hidden />
      </button>
    </div>
  )
}
