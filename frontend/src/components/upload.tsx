import { useEffect, useRef, useState } from "react"
import { CheckCircle2, ChevronDown, CircleAlert, Copy, Inbox, Loader2, Pencil, Upload as UploadIcon, X } from "lucide-react"
import { Link, useNavigate } from "@tanstack/react-router"
import type { UploadOptions } from "@/lib/api"
import { addUploads, clearFinished, dismissUpload, retryUpload, useUploads, type UploadItem } from "@/lib/upload-store"
import { categoryLabel } from "@/lib/kategorie"
import { useLibrarySearch } from "@/lib/use-library"
import { useDesktop } from "@/lib/use-media"
import { t } from "@/i18n"
import { cn } from "@/lib/utils"
import { Button } from "./ui/button"
import { Dialog, DialogContent, DialogTitle } from "./ui/dialog"

const ACCEPT = ".epub,.kepub,.pdf,.azw,.azw3,.mobi,.cbz,.cbr,.djvu,.fb2,.txt,.rtf,.docx,.odt,.lit,.lrf"

// Filters active in the library become a suggestion for the new books.
function useSuggestedOptions(): UploadOptions {
  const s = useLibrarySearch()
  return { kategorie: s.kategorie, tags: s.tag }
}

let pickFiles: ((files: File[]) => void) | null = null

export function UploadButton({ className }: { className?: string }) {
  return (
    <label
      className={cn(
        "inline-flex size-9 shrink-0 cursor-pointer items-center justify-center rounded-md hover:bg-accent has-focus-visible:ring-[3px] has-focus-visible:ring-ring/50 eink:size-12 touch:size-11",
        className,
      )}
      title={t("upload.button")}
    >
      <UploadIcon className="size-5" aria-hidden />
      <span className="sr-only">{t("upload.button")}</span>
      <input
        type="file"
        multiple
        accept={ACCEPT}
        className="sr-only"
        onChange={(e) => {
          pickFiles?.([...(e.target.files ?? [])])
          e.target.value = ""
        }}
      />
    </label>
  )
}

// Window-wide drop target, the confirmation for suggested metadata and the tray.
export function UploadHost() {
  const [dragging, setDragging] = useState(false)
  const [pending, setPending] = useState<File[] | null>(null)
  const suggested = useSuggestedOptions()
  const hasSuggestion = !!suggested.kategorie || !!suggested.tags?.length

  const start = (files: File[]) => {
    if (!files.length) return
    if (hasSuggestion) setPending(files)
    else addUploads(files, {})
  }
  // the listeners below are registered once; they call the current start
  const startRef = useRef(start)
  useEffect(() => {
    startRef.current = start
  })

  // Registered once: re-registering on every render would reset the
  // enter/leave counter, and the overlay would vanish while dragging.
  useEffect(() => {
    pickFiles = (files) => startRef.current(files)
    let depth = 0
    const isFiles = (e: DragEvent) => [...(e.dataTransfer?.types ?? [])].includes("Files")
    const enter = (e: DragEvent) => {
      if (!isFiles(e)) return
      depth++
      setDragging(true)
    }
    const leave = (e: DragEvent) => {
      if (!isFiles(e)) return
      if (--depth <= 0) {
        depth = 0
        setDragging(false)
      }
    }
    const over = (e: DragEvent) => isFiles(e) && e.preventDefault()
    const drop = (e: DragEvent) => {
      if (!isFiles(e) || e.defaultPrevented) {
        depth = 0
        setDragging(false)
        return
      }
      e.preventDefault()
      depth = 0
      setDragging(false)
      startRef.current([...(e.dataTransfer?.files ?? [])])
    }
    window.addEventListener("dragenter", enter)
    window.addEventListener("dragleave", leave)
    window.addEventListener("dragover", over)
    window.addEventListener("drop", drop)
    return () => {
      pickFiles = null
      window.removeEventListener("dragenter", enter)
      window.removeEventListener("dragleave", leave)
      window.removeEventListener("dragover", over)
      window.removeEventListener("drop", drop)
    }
  }, [])

  return (
    <>
      {dragging && (
        <div className="pointer-events-none fixed inset-0 z-[60] flex items-center justify-center bg-background/80 eink:bg-white">
          <div className="rounded-xl border-4 border-dashed border-primary px-10 py-8 text-xl font-medium">{t("upload.drop")}</div>
        </div>
      )}
      {pending && <ConfirmDialog files={pending} suggested={suggested} onClose={() => setPending(null)} />}
      <UploadTray />
    </>
  )
}

