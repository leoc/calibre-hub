import { useState, type ClipboardEvent, type DragEvent } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { FileDown, ImageUp, Link2, Search } from "lucide-react"
import { write, type Book } from "@/lib/api"
import { storeBook } from "@/lib/mutations"
import { toCoverImage } from "@/lib/image"
import { t } from "@/i18n"
import { cn } from "@/lib/utils"
import { BookCover } from "./book-cover"
import { Button } from "./ui/button"
import { Input } from "./ui/input"

// Cover changes apply right away (not part of the form's save).
export function CoverEditor({ book }: { book: Book }) {
  const qc = useQueryClient()
  const [open, setOpen] = useState(false)
  const [url, setUrl] = useState("")
  const [searching, setSearching] = useState(false)
  const [over, setOver] = useState(false)
  const apply = useMutation({
    mutationFn: (fn: () => Promise<Book>) => fn(),
    onSuccess: (b) => {
      storeBook(qc, b)
      setUrl("")
    },
  })
  const hits = useQuery({
    queryKey: ["coverSearch", book.id],
    queryFn: () => write.coverSearch(book.id),
    enabled: searching,
    staleTime: Infinity,
  })
  const upload = (file: Blob | null | undefined) => {
    if (file && file.type.startsWith("image/")) apply.mutate(async () => write.coverUpload(book.id, await toCoverImage(file)))
  }
  const onDrop = (e: DragEvent) => {
    e.preventDefault()
    e.stopPropagation()
    setOver(false)
    upload(e.dataTransfer.files[0])
  }
  const onPaste = (e: ClipboardEvent) => {
    const item = [...e.clipboardData.items].find((i) => i.type.startsWith("image/"))
    if (item) {
      e.preventDefault()
      upload(item.getAsFile())
    }
  }

  return (
    <div
      className="w-40 shrink-0 space-y-2 self-center sm:w-44 sm:self-start"
      onDragOver={(e) => {
        if ([...e.dataTransfer.types].includes("Files")) {
          e.preventDefault()
          e.stopPropagation()
          setOver(true)
        }
      }}
      onDragLeave={() => setOver(false)}
      onDrop={onDrop}
      onPaste={onPaste}
    >
      <div className={cn("relative rounded-md", over && "ring-4 ring-ring", apply.isPending && "opacity-50")}>
        <BookCover book={book} thumb={false} />
      </div>
      {!open ? (
        <Button type="button" variant="outline" size="sm" className="w-full" onClick={() => setOpen(true)}>
          {t("cover.change")}
        </Button>
      ) : (
        <div className="space-y-2" tabIndex={-1}>
          <label className={cn("flex w-full cursor-pointer items-center justify-center gap-2 rounded-md border px-2 py-1.5 text-sm hover:bg-accent eink:border-2 eink:py-3")}>
            <ImageUp className="size-4" /> {t("cover.upload")}
            <input type="file" accept="image/*" className="sr-only" onChange={(e) => upload(e.target.files?.[0])} />
          </label>
          <p className="text-xs text-muted-foreground eink:text-black">{t("cover.pasteHint")}</p>
          <Button type="button" variant="outline" size="sm" className="w-full" disabled={!book.formats.length} onClick={() => apply.mutate(() => write.coverFromFile(book.id))}>
            <FileDown /> {t("cover.fromFile")}
          </Button>
          <div className="flex gap-1">
            <Input
              value={url}
              onChange={(e) => setUrl(e.target.value)}
              placeholder={t("cover.urlPlaceholder")}
              aria-label={t("cover.fromUrl")}
              className="h-8 text-sm"
              onKeyDown={(e) => {
                if (e.key === "Enter") {
                  e.preventDefault()
                  if (url.trim()) apply.mutate(() => write.coverFromUrl(book.id, url.trim()))
                }
              }}
            />
            <Button type="button" variant="outline" size="icon" aria-label={t("cover.fromUrl")} disabled={!url.trim()} onClick={() => apply.mutate(() => write.coverFromUrl(book.id, url.trim()))}>
              <Link2 />
            </Button>
          </div>
          <Button type="button" variant="outline" size="sm" className="w-full" onClick={() => setSearching(true)}>
            <Search /> {hits.isFetching ? t("cover.searching") : t("cover.search")}
          </Button>
          {apply.error && (
            <p role="alert" className="text-xs text-destructive eink:font-bold">
              {t("cover.error")}: {apply.error.message}
            </p>
          )}
        </div>
      )}
      {searching && hits.data && (
        <div className="space-y-1">
          {hits.data.length === 0 && <p className="text-xs">{t("cover.noHits")}</p>}
          <ul className="grid grid-cols-2 gap-2">
            {hits.data.map((h) => (
              <li key={h.url}>
                <button
                  type="button"
                  onClick={() => apply.mutate(() => write.coverFromUrl(book.id, h.url))}
                  className="block w-full rounded-sm text-left hover:ring-2 hover:ring-ring"
                  title={h.source}
                >
                  <img src={h.url} alt="" loading="lazy" referrerPolicy="no-referrer" className="aspect-[3/4] w-full rounded-sm bg-muted object-cover" />
                  <span className="block truncate text-[10px] text-muted-foreground eink:text-black">
                    {h.source}
                    {h.width && h.height ? ` · ${h.width}×${h.height}` : ""}
                  </span>
                </button>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  )
}
