// Key bindings for the library, in two modes: "app" (arrows, Home/End, Space
// …) and "vim" (the app keys plus hjkl, counts, gg/G, visual mode …).
//
// Keys are written like Vim and the TUI keymaps: a printable character is
// itself ("j", "G", ">", "/"), everything else is <Name> with optional
// modifiers C- (Ctrl, also Cmd), A- (Alt), S- (Shift): "<Down>", "<S-Down>",
// "<C-d>", "<A-Left>", "<Space>", "<Enter>", "<Esc>", "<Del>", "<F2>",
// "<PageDown>". A sequence is the keys one after the other: "gg", "dd", "gt".

export const MODES = ["app", "vim"] as const
export type KeyMode = (typeof MODES)[number]

export const ACTIONS = [
  "down",
  "up",
  "left",
  "right",
  "first",
  "last",
  "halfDown",
  "halfUp",
  "nextPage",
  "prevPage",
  "open",
  "toggleSelect",
  "extendDown",
  "extendUp",
  "extendLeft",
  "extendRight",
  "visual",
  "selectAll",
  "search",
  "commands",
  "edit",
  "toggleList",
  "saveLast",
  "saveDialog",
  "delete",
  "copyLink",
  "download",
  "back",
  "forward",
  "goLibrary",
  "goTrash",
  "goMetadata",
  "goSuggestions",
  "goCategories",
  "goLists",
  "goDuplicates",
  "hints",
  "hintsSelect",
  "help",
] as const
export type Action = (typeof ACTIONS)[number]

export type Bindings = Partial<Record<Action, string[]>>

const APP: Bindings = {
  down: ["<Down>"],
  up: ["<Up>"],
  left: ["<Left>"],
  right: ["<Right>"],
  first: ["<Home>"],
  last: ["<End>"],
  nextPage: ["<PageDown>"],
  prevPage: ["<PageUp>"],
  open: ["<Enter>"],
  toggleSelect: ["<Space>"],
  extendDown: ["<S-Down>"],
  extendUp: ["<S-Up>"],
  extendLeft: ["<S-Left>"],
  extendRight: ["<S-Right>"],
  selectAll: ["<C-a>"],
  search: ["/"],
  commands: [">"],
  edit: ["<F2>"],
  // Ctrl+S would save the page in the browser
  saveLast: ["<C-s>"],
  saveDialog: ["<C-S-s>"],
  delete: ["<Del>"],
  back: ["<A-Left>"],
  forward: ["<A-Right>"],
  help: ["?"],
}

// on top of the app keys
const VIM: Bindings = {
  down: ["j"],
  up: ["k"],
  left: ["h"],
  right: ["l"],
  first: ["gg"],
  last: ["G"],
  halfDown: ["<C-d>"],
  halfUp: ["<C-u>"],
  nextPage: ["]"],
  prevPage: ["["],
  visual: ["v"],
  edit: ["e"],
  toggleList: ["t"],
  saveLast: ["s"],
  saveDialog: ["S"],
  delete: ["dd"],
  copyLink: ["y"],
  download: ["D"],
  back: ["H"],
  forward: ["L"],
  goLibrary: ["gl"],
  goTrash: ["gt"],
  goMetadata: ["gm"],
  goSuggestions: ["gv"],
  goCategories: ["gc"],
  goLists: ["gL"],
  goDuplicates: ["gD"],
  hints: ["f"],
  hintsSelect: ["F"],
}

// For the help and the settings, in this order
export const GROUPS: { title: "move" | "select" | "book" | "go"; actions: Action[] }[] = [
  { title: "move", actions: ["down", "up", "left", "right", "first", "last", "halfDown", "halfUp", "nextPage", "prevPage"] },
  { title: "select", actions: ["toggleSelect", "extendDown", "extendUp", "extendLeft", "extendRight", "visual", "selectAll"] },
  { title: "book", actions: ["open", "edit", "toggleList", "saveLast", "saveDialog", "delete", "copyLink", "download", "hints", "hintsSelect"] },
  { title: "go", actions: ["search", "commands", "back", "forward", "goLibrary", "goTrash", "goMetadata", "goSuggestions", "goCategories", "goLists", "goDuplicates", "help"] },
]

export function defaultBindings(mode: KeyMode): Bindings {
  if (mode === "app") return APP
  const out: Bindings = { ...APP }
  for (const [action, keys] of Object.entries(VIM) as [Action, string[]][]) out[action] = [...keys, ...(APP[action] ?? [])]
  return out
}

// Own bindings replace the defaults of the actions they name.
export function withOverrides(base: Bindings, overrides: Bindings | null | undefined): Bindings {
  return { ...base, ...(overrides ?? {}) }
}

// Own bindings as stored: {"down": ["n", "j"], …}; anything else is dropped.
export function parseOverrides(json: string | null): Bindings {
  if (!json) return {}
  try {
    const raw: unknown = JSON.parse(json)
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) return {}
    const out: Bindings = {}
    for (const [action, keys] of Object.entries(raw)) {
      if ((ACTIONS as readonly string[]).includes(action) && Array.isArray(keys) && keys.every((k) => typeof k === "string" && k.length > 0)) {
        out[action as Action] = keys
      }
    }
    return out
  } catch {
    return {}
  }
}

// Only what differs from the defaults is kept.
export function diffOverrides(base: Bindings, wanted: Bindings): Bindings {
  const out: Bindings = {}
  for (const action of ACTIONS) {
    const keys = wanted[action]
    if (keys && keys.join(" ") !== (base[action] ?? []).join(" ")) out[action] = keys
  }
  return out
}