function ConfirmDialog({ files, suggested, onClose }: { files: File[]; suggested: UploadOptions; onClose: () => void }) {
  const [useKategorie, setUseKategorie] = useState(true)
  const [useTags, setUseTags] = useState<string[]>(suggested.tags ?? [])
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent aria-describedby={undefined}>
        <DialogTitle className="text-lg font-semibold">{t("upload.confirm", { count: files.length })}</DialogTitle>
        <ul className="max-h-32 overflow-y-auto text-sm text-muted-foreground eink:text-black">
          {files.map((f) => (
            <li key={f.name} className="truncate">
              {f.name}
            </li>
          ))}
        </ul>
        <p className="text-sm">{t("upload.suggestion")}</p>
        <div className="space-y-2">
          {suggested.kategorie && (
            <label className="flex items-center gap-2 eink:min-h-11 touch:min-h-11">
              <input type="checkbox" checked={useKategorie} onChange={(e) => setUseKategorie(e.target.checked)} className="size-4 eink:size-6" />
              {t("book.kategorie")}: {categoryLabel(suggested.kategorie)}
            </label>
          )}
          {suggested.tags?.map((tag) => (
            <label key={tag} className="flex items-center gap-2 eink:min-h-11 touch:min-h-11">
              <input
                type="checkbox"
                checked={useTags.includes(tag)}
                onChange={(e) => setUseTags(e.target.checked ? [...useTags, tag] : useTags.filter((x) => x !== tag))}
                className="size-4 eink:size-6"
              />
              {t("filter.tag")}: {tag}
            </label>
          ))}
        </div>
        <div className="flex justify-end gap-2">
          <Button variant="outline" onClick={onClose}>
            {t("edit.cancel")}
          </Button>
          <Button
            onClick={() => {
              addUploads(files, { kategorie: useKategorie ? suggested.kategorie : undefined, tags: useTags.length ? useTags : undefined })
              onClose()
            }}
          >
            {t("upload.start")}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  )
}

function UploadTray() {
  const items = useUploads()
  const [collapsed, setCollapsed] = useState(false)
  if (!items.length) return null
  const active = items.filter((i) => i.status === "queued" || i.status === "uploading" || i.status === "checking").length
  const problems = items.filter((i) => i.status === "error" || i.status === "duplicate" || i.status === "gone").length
  return (
    <section
      aria-label={t("upload.title")}
      className="fixed right-[max(0.75rem,env(safe-area-inset-right))] bottom-[max(0.75rem,env(safe-area-inset-bottom))] z-40 w-[min(26rem,calc(100vw-1.5rem))] rounded-lg border bg-background shadow-xl eink:border-2 eink:shadow-none"
    >
      <header className={cn("flex items-center gap-2 py-1 pr-1 pl-3", !collapsed && "border-b eink:border-b-2")}>
        <button className="flex min-h-9 flex-1 items-center gap-2 text-left text-sm font-medium eink:min-h-12 touch:min-h-11 eink:text-base" onClick={() => setCollapsed(!collapsed)} aria-expanded={!collapsed}>
          <span className="flex-1">
            {active
              ? t("upload.running", { count: active })
              : problems
                ? t("upload.finishedProblems", { done: items.length - problems, problems })
                : t("upload.finished", { count: items.length })}
          </span>
          <ChevronDown className={cn("size-4 shrink-0 transition-transform", collapsed && "rotate-180")} aria-hidden />
        </button>
        {!active && (
          <Button variant="ghost" size="icon" onClick={clearFinished} aria-label={t("book.close")}>
            <X />
          </Button>
        )}
      </header>
      {!collapsed && (
        <ul className="max-h-[50vh] divide-y overflow-y-auto eink:divide-y-2 eink:divide-black">
          {items.map((i) => (
            <Row key={i.id} item={i} />
          ))}
        </ul>
      )}
    </section>
  )
}

