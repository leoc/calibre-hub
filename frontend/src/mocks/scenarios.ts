import { makeBooks } from "./data"
import type { Seed } from "./intake"
import type { IntakeUnwritable } from "@/lib/api"

// What the mock Eingang holds, by situation: ?scenario=voll on any page, kept
// for the tab (the app drops the query), chosen with the switcher
// (scenario-switcher.tsx). Without one `analyse`, the Eingang the e2e tests
// know (mocks/intake.ts). A decision stays until the page is loaded again,
// like everything in the mock hub.

export const SCENARIOS = {
  analyse: "Analyse läuft",
  voll: "Eingang voll",
  leer: "Leer",
  dubletten: "Viele Dubletten",
  rechte: "Ordner ohne Schreibrecht",
} as const

export type Scenario = keyof typeof SCENARIOS

const KEY = "hub.mock.scenario"
const known = (s: string | null | undefined): s is Scenario => !!s && Object.hasOwn(SCENARIOS, s)

function chosen(): Scenario {
  if (typeof window === "undefined") return "analyse"
  const asked = new URLSearchParams(window.location.search).get("scenario")
  if (known(asked)) {
    sessionStorage.setItem(KEY, asked)
    return asked
  }
  const kept = sessionStorage.getItem(KEY)
  return known(kept) ? kept : "analyse"
}

export const scenario = chosen()

// someone asked for a scenario in this tab
export const scenarioAsked = () => sessionStorage.getItem(KEY) !== null

const AUTHORS = ["Kosaku Yosida", "Walter Rudin", "Serge Lang", "Hannah Arendt", "Max Weber", "Marie Curie", "Rosalind Franklin", "Emmy Noether", "Theodor Fontane", "Annette von Droste-Hülshoff", "Robert Musil", "Ingeborg Bachmann"]
const SUBJECTS = ["Analysis", "Algebra", "Topologie", "Zahlentheorie", "Stochastik", "Biochemie", "Anatomie", "Mechanik", "Thermodynamik", "Kartografie", "Rhetorik", "Ethik", "Staatsrecht", "Ökologie", "Linguistik"]
const KINDS = ["Grundlagen der", "Einführung in die", "Handbuch der", "Geschichte der", "Lehrbuch der", "Übungen zur"]
const EXTENSIONS = ["pdf", "pdf", "pdf", "epub", "djvu", "mobi", "chm"]

const pad = (n: number) => String(n).padStart(3, "0")

// the n-th book of a made-up collection, the same one on every load
function made(n: number) {
  const author = AUTHORS[n % AUTHORS.length]
  const title = `${KINDS[n % KINDS.length]} ${SUBJECTS[n % SUBJECTS.length]}, Band ${Math.floor(n / 90) + 1}`
  return { author, title, name: `${author} - ${title}`, ext: EXTENSIONS[n % EXTENSIONS.length] }
}

const fresh = (n: number, confidence: number, level: 1 | 2 | 3, decided: string): Seed => {
  const b = made(n)
  return { path: `Sammlung ${n % 7}/${b.name}.${b.ext}`, title: b.title, authors: [b.author], confidence, level, decided }
}

const unread = (n: number): Seed => ({ path: `Unsortiert/${1380293052000 + n}.pdf`, title: String(1380293052000 + n), authors: ["Unknown"], confidence: 10 + (n % 5) * 10, level: 3, decided: "unsure" })

const broken = (n: number): Seed => ({ path: `Defekt/kaputt-${pad(n)}.pdf`, title: "", authors: [], confidence: 0, level: null, failed: "pdfinfo: not a PDF" })

// the file of a book of the mock library, a sure or a possible duplicate
const library = makeBooks(200)
const copy = (n: number, sure: boolean): Seed => {
  const book = library[n % library.length]
  return {
    path: `${sure ? "Kopien" : "Vielleicht"}/${book.authors[0]} - ${book.title} ${pad(n)}.pdf`,
    title: book.title,
    authors: book.authors,
    confidence: sure ? 92 - (n % 3) * 7 : 84 - (n % 5) * 8,
    level: 2,
    decided: "file",
    action: "duplicate",
    bookId: book.id,
    bookTitle: book.title,
    sure,
  }
}

