import {
  BookOpenText,
  BookText,
  Building,
  CalendarDays,
  CloudDownload,
  CopyCheck,
  Download,
  FileOutput,
  FolderTree,
  ImageDown,
  Languages,
  Link2,
  ListMinus,
  ListOrdered,
  ListPlus,
  LockKeyhole,
  Sparkles,
  Star,
  Tag,
  Tags,
  Trash2,
  User,
  WandSparkles,
  Wrench,
  type LucideIcon,
} from "lucide-react"
import { formatNumber, languageName, t } from "@/i18n"
import type { MessageKey } from "@/i18n/de"
import type { Book, BulkChanges, BulkTarget, Categories, HubConfig, Named, ReadingList } from "./api"
import { categorySuggestions, parseCategory } from "./kategorie"
import { inList, listLabel, savableLists } from "./lists"
import { matchNamed } from "./palette"
import { readerFormat } from "./reader"

// Commands on books, one definition each for the bulk bar and the command
// palette (README "Commands on books"). Pure: what an action is called, what
// it takes, for which books it is offered and which field change it makes.
// Running them is src/lib/run-action.ts.

// Runs over more books than this ask first (deleting always asks)
export const CONFIRM_ABOVE = 50

// The books a command acts on: the selection (ids in the order they were
// selected, or all matches of the search), else the active book (focus
// ring), else the book open in the detail
export interface ActionTarget {
  bulk: BulkTarget
  count: number
  // one book: its title names the target
  book?: Book
  // ids in selection order (numbering a series)
  ordered: boolean
}

export const bookTarget = (book: Book): ActionTarget => ({ bulk: { ids: [book.id] }, count: 1, book, ordered: true })

export type ValueKind = "tag" | "bookTag" | "privateTag" | "bookPrivateTag" | "kategorie" | "series" | "author" | "publisher" | "language" | "rating" | "year" | "list" | "bookList" | "name"

// A value to pick: what is stored (category dotted, list id, language code)
// and what is shown
export interface ActionValue {
  value: string
  label: string
  count?: number
  // categories: level in the tree
  depth?: number
  // not there yet: created ("Neu: …")
  isNew?: boolean
  // empties the field
  clear?: boolean
}

export type BookActionId =
  | "addTags"
  | "removeTags"
  | "addPrivateTags"
  | "removePrivateTags"
  | "kategorie"
  | "series"
  | "seriesNumbered"
  | "authors"
  | "publisher"
  | "language"
  | "rating"
  | "year"
  | "addToList"
  | "removeFromList"
  | "newList"
  | "metadata"
  | "classify"
  | "epubFix"
  | "convert"
  | "duplicates"
  | "cover"
  | "read"
  | "download"
  | "copyLink"
  | "offline"
  | "delete"

// mine: the user's own data on books (private tags), for readers too
export type ActionGroup = "edit" | "mine" | "lists" | "maintenance" | "device"

export interface BookActionDef {
  id: BookActionId
  group: ActionGroup
  // the command: "Tag hinzufügen"
  label: MessageKey
  // the bulk bar's button, when it has one
  bar?: MessageKey
  // with a value: "Tag ‚{value}‘ hinzufügen"
  valued?: MessageKey
  icon: LucideIcon
  // typed words that start a direct command ("tag sheet music"), folded
  keywords: string[]
  // takes a value of this kind (palette: direct or as a second step)
  value?: ValueKind
  // a value that doesn't exist yet may be typed ("Neu: …")
  allowNew?: boolean
  // the typed text is the value itself (year, publisher), no "Neu:"
  free?: boolean
  // an entry that empties the field
  clear?: MessageKey
  // only for one book
  one?: boolean
  // needs a hub feature (GET /api/config)
  needs?: "metadata" | "classify"
  // always asks (deleting)
  confirm?: boolean
  // a reader may run it: it changes only the reader's own things (lists,
  // private tags) or none
  reader?: boolean
  // field changes: a bulk job, undoable
  changes?: (value: string | string[] | null, target: ActionTarget) => BulkChanges
  // offered for these books at all
  offered?: (target: ActionTarget) => boolean
}

