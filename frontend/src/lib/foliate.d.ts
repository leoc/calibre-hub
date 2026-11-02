// The parts of foliate-js (vendor/foliate-js, alias "foliate-js") the
// reader uses. Importing view.js defines the <foliate-view> element.
declare module "foliate-js/view.js" {
  export interface TocItem {
    label: string
    href: string
    subitems?: TocItem[] | null
  }

  // a CFI or TOC href, a section index, or a fraction of the book
  export type Target = string | number | { fraction: number }

  export interface FoliateBook {
    metadata?: { title?: unknown; author?: unknown; language?: unknown }
    toc?: TocItem[]
    sections: { id: unknown; linear?: string }[]
    dir?: string
    rendition?: { layout?: string }
  }

  export interface RelocateDetail {
    fraction: number
    section?: { current: number; total: number }
    location?: { current: number; next: number; total: number }
    tocItem?: { label?: string; href?: string } | null
    pageItem?: { label?: string } | null
    cfi: string
  }

  export interface Renderer extends HTMLElement {
    setStyles?: (css: string) => void
    next: () => Promise<void>
    prev: () => Promise<void>
  }

  export interface FoliateView extends HTMLElement {
    book: FoliateBook
    renderer: Renderer
    isFixedLayout: boolean
    lastLocation: RelocateDetail | null
    open(book: File | Blob | string): Promise<void>
    close(): void
    init(opts: { lastLocation?: Target | null; showTextStart?: boolean }): Promise<void>
    goTo(target: Target): Promise<unknown>
    goToFraction(fraction: number): Promise<void>
    next(): Promise<void>
    prev(): Promise<void>
    goLeft(): Promise<void>
    goRight(): Promise<void>
  }

  export class ResponseError extends Error {}
  export class NotFoundError extends Error {}
  export class UnsupportedTypeError extends Error {}
}