const NAMES: Record<string, string> = {
  ArrowDown: "Down",
  ArrowUp: "Up",
  ArrowLeft: "Left",
  ArrowRight: "Right",
  Escape: "Esc",
  Delete: "Del",
  Backspace: "BS",
  " ": "Space",
}
const MODIFIER_KEYS = new Set(["Shift", "Control", "Alt", "Meta", "AltGraph", "CapsLock", "OS", "Dead", "Unidentified", "Process"])

export interface KeyLike {
  key: string
  ctrlKey: boolean
  altKey: boolean
  metaKey: boolean
  shiftKey: boolean
}

// One key press as a token: "j", "G", "<C-d>", "<S-Down>"; null for modifier keys alone.
export function eventToken(e: KeyLike): string | null {
  if (MODIFIER_KEYS.has(e.key)) return null
  const ctrl = e.ctrlKey || e.metaKey
  const printable = e.key.length === 1 && e.key !== " "
  if (printable && !ctrl && !e.altKey) return e.key
  const name = NAMES[e.key] ?? (printable ? e.key.toLowerCase() : e.key)
  // Shift is part of a printable character ("G"), a modifier for the rest
  const shift = e.shiftKey && (!printable || ctrl || e.altKey)
  const mods = `${ctrl ? "C-" : ""}${e.altKey ? "A-" : ""}${shift ? "S-" : ""}`
  return `<${mods}${name}>`
}

const CANONICAL = new Map(
  ["Down", "Up", "Left", "Right", "Esc", "Del", "BS", "Space", "Enter", "Tab", "Home", "End", "PageDown", "PageUp", "Insert"].map((n) => [n.toLowerCase(), n]),
)

// "gg" -> ["g", "g"], "<c-d>x" -> ["<C-d>", "x"]
export function parseKeys(keys: string): string[] {
  const out: string[] = []
  for (let i = 0; i < keys.length; ) {
    const m = keys[i] === "<" ? /^<((?:[CASM]-)*)([^<>\s-]+|-)>/i.exec(keys.slice(i)) : null
    if (m) {
      const mods = ["C", "A", "S"].filter((x) => m[1].toUpperCase().includes(`${x}-`) || (x === "C" && /M-/i.test(m[1])))
      let name = m[2]
      name = CANONICAL.get(name.toLowerCase()) ?? (/^f\d{1,2}$/i.test(name) ? name.toUpperCase() : name.length === 1 && mods.length ? name.toLowerCase() : name)
      out.push(mods.length || name.length > 1 ? `<${mods.map((x) => `${x}-`).join("")}${name}>` : name)
      i += m[0].length
    } else {
      out.push(keys[i])
      i++
    }
  }
  return out
}

// Shown in the help and the settings: "<C-d>" -> "Strg+D", "<S-Down>" -> "Shift+↓"
const SHOWN: Record<string, string> = { Down: "↓", Up: "↑", Left: "←", Right: "→", Esc: "Esc", Del: "Entf", Space: "Leertaste", Enter: "Enter", PageDown: "Bild↓", PageUp: "Bild↑", Home: "Pos1", End: "Ende", BS: "⌫" }
export function formatKeys(keys: string): string {
  return parseKeys(keys)
    .map((tok) => {
      const m = /^<((?:[CAS]-)*)(.+)>$/.exec(tok)
      if (!m) return tok
      const mods = m[1].split("-").filter(Boolean).map((x) => ({ C: "Strg", A: "Alt", S: "Shift" })[x] + "+")
      const name = SHOWN[m[2]] ?? (m[2].length === 1 ? m[2].toUpperCase() : m[2])
      return mods.join("") + name
    })
    .join(" ")
}

export type Feed = { type: "action"; action: Action; count: number | null } | { type: "pending" } | { type: "none" }

// Turns key tokens into actions: sequences ("gg"), and in Vim mode a count
// in front ("5j"). A key that fits nothing drops what was typed so far.
export class KeyEngine {
  private exact = new Map<string, Action>()
  private prefixes = new Set<string>()
  private buffer: string[] = []
  private count = ""

  constructor(
    bindings: Bindings,
    private counts: boolean,
  ) {
    for (const [action, list] of Object.entries(bindings) as [Action, string[]][]) {
      for (const keys of list ?? []) {
        const toks = parseKeys(keys)
        if (!toks.length) continue
        const id = toks.join("\u0000")
        if (!this.exact.has(id)) this.exact.set(id, action)
        for (let i = 1; i < toks.length; i++) this.prefixes.add(toks.slice(0, i).join("\u0000"))
      }
    }
  }

  // what has been typed towards the next action, for the status line
  get pending(): string {
    return this.count + this.buffer.join("")
  }

  reset() {
    this.buffer = []
    this.count = ""
  }

  feed(token: string): Feed {
    if (this.counts && !this.buffer.length && /^[0-9]$/.test(token) && (token !== "0" || this.count)) {
      this.count += token
      return { type: "pending" }
    }
    const tryBuffer = (buf: string[]): Feed | null => {
      const id = buf.join("\u0000")
      const action = this.exact.get(id)
      if (action) {
        const count = this.count ? Number(this.count) : null
        this.reset()
        return { type: "action", action, count }
      }
      if (this.prefixes.has(id)) {
        this.buffer = buf
        return { type: "pending" }
      }
      return null
    }
    const hadPending = this.buffer.length > 0 || this.count !== ""
    const r = tryBuffer([...this.buffer, token])
    if (r) return r
    // nothing fits: start over with this key alone
    this.reset()
    if (hadPending) {
      const again = tryBuffer([token])
      if (again) return again
    }
    return { type: "none" }
  }
}
