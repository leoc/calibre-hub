import { useState } from "react"
import { ACTIONS, defaultBindings, formatKeys, GROUPS, type Action, type Bindings } from "@/lib/keymap"
import { keyboard, useKeyboard } from "@/lib/keyboard"
import { t } from "@/i18n"
import { Button } from "./ui/button"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "./ui/dialog"

// --- hints (f, F) -----------------------------------------------------------------

export interface Hint {
  el: HTMLElement
  label: string
  // a book in the grid or list: f opens it, F selects it
  book: number | null
  x: number
  y: number
}
export interface Hints {
  list: Hint[]
  typed: string
  select: boolean
}

const ALPHABET = "asdfjklghqwertzuiopyxcvbnm"

// Labels of equal length, so none is the start of another.
export function hintLabels(n: number): string[] {
  let len = 1
  while (ALPHABET.length ** len < n) len++
  return Array.from({ length: n }, (_, i) => {
    let s = ""
    for (let k = 0, x = i; k < len; k++, x = Math.floor(x / ALPHABET.length)) s = ALPHABET[x % ALPHABET.length] + s
    return s
  })
}

const TARGETS = 'a[href], button:not([disabled]), [role="button"], [role="radio"], [role="checkbox"], summary'

// Books first (so they get the short, early labels), then the other links
// and buttons on screen; inside an open panel only its own.
export function collectHints(): Hint[] {
  const scope: ParentNode = document.querySelector('[role="dialog"][data-state="open"]') ?? document
  const visible = (el: HTMLElement) => {
    const r = el.getBoundingClientRect()
    return r.width > 0 && r.height > 0 && r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth && !el.closest('[aria-hidden="true"], [inert]')
  }
  const books = [...scope.querySelectorAll<HTMLElement>("main [data-book-id]")].filter(visible)
  const others = [...scope.querySelectorAll<HTMLElement>(TARGETS)].filter((el) => !el.closest("[data-book-id]") && visible(el))
  const els = [...books, ...others]
  const labels = hintLabels(els.length)
  return els.map((el, i) => {
    const r = el.getBoundingClientRect()
    const id = el.getAttribute("data-book-id")
    return { el, label: labels[i], book: id != null ? Number(id) : null, x: Math.max(0, r.left), y: Math.max(0, r.top) }
  })
}

export function HintLayer({ hints }: { hints: Hints }) {
  return (
    <div aria-hidden className="pointer-events-none fixed inset-0 z-[70]">
      {hints.list.map((h) =>
        h.label.startsWith(hints.typed) ? (
          <span
            key={h.label}
            data-hint={h.label}
            data-hint-book={h.book ?? undefined}
            style={{ left: h.x, top: h.y }}
            className="absolute rounded-sm border border-black bg-yellow-300 px-1 font-mono text-xs leading-4 font-bold text-black uppercase shadow-sm eink:border-2 eink:bg-black eink:text-sm eink:text-white eink:shadow-none"
          >
            <span className="opacity-40 eink:opacity-100 eink:underline">{hints.typed}</span>
            {h.label.slice(hints.typed.length)}
          </span>
        ) : null,
      )}
    </div>
  )
}

// --- help (?) -------------------------------------------------------------------

function Keys({ keys }: { keys: string[] | undefined }) {
  if (!keys?.length) return <span className="text-muted-foreground eink:text-black">{t("keys.unbound")}</span>
  return (
    <span className="flex flex-wrap justify-end gap-1">
      {keys.map((k) => (
        <kbd key={k} className="rounded-sm border bg-muted px-1.5 py-0.5 font-mono text-xs eink:border-2 eink:border-black eink:bg-white eink:text-sm">
          {formatKeys(k)}
        </kbd>
      ))}
    </span>
  )
}

