import type { ReactNode } from "react"
import { useQuery } from "@tanstack/react-query"
import { Download, Pencil } from "lucide-react"
import { categoryOf, DEFAULT_CONFIG, downloadUrl, type Book, type BookPatch } from "@/lib/api"
import { bookQuery, configQuery } from "@/lib/queries"
import { toggleTag, withFilter } from "@/lib/search"
import { formatDate, languageName, t } from "@/i18n"
import { cn } from "@/lib/utils"
import { BookCover } from "./book-cover"
import { formatIndex } from "./book-grid"
import { ErrorMessage } from "./error-view"
import { Button, buttonVariants } from "./ui/button"
import { BookEdit } from "./book-edit"
import { ListButtons } from "./lists"
import { listLabel, listsQuery } from "@/lib/lists"
import { DeleteBookButton } from "./delete-book"
import { EpubFixButton } from "./epub-fix"
import { SuggestionBox } from "./suggestion-box"
import { Badge } from "./ui/badge"
import { LibraryLink } from "@/components/library-link"
import { ReadButton } from "./reading"
import { OfflineButton } from "./offline"
import { readerFormat, sortFormats } from "@/lib/reader"
import { sanitize } from "@/lib/sanitize"
import { useIsAdmin } from "@/lib/session"
import { PrivateTags } from "./private-tags"

export { sortFormats } from "@/lib/reader"

interface DetailProps {
  id: number
  placeholder?: Book
  onNavigate?: () => void
  edit?: boolean
  onEdit?: (on: boolean) => void
  // after saving the form; default: back to the detail
  onSaved?: (patch: BookPatch, opts: { carry: boolean }) => void
  prefillKategorie?: string | null
  // after the book went to the trash
  onDeleted?: () => void
}

export function BookDetail({ id, placeholder, onNavigate, edit, onEdit: canEdit, onSaved, onDeleted: canDelete, prefillKategorie }: DetailProps) {
  // list rows have everything except comments; show them right away
  const { data, error, refetch, isPlaceholderData } = useQuery({ ...bookQuery(id), placeholderData: placeholder })
  // readers neither edit nor delete
  const admin = useIsAdmin()
  const onEdit = admin ? canEdit : undefined
  const onDeleted = admin ? canDelete : undefined
  if (error && !data) return <ErrorMessage error={error} onRetry={() => refetch()} />
  if (!data) return <p className="p-8 text-muted-foreground">{t("loading")}</p>
  // the form needs the full book (comments)
  if (edit && onEdit) {
    return isPlaceholderData ? <p className="p-8 text-muted-foreground">{t("loading")}</p> : <BookEdit key={data.id} book={data} onDone={() => onEdit(false)} onSaved={onSaved} prefillKategorie={prefillKategorie} />
  }
  return <BookView book={data} onNavigate={onNavigate} onEdit={onEdit && (() => onEdit(true))} onDeleted={onDeleted} />
}