const list = (v: string | string[] | null) => (v == null ? [] : Array.isArray(v) ? v : [v])
const one = (v: string | string[] | null) => list(v)[0] ?? null

export const BOOK_ACTIONS: BookActionDef[] = [
  // --- edit -----------------------------------------------------------------
  {
    id: "addTags",
    group: "edit",
    label: "actions.addTags",
    bar: "bulk.addTags",
    valued: "actions.addTagsValue",
    icon: Tags,
    keywords: ["tag hinzufugen", "tags hinzufugen", "tag", "tags", "+tag"],
    value: "tag",
    allowNew: true,
    changes: (v) => ({ addTags: list(v) }),
  },
  {
    id: "removeTags",
    group: "edit",
    label: "actions.removeTags",
    bar: "bulk.removeTags",
    valued: "actions.removeTagsValue",
    icon: Tag,
    keywords: ["tag entfernen", "tags entfernen", "-tag", "untag"],
    value: "bookTag",
    changes: (v) => ({ removeTags: list(v) }),
  },
  {
    id: "kategorie",
    group: "edit",
    label: "bulk.kategorie",
    bar: "bulk.kategorie",
    valued: "actions.kategorieValue",
    icon: FolderTree,
    keywords: ["kategorie setzen", "kategorie", "kat"],
    value: "kategorie",
    allowNew: true,
    clear: "actions.kategorieClear",
    changes: (v) => ({ kategorie: one(v) }),
  },
  {
    id: "series",
    group: "edit",
    label: "bulk.series",
    bar: "bulk.series",
    valued: "actions.seriesValue",
    icon: BookText,
    keywords: ["serie setzen", "serie", "series"],
    value: "series",
    allowNew: true,
    clear: "actions.seriesClear",
    changes: (v) => ({ series: one(v) }),
  },
  {
    // volumes 1..n in the order the books were selected
    id: "seriesNumbered",
    group: "edit",
    label: "actions.seriesNumbered",
    valued: "actions.seriesNumberedValue",
    icon: ListOrdered,
    keywords: ["serie nummerieren", "durchnummerieren", "nummerieren"],
    value: "series",
    allowNew: true,
    changes: (v) => ({ series: one(v), numberSeries: true }),
    offered: (target) => target.ordered && target.count > 1,
  },
  {
    id: "authors",
    group: "edit",
    label: "actions.authors",
    valued: "actions.authorsValue",
    icon: User,
    keywords: ["autor setzen", "autor", "autoren", "author"],
    value: "author",
    allowNew: true,
    // "A & B": several authors, as calibre writes them
    changes: (v) => ({ authors: list(v).flatMap((a) => a.split(/\s+&\s+/)).map((a) => a.trim()).filter(Boolean) }),
  },
  {
    id: "publisher",
    group: "edit",
    label: "actions.publisher",
    valued: "actions.publisherValue",
    icon: Building,
    keywords: ["verlag setzen", "verlag", "publisher"],
    value: "publisher",
    free: true,
    clear: "actions.publisherClear",
    changes: (v) => ({ publisher: one(v) }),
  },
  {
    id: "language",
    group: "edit",
    label: "actions.language",
    valued: "actions.languageValue",
    icon: Languages,
    keywords: ["sprache setzen", "sprache", "language"],
    value: "language",
    changes: (v) => ({ languages: list(v) }),
  },
  {
    id: "rating",
    group: "edit",
    label: "actions.rating",
    valued: "actions.ratingValue",
    icon: Star,
    keywords: ["bewertung", "sterne", "rating"],
    value: "rating",
    changes: (v) => ({ rating: Number(one(v)) || null }),
  },
  {
    id: "year",
    group: "edit",
    label: "actions.year",
    valued: "actions.yearValue",
    icon: CalendarDays,
    keywords: ["erscheinungsjahr", "jahr", "year"],
    value: "year",
    free: true,
    clear: "actions.yearClear",
    changes: (v) => ({ pubYear: one(v) ? Number(one(v)) : null }),
  },
  // --- the user's private tags (in the hub, not in calibre) -----------------
  {
    id: "addPrivateTags",
    group: "mine",
    label: "actions.addPrivateTags",
    bar: "bulk.addPrivateTags",
    valued: "actions.addPrivateTagsValue",
    icon: LockKeyhole,
    keywords: ["mein tag hinzufugen", "meinen tag hinzufugen", "mein tag", "meinen tag", "+mein"],
    value: "privateTag",
    allowNew: true,
    reader: true,
  },
  {
    id: "removePrivateTags",
    group: "mine",
    label: "actions.removePrivateTags",
    bar: "bulk.removePrivateTags",
    valued: "actions.removePrivateTagsValue",
    icon: LockKeyhole,
    keywords: ["mein tag entfernen", "meinen tag entfernen", "-mein"],
    value: "bookPrivateTag",
    reader: true,
  },
  // --- lists (never a magic shelf: its rule finds its books) ----------------
  {
    id: "addToList",
    group: "lists",
    label: "bulk.addToList",
    bar: "bulk.addToList",
    valued: "actions.addToListValue",
    icon: ListPlus,
    keywords: ["zu liste", "in liste", "liste"],
    value: "list",
    allowNew: true,
    reader: true,
  },
  {
    id: "removeFromList",
    group: "lists",
    label: "bulk.removeFromList",
    bar: "bulk.removeFromList",
    valued: "actions.removeFromListValue",
    icon: ListMinus,
    keywords: ["aus liste"],
    value: "bookList",
    reader: true,
  },
  {
    id: "newList",
    group: "lists",
    label: "actions.newList",
    valued: "actions.newListValue",
    icon: ListPlus,
    keywords: ["neue liste"],
    value: "name",
    free: true,
    reader: true,
  },
  // --- maintenance runs -------------------------------------------------------
  { id: "metadata", group: "maintenance", label: "actions.metadata", icon: WandSparkles, keywords: [], needs: "metadata" },
  { id: "classify", group: "maintenance", label: "actions.classify", icon: Sparkles, keywords: [], needs: "classify" },
  {
    id: "epubFix",
    group: "maintenance",
    label: "actions.epubFix",
    icon: Wrench,
    keywords: [],
    offered: (target) => !target.book || target.book.formats.some((f) => f.toUpperCase() === "EPUB"),
  },
  {
    id: "convert",
    group: "maintenance",
    label: "actions.convert",
    icon: FileOutput,
    keywords: [],
    offered: (target) => !target.book || (target.book.formats.length > 0 && !target.book.formats.some((f) => f.toUpperCase() === "EPUB")),
  },
  { id: "duplicates", group: "maintenance", label: "actions.duplicates", icon: CopyCheck, keywords: [] },
  {
    id: "cover",
    group: "maintenance",
    label: "actions.cover",
    icon: ImageDown,
    keywords: [],
    offered: (target) => !target.book || target.book.formats.length > 0,
  },
  // --- device and export ----------------------------------------------------
  { id: "read", group: "device", label: "actions.read", icon: BookOpenText, keywords: [], one: true, reader: true, offered: (target) => !!target.book && !!readerFormat(target.book) },
  {
    id: "download",
    group: "device",
    label: "book.download",
    icon: Download,
    keywords: [],
    reader: true,
    offered: (target) => !target.book || target.book.formats.length > 0,
  },
  { id: "copyLink", group: "device", label: "actions.copyLink", icon: Link2, keywords: [], reader: true },
  {
    id: "offline",
    group: "device",
    label: "offline.make",
    icon: CloudDownload,
    keywords: [],
    reader: true,
    offered: (target) => typeof caches !== "undefined" && (!target.book || !!readerFormat(target.book)),
  },
  { id: "delete", group: "device", label: "bulk.delete", bar: "bulk.delete", icon: Trash2, keywords: [], confirm: true, changes: () => ({ delete: true }) },
]