function Row({ item }: { item: UploadItem }) {
  const navigate = useNavigate()
  const desktop = useDesktop()
  const open = (id: number, edit = false) =>
    desktop ? navigate({ to: "/", search: { book: id, edit: edit || undefined } }) : navigate({ to: "/books/$id", params: { id }, search: { edit: edit || undefined } })
  const ext = item.file.name.split(".").pop()?.toUpperCase() ?? ""
  return (
    <li className="space-y-1.5 px-3 py-2 text-sm">
      <div className="flex items-center gap-2">
        {item.status === "done" ? (
          <CheckCircle2 className="size-4 shrink-0" />
        ) : item.status === "waiting" ? (
          <Inbox className="size-4 shrink-0" />
        ) : item.status === "error" || item.status === "duplicate" || item.status === "gone" ? (
          <CircleAlert className="size-4 shrink-0 text-destructive eink:text-black" />
        ) : (
          <Loader2 className="size-4 shrink-0 animate-spin" />
        )}
        <span className="min-w-0 flex-1 truncate" title={item.file.name}>
          {item.book?.title ?? item.file.name}
        </span>
        {item.status !== "uploading" && (
          <button onClick={() => dismissUpload(item.id)} aria-label={t("book.close")} className="-my-1 flex size-7 shrink-0 items-center justify-center rounded-sm hover:bg-accent eink:size-12 touch:size-11">
            <X className="size-3.5" />
          </button>
        )}
      </div>
      {item.status === "uploading" && (
        <div className="h-1.5 overflow-hidden rounded-full bg-muted eink:border eink:border-black" role="progressbar" aria-valuenow={Math.round(item.progress * 100)}>
          <div className="h-full bg-primary" style={{ width: `${item.progress * 100}%` }} />
        </div>
      )}
      {item.status === "error" && <p className="text-xs text-destructive eink:text-black">{item.error}</p>}
      {item.status === "checking" && <p className="text-xs">{t("upload.checking")}</p>}
      {item.status === "gone" && <p className="text-xs">{t("upload.gone")}</p>}
      {item.status === "waiting" && (
        <p className="text-xs">
          {item.confidence != null && item.threshold != null ? t("upload.waiting", { value: item.confidence, threshold: item.threshold }) : t("upload.waitingPlain")}{" "}
          <Link to="/eingang" className="underline underline-offset-2">
            {t("upload.toIntake")}
          </Link>
        </p>
      )}
      {item.status === "done" && !!item.similar?.length && (
        <p className="text-xs">
          {t("dup.upload", { books: item.similar.map((b) => `#${b.id} „${b.title}“`).join(", ") })}{" "}
          <Link to="/duplicates" className="underline underline-offset-2">
            {t("dup.uploadLink")}
          </Link>
        </p>
      )}
      {item.status === "done" && item.book && (
        <div className="flex gap-2">
          <Button size="sm" variant="outline" onClick={() => open(item.book!.id)}>
            {t("upload.open")}
          </Button>
          <Button size="sm" variant="outline" onClick={() => open(item.book!.id, true)}>
            <Pencil /> {t("book.edit")}
          </Button>
        </div>
      )}
      {item.status === "duplicate" && (
        <div className="space-y-1.5">
          <p className="text-xs">{t(item.copy ? "upload.copy" : "upload.duplicate")}</p>
          {item.duplicates?.length ? (
            item.duplicates.map((d) => {
              const replaces = d.formats.includes(ext)
              return (
                <div key={d.id} className="flex flex-wrap items-center gap-2 rounded-sm bg-muted px-2 py-1 eink:border eink:border-black">
                  <button className="min-w-0 flex-1 truncate text-left underline-offset-2 hover:underline" onClick={() => open(d.id)}>
                    {d.title} · {d.authors.join(", ")} ({d.formats.join(", ") || "–"})
                  </button>
                  <Button
                    size="sm"
                    variant="outline"
                    onClick={() => {
                      if (!replaces || window.confirm(t("upload.replaceFormat", { format: ext, title: d.title }))) retryUpload(item.id, { addFormatTo: d.id })
                    }}
                  >
                    <Copy /> {replaces ? t("upload.replaceAs", { format: ext }) : t("upload.addAs", { format: ext })}
                  </Button>
                </div>
              )
            })
          ) : (
            <ul className="text-xs text-muted-foreground eink:text-black">
              {(item.duplicateTitles?.length ? item.duplicateTitles : [item.file.name]).map((title) => (
                <li key={title}>{title}</li>
              ))}
            </ul>
          )}
          {/* outline: adding a second copy is the exception, not the default */}
          <Button size="sm" variant="outline" onClick={() => retryUpload(item.id, { force: true })}>
            {t("upload.force")}
          </Button>
        </div>
      )}
    </li>
  )
}