function BookView({ book, onNavigate, onEdit, onDeleted }: { book: Book; onNavigate?: () => void; onEdit?: () => void; onDeleted?: () => void }) {
  const { data: config = DEFAULT_CONFIG } = useQuery(configQuery)
  const admin = useIsAdmin()
  const kategorie = categoryOf(book, config.categoryColumn)
  const formats = sortFormats(book.formats)
  // reading in the browser is the primary action, downloads come after it
  const readable = readerFormat(book) != null
  const { data: lists } = useQuery(listsQuery)
  const inLists = lists?.filter((l) => book.lists?.includes(l.id)) ?? []
  // E-Ink: links become 44 px tall tap targets
  const link = "underline-offset-2 hover:underline eink:inline-flex eink:min-h-11 eink:items-center touch:inline-flex touch:min-h-11 touch:items-center eink:underline"

  return (
    <article className="space-y-6 pb-6">
      {/* phones: a small cover next to the title, the actions below both, so
          title and downloads fit on the first screen; wider: cover on the left */}
      <div className="grid grid-cols-[6.5rem_minmax(0,1fr)] gap-x-4 gap-y-4 sm:grid-cols-[11rem_minmax(0,1fr)] sm:grid-rows-[auto_1fr] sm:gap-x-5 sm:gap-y-2">
        <BookCover book={book} thumb={false} progress className="w-full self-start sm:row-span-2" />
        <div className="min-w-0 space-y-2">
          <h1 className="text-xl leading-tight font-semibold text-balance sm:text-2xl">{book.title}</h1>
          <p className="sm:text-lg">
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
        </div>
        {/* reading first: the downloads, then the management actions */}
        <div className="col-span-2 min-w-0 space-y-2 sm:col-span-1 sm:col-start-2">
          <div className="flex flex-wrap gap-2 sm:pt-2">
            {formats.length === 0 && <p className="text-muted-foreground eink:text-black">{t("book.noFormats")}</p>}
            <ReadButton book={book} />
            {formats.map((f, i) => (
              <a key={f} href={downloadUrl(book.id, f)} download className={buttonVariants({ variant: i === 0 && !readable ? "default" : "outline" })}>
                <Download aria-hidden /> {f}
              </a>
            ))}
          </div>
          <div className="flex flex-wrap gap-2">
            {onEdit && (
              <Button type="button" variant="outline" onClick={onEdit}>
                <Pencil /> {t("book.edit")}
              </Button>
            )}
            <ListButtons book={book} />
            {onEdit && <EpubFixButton book={book} />}
            <OfflineButton book={book} />
            {onDeleted && <DeleteBookButton book={book} onDeleted={onDeleted} />}
          </div>
        </div>
      </div>

      {admin && <SuggestionBox book={book} />}

      <dl className="grid grid-cols-[auto_1fr] gap-x-6 gap-y-2 text-sm eink:text-base">
        {inLists.length > 0 && (
          <Row label={t("list.inLists")}>
            <span className="flex flex-wrap gap-1.5">
              {inLists.map((l) => (
                <LibraryLink key={l.id} search={withFilter({}, { list: l.id })} onClick={onNavigate} className="eink:inline-flex eink:min-h-11 eink:items-center touch:inline-flex touch:min-h-11 touch:items-center">
                  <Badge variant="outline">{listLabel(l)}</Badge>
                </LibraryLink>
              ))}
            </span>
          </Row>
        )}
        {kategorie && (
          <Row label={t("book.kategorie")}>
            <Breadcrumb path={kategorie} onNavigate={onNavigate} />
          </Row>
        )}
        {book.tags.length > 0 && (
          <Row label={t("book.tags")}>
            <span className="flex flex-wrap gap-1.5">
              {book.tags.map((tag) => (
                <LibraryLink key={tag} search={toggleTag({}, tag)} onClick={onNavigate} className="eink:inline-flex eink:min-h-11 eink:items-center touch:inline-flex touch:min-h-11 touch:items-center">
                  <Badge variant="secondary">{tag}</Badge>
                </LibraryLink>
              ))}
            </span>
          </Row>
        )}
        {/* the user's own, apart from calibre's shared tags (older hubs: none) */}
        {book.privateTags && (
          <Row label={t("book.privateTags")}>
            <PrivateTags book={book} onNavigate={onNavigate} />
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

// stored "A.B", shown as "A/B" with a link per level
function Breadcrumb({ path, onNavigate }: { path: string; onNavigate?: () => void }) {
  const parts = path.split(".")
  return (
    <span>
      {parts.map((p, i) => (
        <span key={i}>
          {i > 0 && "/"}
          <LibraryLink search={withFilter({}, { kategorie: parts.slice(0, i + 1).join(".") })} onClick={onNavigate} className="underline-offset-2 hover:underline eink:inline-flex eink:min-h-11 eink:items-center touch:inline-flex touch:min-h-11 touch:items-center eink:underline">
            {p}
          </LibraryLink>
        </span>
      ))}
    </span>
  )
}

function Comments({ html }: { html: string }) {
  return (
    <div
      className="max-w-prose space-y-3 leading-relaxed [&_a]:underline [&_li]:ml-5 [&_ol]:list-decimal [&_ul]:list-disc eink:text-lg"
      dangerouslySetInnerHTML={{ __html: sanitize(html) }}
    />
  )
}