export const bookAction = (id: BookActionId): BookActionDef => BOOK_ACTIONS.find((a) => a.id === id)!

// The actions offered for these books with this hub's features; a reader
// gets only those that change nothing of the library (admin: false)
export function offeredActions(target: ActionTarget, config: Pick<HubConfig, "metadata" | "classify">, admin = true): BookActionDef[] {
  return BOOK_ACTIONS.filter(
    (a) => (admin || a.reader) && (!a.one || target.book) && (!a.needs || config[a.needs]) && (a.offered?.(target) ?? true),
  )
}

// " (3)" or ": Titel"
export const targetSuffix = (target: ActionTarget) => (target.book ? `: ${target.book.title}` : ` (${formatNumber(target.count)})`)

// "Tag hinzufügen (3)", "Tag ‚Krimi‘ hinzufügen: Titel", "Neu: Zu Liste ‚Sommer‘ (3)"
export function commandLabel(def: BookActionDef, target: ActionTarget | null, value?: ActionValue): string {
  const base = value?.clear && def.clear ? t(def.clear) : value && def.valued ? t(def.valued, { value: value.label }) : t(def.label)
  const named = value?.isNew && !def.free ? t("actions.new", { label: base }) : base
  return target ? `${named}${targetSuffix(target)}` : named
}