// The keys of the current mode, grouped; plain table, no greys in E-Ink.
export function HelpPanel({ onClose, onCustomize }: { onClose: () => void; onCustomize: () => void }) {
  const { mode } = useKeyboard()
  const bindings = keyboard.bindings(mode)
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="sm:max-w-2xl">
        <DialogTitle className="text-lg font-semibold">{t("keys.help")}</DialogTitle>
        <DialogDescription>{t("keys.helpMode", { mode: t(`keys.${mode}`) })}</DialogDescription>
        <div className="grid gap-5 sm:grid-cols-2">
          {GROUPS.map((g) => {
            const rows = g.actions.filter((a) => bindings[a]?.length)
            if (!rows.length) return null
            return (
              <section key={g.title}>
                <h3 className="mb-1 text-sm font-semibold">{t(`keys.group.${g.title}`)}</h3>
                <table className="w-full text-sm eink:text-base">
                  <tbody>
                    {rows.map((a) => (
                      <tr key={a} className="border-b last:border-b-0 eink:border-black">
                        <td className="py-1 pr-2">{t(`keys.a.${a}`)}</td>
                        <td className="py-1 text-right">
                          <Keys keys={bindings[a]} />
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </section>
            )
          })}
        </div>
        <div className="flex justify-end gap-2">
          <Button variant="outline" onClick={onCustomize}>
            {t("keys.customize")}
          </Button>
          <Button onClick={onClose}>OK</Button>
        </div>
      </DialogContent>
    </Dialog>
  )
}

// --- own bindings ------------------------------------------------------------------

const split = (text: string) => text.split(/\s+/).filter(Boolean)

// One field per action, keys separated by spaces; stored per device and mode.
export function SettingsPanel({ onClose }: { onClose: () => void }) {
  const { mode } = useKeyboard()
  const defaults = defaultBindings(mode)
  const [draft, setDraft] = useState<Record<Action, string>>(() => {
    const now = keyboard.bindings(mode)
    return Object.fromEntries(ACTIONS.map((a) => [a, (now[a] ?? []).join(" ")])) as Record<Action, string>
  })
  const save = () => {
    const wanted: Bindings = Object.fromEntries(ACTIONS.map((a) => [a, split(draft[a])]))
    keyboard.setBindings(mode, wanted)
    onClose()
  }
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="sm:max-w-2xl">
        <DialogTitle className="text-lg font-semibold">
          {t("keys.settings")} · {t(`keys.${mode}`)}
        </DialogTitle>
        <DialogDescription>{t("keys.settingsHint")}</DialogDescription>
        <form
          className="space-y-5"
          onSubmit={(e) => {
            e.preventDefault()
            save()
          }}
        >
          {GROUPS.map((g) => (
            <fieldset key={g.title} className="space-y-1.5">
              <legend className="mb-1 text-sm font-semibold">{t(`keys.group.${g.title}`)}</legend>
              {g.actions.map((a) => {
                const isDefault = split(draft[a]).join(" ") === (defaults[a] ?? []).join(" ")
                return (
                  <div key={a} className="grid grid-cols-[1fr_9rem_auto] items-center gap-2 text-sm eink:text-base">
                    <label htmlFor={`key-${a}`}>{t(`keys.a.${a}`)}</label>
                    <input
                      id={`key-${a}`}
                      value={draft[a]}
                      onChange={(e) => setDraft({ ...draft, [a]: e.target.value })}
                      spellCheck={false}
                      autoComplete="off"
                      placeholder={t("keys.unbound")}
                      className="h-8 min-w-0 rounded-md border bg-transparent px-2 font-mono text-sm eink:h-11 touch:h-11 eink:border-2"
                    />
                    <Button
                      type="button"
                      variant="ghost"
                      size="sm"
                      disabled={isDefault}
                      onClick={() => setDraft({ ...draft, [a]: (defaults[a] ?? []).join(" ") })}
                    >
                      {t("keys.default")}
                    </Button>
                  </div>
                )
              })}
            </fieldset>
          ))}
          <div className="sticky bottom-0 flex flex-wrap justify-end gap-2 bg-background pt-2">
            <Button
              type="button"
              variant="ghost"
              className="mr-auto"
              onClick={() => setDraft(Object.fromEntries(ACTIONS.map((a) => [a, (defaults[a] ?? []).join(" ")])) as Record<Action, string>)}
            >
              {t("keys.resetAll")}
            </Button>
            <Button type="button" variant="outline" onClick={onClose}>
              {t("edit.cancel")}
            </Button>
            <Button type="submit">{t("keys.save")}</Button>
          </div>
        </form>
      </DialogContent>
    </Dialog>
  )
}
