import { useState } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { Check, ExternalLink, Loader2, Search, WandSparkles } from "lucide-react"
import { ApiError, write, type Book, type MetadataCandidate } from "@/lib/api"
import { metadataCandidatesQuery } from "@/lib/queries"
import { storeBook } from "@/lib/mutations"
import type { BookForm } from "@/lib/book-form"
import { asMetadataField, CANDIDATE_FIELDS, candidateLabel, formatValue, formValue, sameValue, sourceLabel, type CandidateField } from "@/lib/metadata"
import { percent } from "@/lib/kategorie"
import { t } from "@/i18n"
import { Button } from "./ui/button"
import { Badge } from "./ui/badge"
import { Input } from "./ui/input"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "./ui/dialog"
import { BookCover } from "./book-cover"

const errorText = (e: unknown) => (e instanceof ApiError ? e.message : String(e))
const source = (s: string) => {
  const key = sourceLabel(s)
  return key ? t(key) : s
}

// "Metadaten holen" in the edit form: what the book file, Open Library and
// the DNB know about the book. Taken fields go into the form (saved with
// it); a cover is set right away, like in the cover editor.
export function FetchMetadata({
  book,
  form,
  onApply,
  onCover,
}: {
  book: Book
  form: BookForm
  onApply: (field: CandidateField, value: unknown) => void
  onCover: (book: Book) => void
}) {
  const qc = useQueryClient()
  const [open, setOpen] = useState(false)
  // here and not in the dialog: survives closing it with "Alle übernehmen"
  const cover = useMutation({
    mutationFn: (url: string) => write.coverFromUrl(book.id, url),
    onSuccess: (b) => {
      storeBook(qc, b)
      onCover(b)
    },
  })
  return (
    <>
      <Button type="button" variant="outline" size="sm" onClick={() => setOpen(true)}>
        <WandSparkles /> {t("meta.fetch")}
      </Button>
      {cover.error && !open && (
        <p role="alert" className="text-xs text-destructive eink:font-bold">
          {t("cover.error")}: {errorText(cover.error)}
        </p>
      )}
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="sm:max-w-2xl">
          <DialogTitle className="text-lg font-semibold">{t("meta.fetch")}</DialogTitle>
          <DialogDescription className="text-sm text-muted-foreground eink:text-black">{t("meta.fetchHint")}</DialogDescription>
          <Candidates
            book={book}
            form={form}
            onApply={onApply}
            cover={cover}
            onAll={(c) => {
              for (const f of CANDIDATE_FIELDS) {
                const v = c.fields[f]
                if (v == null) continue
                if (f === "coverUrl") cover.mutate(String(v))
                else if (!sameValue(form, f, v)) onApply(f, v)
              }
              setOpen(false)
            }}
          />
        </DialogContent>
      </Dialog>
    </>
  )
}

function Candidates({
  book,
  form,
  onApply,
  onAll,
  cover,
}: {
  book: Book
  form: BookForm
  onApply: (field: CandidateField, value: unknown) => void
  onAll: (c: MetadataCandidate) => void
  cover: { mutate: (url: string) => void; isPending: boolean; error: Error | null; variables: string | undefined; isSuccess: boolean }
}) {
  const [q, setQ] = useState("")
  const [sentQ, setSentQ] = useState("")
  const { data, error, isFetching, refetch } = useQuery(metadataCandidatesQuery(book.id, sentQ))
  // no nested <form>: React would bubble its submit into the edit form
  const search = () => setSentQ(q.trim())

  return (
    <div className="space-y-4">
      <div className="flex gap-2">
        <Input
          value={q}
          onChange={(e) => setQ(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") {
              e.preventDefault()
              search()
            }
          }}
          placeholder={t("meta.search")}
          aria-label={t("meta.search")}
        />
        <Button type="button" variant="outline" size="icon" aria-label={t("meta.search")} onClick={search}>
          <Search />
        </Button>
      </div>
      {cover.error && (
        <p role="alert" className="text-sm text-destructive eink:font-bold">
          {t("cover.error")}: {errorText(cover.error)}
        </p>
      )}
      {isFetching ? (
        <p role="status" className="flex items-center gap-2 py-6 text-sm text-muted-foreground eink:text-black">
          <Loader2 className="size-4 animate-spin eink:animate-none" aria-hidden /> {t("meta.searching")}
        </p>
      ) : error ? (
        <div role="alert" className="space-y-2 text-sm">
          <p className="text-destructive eink:font-bold">
            {t("meta.fetchError")}: {errorText(error)}
          </p>
          <Button type="button" variant="outline" size="sm" onClick={() => refetch()}>
            {t("error.retry")}
          </Button>
        </div>
      ) : data && data.candidates.length === 0 ? (
        <p className="py-6 text-center">{t("meta.noCandidates")}</p>
      ) : (
        data && (
          <ul className="space-y-4" aria-label={t("meta.candidates")}>
            {data.candidates.map((c, i) => (
              <Candidate key={`${c.source}-${i}`} book={book} candidate={c} form={form} onApply={onApply} onAll={() => onAll(c)} cover={cover} />
            ))}
          </ul>
        )
      )}
    </div>
  )
}