// Runs that change many books ask first; deleting always does
export const needsConfirm = (def: BookActionDef, target: ActionTarget) =>
  !!def.confirm || (def.id !== "read" && def.id !== "copyLink" && def.id !== "duplicates" && target.count > CONFIRM_ABOVE)

// --- direct input -------------------------------------------------------------

const fold = (s: string) =>
  s
    .normalize("NFD")
    .replace(/\p{Diacritic}/gu, "")
    .toLowerCase()
    .replace(/[:…‚‘„“"]/g, " ")
    .replace(/\s+/g, " ")
    .trim()

// "tag sheet music" -> addTags with "sheet music"; the longest keyword wins
// ("tag entfernen krimi" is removeTags, not a tag "entfernen krimi")
export function parseDirect(text: string, defs: BookActionDef[] = BOOK_ACTIONS): { def: BookActionDef; rest: string }[] {
  const folded = fold(text)
  // still typing a longer keyword ("tag hinzu…"): the command itself, no value
  if (defs.some((d) => d.keywords.some((k) => k.startsWith(folded)))) return []
  const hits: { def: BookActionDef; rest: string; length: number }[] = []
  for (const def of defs) {
    if (!def.value) continue
    const k = def.keywords.filter((w) => folded.startsWith(`${w} `)).sort((a, b) => b.length - a.length)[0]
    if (!k) continue
    // the rest keeps its case: "Sheet Music" stays as typed
    const words = k.split(" ").length
    const rest = text.trim().split(/\s+/).slice(words).join(" ").replace(/^[:\s]+/, "").trim()
    if (rest) hits.push({ def, rest, length: k.length })
  }
  const longest = Math.max(0, ...hits.map((h) => h.length))
  return hits.filter((h) => h.length === longest).map(({ def, rest }) => ({ def, rest }))
}

// --- values ---------------------------------------------------------------------

export interface ValueSources {
  // privateTags: the user's own
  cats?: Categories
  lists?: ReadingList[]
  // one book: its own tags and lists to remove
  book?: Book
}

const RATINGS = [0, 2, 4, 6, 8, 10]
export const ratingLabel = (r: number) => (r === 0 ? t("actions.noRating") : `${"★".repeat(r / 2)}${"☆".repeat(5 - r / 2)}`)

const named = (items: Named[], text: string, limit: number): ActionValue[] =>
  matchNamed(items, text, limit).map((n) => ({ value: n.name, label: n.name, count: n.count }))

// The values to pick from, matching the typed text; existing ones only
export function existingValues(kind: ValueKind, src: ValueSources, text: string, limit = 50): ActionValue[] {
  const cats = src.cats
  switch (kind) {
    case "tag":
      return named(cats?.tags ?? [], text, limit)
    case "bookTag":
      return named(src.book ? src.book.tags.map((name) => ({ name, count: 0 })) : (cats?.tags ?? []), text, limit)
    case "privateTag":
      return named(cats?.privateTags ?? [], text, limit)
    case "bookPrivateTag":
      return named(src.book ? (src.book.privateTags ?? []).map((name) => ({ name, count: 0 })) : (cats?.privateTags ?? []), text, limit)
    case "series":
      return named(cats?.series ?? [], text, limit)
    case "author":
      return named(cats?.authors ?? [], text, limit)
    case "kategorie": {
      const all = categorySuggestions(cats?.kategorie ?? [])
      // the tree in its order, indented; typed: the best matches
      const shown = text.trim() ? matchNamed(all, text, limit) : all.slice(0, limit)
      return shown.map((k) => ({ value: k.path, label: k.name, count: k.count, depth: text.trim() ? 0 : k.name.split("/").length - 1 }))
    }
    case "language":
      return matchNamed(
        (cats?.languages ?? []).map((l) => ({ name: `${languageName(l.name)} (${l.name})`, code: l.name, count: l.count })),
        text,
        limit,
      ).map((l) => ({ value: l.code, label: languageName(l.code), count: l.count }))
    case "rating":
      return RATINGS.filter((r) => !text.trim() || String(r / 2) === text.trim() || ratingLabel(r).toLowerCase().includes(text.trim().toLowerCase())).map((r) => ({
        value: String(r),
        label: ratingLabel(r),
      }))
    case "list":
    case "bookList": {
      const own = savableLists(src.lists).filter((l) => kind === "list" || !src.book || inList(src.book, l.id))
      return matchNamed(
        own.map((l) => ({ name: listLabel(l), count: l.count, id: l.id })),
        text,
        limit,
      )
        .sort((a, b) => (text.trim() ? 0 : a.name.localeCompare(b.name, "de", { sensitivity: "base", numeric: true })))
        .map((l) => ({ value: String(l.id), label: l.name, count: l.count }))
    }
    case "publisher":
    case "year":
    case "name":
      return []
  }
}

// The typed text as a value of its own, or null when it can't be one
export function typedValue(def: BookActionDef, text: string): ActionValue | null {
  const v = text.trim()
  if (!v || !(def.allowNew || def.free)) return null
  switch (def.value) {
    case "year":
      return /^\d{1,4}$/.test(v) && Number(v) > 0 ? { value: String(Number(v)), label: String(Number(v)), isNew: true } : null
    case "kategorie": {
      const p = parseCategory(v)
      return "value" in p && p.value ? { value: p.value, label: p.value.split(".").join("/"), isNew: true } : null
    }
    case "list":
    case "name":
      return { value: listLabel(v), label: listLabel(v), isNew: true }
    default:
      return { value: v, label: v, isNew: true }
  }
}

// Existing values first, then the typed one when it isn't among them, then
// the entry that empties the field
export function valueChoices(def: BookActionDef, src: ValueSources, text: string, limit = 50): ActionValue[] {
  if (!def.value) return []
  const found = existingValues(def.value, src, text, limit)
  const typed = typedValue(def, text)
  const same = (a: string, b: string) => a.localeCompare(b, "de", { sensitivity: "base" }) === 0
  const exists = typed && found.some((f) => same(f.label, typed.label) || same(f.value, typed.value))
  const clear = def.clear && !text.trim() ? [{ value: "", label: t(def.clear), clear: true }] : []
  return [...found, ...(typed && !exists ? [typed] : []), ...clear]
}

// The stored value a change takes: null empties
export const changeValue = (v: ActionValue): string | null => (v.clear ? null : v.value)
