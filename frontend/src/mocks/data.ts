import type { Book, Categories, CategoryNode, Named } from "@/lib/api"

// Deterministic fake library for `pnpm dev:mock` and tests.
function rng(seed: number) {
  return () => {
    seed = (seed * 1664525 + 1013904223) % 4294967296
    return seed / 4294967296
  }
}

const AUTHORS = ["Terry Pratchett", "Ursula K. Le Guin", "Neil Gaiman", "Isaac Asimov", "Octavia E. Butler", "Brigitte Präger", "John Bowlby", "Daniel Kahneman", "Mary Beard", "Yuval Noah Harari", "Christa Wolf", "Thomas Mann", "Juli Zeh", "Ted Chiang", "N. K. Jemisin"]
const SERIES = ["Scheibenwelt", "Erdsee", "Foundation", "Die zerbrochene Erde", "Xenogenesis"]
const KATEGORIEN = ["Roman.Fantasy", "Roman.Science-Fiction", "Roman.Klassiker", "Sachbuch.Geschichte.Antike", "Sachbuch.Psychologie", "Psychologie.Attachment", "Fachbuch.Software.Architektur", null, null]
const TAGS = ["leseliste", "gelesen", "favorit", "ausgeliehen", "englisch-lernen", "geschenk"]
const WORDS = ["Die", "Farben", "der", "Magie", "Zeit", "Schatten", "Wind", "Stadt", "Kinder", "Insel", "letzte", "Licht", "Stern", "Haus", "Spiel", "Gedächtnis", "Bindung", "Denken", "schnell", "langsam"]
const FORMATS = [["EPUB"], ["EPUB", "PDF"], ["PDF"], ["EPUB", "AZW3"], []]
const LANGS = [["deu"], ["deu"], ["eng"], ["deu"], ["fra"]]

export function makeBooks(n: number, seed = 42): Book[] {
  const r = rng(seed)
  const pick = <T,>(xs: T[]) => xs[Math.floor(r() * xs.length)]
  const seriesCount: Record<string, number> = {}
  return Array.from({ length: n }, (_, i) => {
    const id = i + 1
    const series = r() < 0.3 ? pick(SERIES) : null
    if (series) seriesCount[series] = (seriesCount[series] ?? 0) + 1
    const added = new Date(Date.UTC(2015, 0, 1) + r() * 11 * 365 * 864e5).toISOString()
    const tags = TAGS.filter(() => r() < 0.15)
    const title = Array.from({ length: 2 + Math.floor(r() * 4) }, () => pick(WORDS)).join(" ")
    const authors = r() < 0.1 ? [pick(AUTHORS), pick(AUTHORS)].filter((a, j, xs) => xs.indexOf(a) === j) : [pick(AUTHORS)]
    return {
      id,
      title: title[0].toUpperCase() + title.slice(1),
      authors,
      authorSort: authors[0].split(" ").reverse().join(", "),
      tags,
      series,
      seriesIndex: series ? seriesCount[series] : null,
      formats: pick(FORMATS),
      lastModified: added,
      added,
      pubdate: r() < 0.8 ? new Date(Date.UTC(1950 + Math.floor(r() * 75), 0, 1)).toISOString() : null,
      rating: r() < 0.3 ? Math.ceil(r() * 5) * 2 : null,
      publisher: r() < 0.6 ? pick(["Goldmann", "Piper", "Fischer", "Tor", "O'Reilly"]) : null,
      identifiers: (r() < 0.5 ? { isbn: `978${Math.floor(r() * 1e10)}` } : {}) as Record<string, string>,
      languages: pick(LANGS),
      comments: r() < 0.7 ? `<p>${title}. Ein Buch über <b>${pick(WORDS)}</b> und ${pick(WORDS)}.</p><p>Zweiter Absatz.</p>` : null,
      custom: { kategorie: pick(KATEGORIEN) },
    }
  })
}

export function tree(items: Named[]): CategoryNode[] {
  const roots: CategoryNode[] = []
  const nodes = new Map<string, CategoryNode>()
  for (const item of [...items].sort((a, b) => a.name.localeCompare(b.name))) {
    const parts = item.name.split(".")
    parts.forEach((part, i) => {
      const path = parts.slice(0, i + 1).join(".")
      let node = nodes.get(path)
      if (!node) {
        node = { name: part, path, count: 0, children: [] }
        nodes.set(path, node)
        if (i === 0) roots.push(node)
        else nodes.get(parts.slice(0, i).join("."))!.children.push(node)
      }
      node.count += item.count
    })
  }
  return roots
}

function counts(values: string[]): Named[] {
  const m = new Map<string, number>()
  values.forEach((v) => m.set(v, (m.get(v) ?? 0) + 1))
  return [...m].map(([name, count]) => ({ name, count })).sort((a, b) => a.name.localeCompare(b.name))
}

export function categories(books: Book[]): Categories {
  return {
    kategorie: tree(counts(books.flatMap((b) => (typeof b.custom.kategorie === "string" ? [b.custom.kategorie] : [])))),
    tags: counts(books.flatMap((b) => b.tags)),
    authors: counts(books.flatMap((b) => b.authors)),
    series: counts(books.flatMap((b) => (b.series ? [b.series] : []))),
    languages: counts(books.flatMap((b) => b.languages)),
  }
}