function Candidate({
  book,
  candidate: c,
  form,
  onApply,
  onAll,
  cover,
}: {
  book: Book
  candidate: MetadataCandidate
  form: BookForm
  onApply: (field: CandidateField, value: unknown) => void
  onAll: () => void
  cover: { mutate: (url: string) => void; isPending: boolean; variables: string | undefined; isSuccess: boolean }
}) {
  const name = source(c.source)
  const fields = CANDIDATE_FIELDS.filter((f) => c.fields[f] != null)
  return (
    <li className="space-y-2 rounded-md border p-3 eink:border-2" aria-label={name}>
      <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
        <span className="font-medium">{name}</span>
        <span className="text-sm text-muted-foreground tabular-nums eink:text-black" title={t("meta.score")}>
          <span className="sr-only">{t("meta.score")}: </span>
          {percent(c.score)}
        </span>
        {c.sure && <Badge>{t("meta.sure")}</Badge>}
        {c.url && (
          <a
            href={c.url}
            target="_blank"
            rel="noreferrer"
            className="inline-flex items-center gap-1 text-sm underline-offset-2 hover:underline eink:min-h-11 touch:min-h-11"
          >
            <ExternalLink className="size-3.5" aria-hidden /> {t("meta.openSource", { source: name })}
          </a>
        )}
        <span className="flex-1" />
        <Button type="button" size="sm" onClick={onAll} aria-label={`${t("meta.takeAll")}: ${name}`}>
          {t("meta.takeAll")}
        </Button>
      </div>
      <ul className="divide-y text-sm eink:divide-y-2">
        {fields.map((f) => {
          const value = c.fields[f]
          const label = t(candidateLabel(f))
          const isCover = f === "coverUrl"
          const taken = isCover ? cover.isSuccess && cover.variables === value : sameValue(form, f, value)
          return (
            <li key={f} className="grid grid-cols-[1fr_auto] items-center gap-x-3 gap-y-1 py-2" aria-label={label}>
              <div className="min-w-0 space-y-0.5">
                <p className="font-medium">{label}</p>
                {isCover ? (
                  <div className="flex items-center gap-2">
                    <BookCover book={book} compact className="w-12" />
                    <span aria-hidden>→</span>
                    <img src={String(value)} alt={t("meta.field.cover")} loading="lazy" referrerPolicy="no-referrer" className="h-16 w-12 rounded-sm bg-muted object-cover eink:border-2 eink:border-black" />
                  </div>
                ) : (
                  <>
                    <p className="break-words text-muted-foreground eink:text-black">
                      <span className="text-xs">{t("meta.current")}: </span>
                      {formatValue(asMetadataField(f), formValue(form, f))}
                    </p>
                    <p className="break-words">
                      <span className="text-xs text-muted-foreground eink:text-black">{t("meta.found")}: </span>
                      {formatValue(asMetadataField(f), value)}
                    </p>
                  </>
                )}
              </div>
              {taken ? (
                <span className="flex items-center gap-1 text-xs text-muted-foreground eink:text-sm eink:text-black">
                  <Check className="size-4" aria-hidden /> {t(isCover ? "meta.taken" : "meta.same")}
                </span>
              ) : (
                <Button
                  type="button"
                  size="sm"
                  variant="outline"
                  disabled={isCover && cover.isPending}
                  onClick={() => (isCover ? cover.mutate(String(value)) : onApply(f, value))}
                  aria-label={`${t("meta.take")}: ${label} (${name})`}
                >
                  {isCover && cover.isPending && cover.variables === value ? <Loader2 className="animate-spin eink:animate-none" /> : null}
                  {t("meta.take")}
                </Button>
              )}
            </li>
          )
        })}
      </ul>
    </li>
  )
}
