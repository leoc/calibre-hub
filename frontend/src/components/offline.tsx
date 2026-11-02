import { useState } from "react"
import { Link } from "@tanstack/react-router"
import { CloudCheck, CloudDownload, CloudOff, Loader2, Trash2 } from "lucide-react"
import type { Book } from "@/lib/api"
import { formatBytes, makeOffline, offlineSupported, removeOffline, useOfflineBook, useOfflineBooks } from "@/lib/offline"
import { useOnline } from "@/lib/online"
import { readerFormat } from "@/lib/reader"
import { cn } from "@/lib/utils"
import { t } from "@/i18n"
import { Button } from "./ui/button"

// "Offline verfügbar machen", or the stored size and "Offline entfernen"
// (detail and reader); only for books the reader opens
export function OfflineButton({ book, format, className }: { book: Book; format?: string; className?: string }) {
  const stored = useOfflineBook(book.id)
  const online = useOnline()
  const [busy, setBusy] = useState(false)
  const [failed, setFailed] = useState(false)
  const wanted = format ?? readerFormat(book)
  if (!offlineSupported() || !wanted) return null
  if (stored) {
    return (
      <div className={cn("flex flex-wrap items-center gap-2", className)}>
        <span className="flex items-center gap-1.5 text-sm text-muted-foreground eink:text-base eink:text-black" data-offline-size>
          <CloudCheck className="size-4" aria-hidden /> {t("offline.available", { size: formatBytes(stored.size) })}
        </span>
        <Button type="button" variant="outline" onClick={() => void removeOffline(book.id)}>
          <Trash2 /> {t("offline.remove")}
        </Button>
      </div>
    )
  }
  const save = async () => {
    setBusy(true)
    setFailed(false)
    try {
      await makeOffline(book, wanted)
    } catch (e) {
      console.error(e)
      setFailed(true)
    } finally {
      setBusy(false)
    }
  }
  return (
    <div className={cn("flex flex-wrap items-center gap-2", className)}>
      <Button type="button" variant="outline" disabled={busy || !online} onClick={save}>
        {busy ? <Loader2 className="animate-spin eink:animate-none" /> : <CloudDownload />} {busy ? t("offline.saving") : t("offline.make")}
      </Button>
      {failed && (
        <p role="alert" className="text-sm text-destructive eink:text-base eink:text-black">
          {t("offline.failed")}
        </p>
      )}
    </div>
  )
}

// "Offline" next to the header's buttons while there is no network
export function OfflineBadge({ className }: { className?: string }) {
  const online = useOnline()
  if (online) return null
  return (
    <span role="status" title={t("offline.status")} className={cn("flex shrink-0 items-center gap-1 rounded-full border px-2 py-0.5 text-xs font-medium eink:border-2 eink:border-black eink:text-sm", className)}>
      <CloudOff className="size-3.5" aria-hidden />
      {/* phones: the icon only */}
      <span className="sr-only sm:not-sr-only">{t("offline.status")}</span>
    </span>
  )
}

// The books stored offline, to read without the hub (the error page)
export function OfflineBooks() {
  const books = useOfflineBooks()
  if (books.length === 0) return null
  const size = formatBytes(books.reduce((n, b) => n + b.size, 0))
  return (
    <section aria-labelledby="offline-books" className="mx-auto w-full max-w-md px-4 pb-12">
      <h2 id="offline-books" className="text-base font-semibold">
        {t("offline.books")}
      </h2>
      <p className="text-sm text-muted-foreground eink:text-black">{books.length === 1 ? t("offline.totalOne", { size }) : t("offline.total", { count: books.length, size })}</p>
      <ul className="mt-2 divide-y rounded-md border eink:border-2 eink:border-black">
        {books.map(({ book, format, size }) => (
          <li key={book.id}>
            <Link to="/read/$id" params={{ id: book.id }} search={{ format }} className="flex flex-col px-3 py-2 hover:bg-accent eink:min-h-12 touch:min-h-11">
              <span className="font-medium">{book.title}</span>
              <span className="text-sm text-muted-foreground eink:text-black">
                {[book.authors.join(", "), format, formatBytes(size)].filter(Boolean).join(" · ")}
              </span>
            </Link>
          </li>
        ))}
      </ul>
    </section>
  )
}
