import type { ReactNode } from "react"
import { useQuery } from "@tanstack/react-query"
import { Download } from "lucide-react"
import { categoryOf, DEFAULT_CONFIG, downloadUrl, type Book } from "@/lib/api"
import { bookQuery, configQuery } from "@/lib/queries"
import { toggleTag, withFilter } from "@/lib/search"
import { formatDate, languageName, t } from "@/i18n"
import { cn } from "@/lib/utils"
import { BookCover } from "./book-cover"
import { formatIndex } from "./book-grid"
import { ErrorMessage } from "./error-view"
import { buttonVariants } from "./ui/button"
import { Badge } from "./ui/badge"
import { LibraryLink } from "@/components/library-link"

// Order in which formats are offered; the first is the primary button.
const FORMAT_ORDER = ["EPUB", "KEPUB", "AZW3", "MOBI", "PDF", "CBZ", "CBR", "DJVU", "TXT"]
const sortFormats = (f: string[]) =>
  [...f].sort((a, b) => (FORMAT_ORDER.indexOf(a) + 1 || 99) - (FORMAT_ORDER.indexOf(b) + 1 || 99))

export function BookDetail({ id, placeholder, onNavigate }: { id: number; placeholder?: Book; onNavigate?: () => void }) {
  // list rows have everything except comments; show them right away
  const { data, error, refetch } = useQuery({ ...bookQuery(id), placeholderData: placeholder })
  if (error && !data) return <ErrorMessage error={error} onRetry={() => refetch()} />
  if (!data) return <p className="p-8 text-muted-foreground">{t("loading")}</p>
  return <BookView book={data} onNavigate={onNavigate} />
}

function BookView({ book, onNavigate }: { book: Book; onNavigate?: () => void }) {
  const { data: config = DEFAULT_CONFIG } = useQuery(configQuery)
  const kategorie = categoryOf(book, config.categoryColumn)
  const formats = sortFormats(book.formats)
  const link = "underline-offset-2 hover:underline eink:underline"

  return (
    <article className="space-y-6">
      <div className="flex flex-col gap-5 sm:flex-row">
        <BookCover book={book} thumb={false} className="w-40 shrink-0 self-center sm:w-44 sm:self-start" />
        <div className="min-w-0 space-y-2">
          <h1 className="text-2xl leading-tight font-semibold text-balance">{book.title}</h1>
          <p className="text-lg">
            {book.authors.map((a, i) => (
              <span key={a}>
                {i > 0 && ", "}
                <LibraryLink search={withFilter({}, { author: a })} onClick={onNavigate} className={link}>
                  {a}
                </LibraryLink>
              </span>
            ))}
          </p>
          {book.series && (
            <p>
              <LibraryLink search={withFilter({}, { series: book.series })} onClick={onNavigate} className={cn(link, "italic")}>
                {book.series}
              </LibraryLink>
              {book.seriesIndex != null && <span className="text-muted-foreground eink:text-black"> · {t("book.volume")} {formatIndex(book.seriesIndex)}</span>}
            </p>
          )}
          <div className="flex flex-wrap gap-2 pt-2">
            {formats.length === 0 && <p className="text-muted-foreground">{t("book.noFormats")}</p>}
            {formats.map((f, i) => (
              <a key={f} href={downloadUrl(book.id, f)} download className={buttonVariants({ variant: i === 0 ? "default" : "outline" })}>
                <Download aria-hidden /> {f}
              </a>
            ))}
          </div>
        </div>
      </div>

      <dl className="grid grid-cols-[auto_1fr] gap-x-6 gap-y-2 text-sm eink:text-base">
        {kategorie && (
          <Row label={t("book.kategorie")}>
            <Breadcrumb path={kategorie} onNavigate={onNavigate} />
          </Row>
        )}
        {book.tags.length > 0 && (
          <Row label={t("book.tags")}>
            <span className="flex flex-wrap gap-1.5">
              {book.tags.map((tag) => (
                <LibraryLink key={tag} search={toggleTag({}, tag)} onClick={onNavigate}>
                  <Badge variant={config.fastTags.includes(tag) ? "default" : "secondary"}>{tag}</Badge>
                </LibraryLink>
              ))}
            </span>
          </Row>
        )}
        {book.languages.length > 0 && (
          <Row label={t("book.languages")}>
            {book.languages.map((l, i) => (
              <span key={l}>
                {i > 0 && ", "}
                <LibraryLink search={withFilter({}, { lang: l })} onClick={onNavigate} className={link}>
                  {languageName(l)}
                </LibraryLink>
              </span>
            ))}
          </Row>
        )}
        {book.publisher && <Row label={t("book.publisher")}>{book.publisher}</Row>}
        {book.pubdate && new Date(book.pubdate).getFullYear() > 101 && <Row label={t("book.published")}>{formatDate(book.pubdate)}</Row>}
        {book.added && <Row label={t("book.added")}>{formatDate(book.added)}</Row>}
        {book.rating != null && book.rating > 0 && <Row label={t("book.rating")}>{"★".repeat(Math.round(book.rating / 2))}</Row>}
        {Object.keys(book.identifiers).length > 0 && (
          <Row label={t("book.identifiers")}>
            <span className="break-all">{Object.entries(book.identifiers).map(([k, v]) => `${k}: ${v}`).join(" · ")}</span>
          </Row>
        )}
      </dl>

      {book.comments && <Comments html={book.comments} />}
    </article>
  )
}

function Row({ label, children }: { label: string; children: ReactNode }) {
  return (
    <>
      <dt className="text-muted-foreground eink:font-bold eink:text-black">{label}</dt>
      <dd className="min-w-0">{children}</dd>
    </>
  )
}

function Breadcrumb({ path, onNavigate }: { path: string; onNavigate?: () => void }) {
  const parts = path.split(".")
  return (
    <span>
      {parts.map((p, i) => (
        <span key={i}>
          {i > 0 && " › "}
          <LibraryLink search={withFilter({}, { kategorie: parts.slice(0, i + 1).join(".") })} onClick={onNavigate} className="underline-offset-2 hover:underline eink:underline">
            {p}
          </LibraryLink>
        </span>
      ))}
    </span>
  )
}

// calibre comments are HTML from the user's own library; strip scripts,
// handlers and styles anyway before rendering.
export function sanitize(html: string): string {
  const doc = new DOMParser().parseFromString(html, "text/html")
  doc.querySelectorAll("script,style,iframe,object,embed,link,meta,form").forEach((n) => n.remove())
  doc.querySelectorAll("*").forEach((el) => {
    for (const a of [...el.attributes]) {
      if (a.name.startsWith("on") || a.name === "style" || ((a.name === "href" || a.name === "src") && /^\s*javascript:/i.test(a.value))) {
        el.removeAttribute(a.name)
      }
    }
    if (el.tagName === "A") el.setAttribute("rel", "noopener noreferrer")
  })
  return doc.body.innerHTML
}

function Comments({ html }: { html: string }) {
  return (
    <div
      className="max-w-prose space-y-3 leading-relaxed [&_a]:underline [&_li]:ml-5 [&_ol]:list-decimal [&_ul]:list-disc eink:text-lg"
      dangerouslySetInnerHTML={{ __html: sanitize(html) }}
    />
  )
}