// a file that is another's in the list, not one of the library
const twin = (n: number, of: Seed): Seed => ({ ...of, path: `Doppelt/${pad(n)} ${of.path.split("/").pop()}`, action: "duplicate", sameAs: `/srv/media/ebooks/inbox/${of.path}`, confidence: 80, level: 3, decided: "name" })

const another = (n: number): Seed => ({ ...copy(n, false), sure: false, action: "addFormats", addFormats: ["EPUB"], path: `Formate/${pad(n)}.epub` })

const range = <T,>(from: number, count: number, make: (n: number) => T): T[] => Array.from({ length: count }, (_, i) => make(from + i))

function full(): Seed[] {
  const sure = range(0, 180, (n) => fresh(n, 90 + (n % 9), n % 2 ? 1 : 2, n % 3 ? "openlibrary" : "file"))
  const review = range(180, 120, (n) => fresh(n, 60 + (n % 30), 2, n % 2 ? "file" : "name"))
  const unsure = [...range(300, 40, (n) => fresh(n, 30 + (n % 30), 3, "name")), ...range(340, 45, unread)]
  const failed = range(1, 15, broken)
  const twins = range(1, 10, (n) => twin(n, review[n]))
  const skipped = range(400, 10, (n) => ({ ...fresh(n, 70, 3, "name"), skipped: true }))
  const seeds = [...sure, ...review, ...unsure, ...failed, ...range(0, 40, (n) => copy(n, true)), ...range(40, 30, (n) => copy(n, false)), ...twins, ...range(70, 10, another), ...skipped]
  // like live: nearly all of it from the inbox, a few uploads
  return seeds.map((s, i) => (i % 40 === 7 ? { ...s, origin: "upload" } : s))
}

function duplicates(): Seed[] {
  const review = range(0, 10, (n) => fresh(n, 70 + n, 2, "file"))
  return [...range(0, 120, (n) => copy(n, true)), ...range(120, 80, (n) => copy(n, false)), ...range(1, 8, (n) => twin(n, review[n])), ...range(200, 12, another), ...review, ...range(10, 10, (n) => fresh(n, 94, 1, "openlibrary"))]
}

// The scenario's files instead of the ones of the e2e tests, null for those
export function scenarioSeeds(which: Scenario): Seed[] | null {
  if (which === "voll" || which === "rechte") return full()
  if (which === "dubletten") return duplicates()
  return which === "leer" ? [] : null
}

// Inbox folders the hub may not move files out of, like on 2026-11-07: 107
// folders of group users instead of srv, 2.829 files
const LOCKED: [string, number][] = [
  ["Networks", 306],
  ["Physik", 241],
  ["Mathematik/Analysis", 198],
  ["Informatik/Software", 176],
  ["Chemie", 154],
  ["Geschichte", 132],
  ["Medizin/Anatomie", 117],
  ["Philosophie", 98],
  ["Sprachen/Englisch", 87],
  ["Recht", 76],
]

function locked(): IntakeUnwritable {
  const rest = range(0, 97, (n) => ({ path: `Archiv/${SUBJECTS[n % SUBJECTS.length]} ${Math.floor(n / SUBJECTS.length) + 1}`, files: n < 80 ? 13 : 12 }))
  const folders = [...LOCKED.map(([path, files]) => ({ path, files })), ...rest]
  return { files: folders.reduce((n, f) => n + f.files, 0), folders }
}

// What the last pass over the inbox could not take in, of the scenario
export const scenarioUnwritable = (which: Scenario): IntakeUnwritable => (which === "rechte" ? locked() : { files: 0, folders: [] })
