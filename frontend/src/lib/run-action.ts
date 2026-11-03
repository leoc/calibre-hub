import type { QueryClient } from "@tanstack/react-query"
import type { useNavigate } from "@tanstack/react-router"
import { formatNumber, t } from "@/i18n"
import { api, ApiError, downloadUrl, write, type Book, type BookPage, type BulkChanges, type MetadataTarget } from "./api"
import { changeValue, commandLabel, type ActionTarget, type ActionValue, type BookActionDef } from "./book-actions"
import { trackedJobs, type JobKind, type TrackedJob } from "./jobs"
import { changeList, listLabel, offerUndoAdd, offerUndoRemove, storeList } from "./lists"
import { storeBook } from "./mutations"
import { makeOffline } from "./offline"
import { readerFormat, sortFormats } from "./reader"
import { toast } from "./toast"

// Runs a command of src/lib/book-actions.ts on its books. Outside of React:
// the palette closes before the hub answers. Asking first (deleting, more
// than CONFIRM_ABOVE books) is the caller's part.

export interface RunContext {
  qc: QueryClient
  navigate: ReturnType<typeof useNavigate>
}

export const errorText = (e: unknown) => (e instanceof ApiError ? e.message : e instanceof Error ? e.message : String(e))
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

// A field change or a delete as a bulk job, watched by <JobWatcher>
export async function startChange(def: BookActionDef, target: ActionTarget, value: string | string[] | null, label: string): Promise<TrackedJob> {
  const changes: BulkChanges = def.changes!(value, target)
  const r = await write.bulk(target.bulk, changes)
  const job: TrackedJob = { id: r.jobId, total: r.total, kind: changes.delete ? "delete" : "bulk", label, target: target.bulk, changes, undoable: !changes.delete }
  trackedJobs.add(job)
  return job
}

const track = (kind: JobKind, label: string) => (r: { jobId: string; total: number }) => trackedJobs.add({ id: r.jobId, total: r.total, kind, label })

// The books themselves (formats for downloads): the cache first, then the hub
export async function targetBooks(qc: QueryClient, target: ActionTarget): Promise<Book[]> {
  if (target.book) return [target.book]
  if ("ids" in target.bulk) {
    const pages = qc.getQueriesData<BookPage>({ queryKey: ["books"] }).flatMap(([, p]) => p?.books ?? [])
    return Promise.all(
      target.bulk.ids.map((id) => qc.getQueryData<Book>(["book", id]) ?? pages.find((b) => b.id === id) ?? qc.fetchQuery({ queryKey: ["book", id], queryFn: () => api.book(id) })),
    )
  }
  const out: Book[] = []
  for (;;) {
    const page = await api.books({ ...target.bulk.query, offset: out.length, limit: 500 })
    out.push(...page.books)
    if (!page.books.length || out.length >= page.total) return out
  }
}

const targetIds = async (qc: QueryClient, target: ActionTarget) => ("ids" in target.bulk ? target.bulk.ids : (await targetBooks(qc, target)).map((b) => b.id))

// One request per book, one after another, with the progress in the toast
async function eachBook(books: Book[], label: string, fn: (b: Book) => Promise<unknown>): Promise<number> {
  let errors = 0
  for (const [i, b] of books.entries()) {
    if (books.length > 1) toast.show(t("actions.progress", { label, done: formatNumber(i), total: formatNumber(books.length) }))
    await fn(b).catch(() => errors++)
  }
  return errors
}

// After a change of private tags: the books (their tags) and the sidebar's counts
export async function refreshPrivateTags(qc: QueryClient) {
  await Promise.all([
    qc.invalidateQueries({ queryKey: ["books"] }),
    qc.invalidateQueries({ queryKey: ["book"] }),
    qc.invalidateQueries({ queryKey: ["categories"] }),
  ])
}

export async function runAction(ctx: RunContext, def: BookActionDef, target: ActionTarget, value?: ActionValue): Promise<void> {
  const { qc, navigate } = ctx
  // "Tag ‚Noten‘ hinzufügen (3)", also for a new one
  const label = commandLabel(def, target, value && { ...value, isNew: false })
  try {
    if (def.changes) {
      await startChange(def, target, value ? changeValue(value) : null, label)
      return
    }
    switch (def.id) {
      case "addPrivateTags":
      case "removePrivateTags": {
        if (!value) return
        const tag = changeValue(value)
        if (!tag) return
        const r = await write.privateTags(target.bulk, def.id === "addPrivateTags" ? { add: [tag] } : { remove: [tag] })
        await refreshPrivateTags(qc)
        toast.show(t("actions.privateTagsDone", { label, count: formatNumber(r.changed.length) }))
        return
      }
      case "addToList":
      case "removeFromList": {
        if (!value) return
        let list = { id: Number(value.value), name: value.label }
        if (value.isNew) {
          const created = await write.createList({ name: value.value })
          storeList(qc, created)
          qc.invalidateQueries({ queryKey: ["lists"] })
          list = created
        }
        const remove = def.id === "removeFromList"
        const r = await changeList(qc, list.id, target.bulk, remove)
        if (remove) offerUndoRemove(qc, r.list, r.removed ?? [])
        else offerUndoAdd(qc, r.list, r.added ?? [])
        return
      }
      case "newList": {
        if (!value) return
        const created = await write.createList({ name: value.value })
        storeList(qc, created)
        qc.invalidateQueries({ queryKey: ["lists"] })
        if (target.count) await changeList(qc, created.id, target.bulk)
        toast.show(t("actions.listCreated", { name: listLabel(created) }))
        await navigate({ to: "/", search: { list: created.id } })
        return
      }
      case "metadata":
        return void track("metadata", label)(await write.metadataRun(target.bulk as MetadataTarget))
      case "classify":
        return void track("classify", label)(await write.classify(target.bulk))
      case "epubFix":
        return void track("epubFix", label)(await write.epubFix(false, target.bulk))
      case "convert":
        return void track("convert", label)(await write.convert("EPUB", target.bulk))
      case "duplicates": {
        const ids = await targetIds(qc, target)
        await navigate({ to: "/duplicates", search: { ids: ids.join(",") } })
        return
      }
      case "cover": {
        const books = await targetBooks(qc, target)
        const errors = await eachBook(books, label, async (b) => storeBook(qc, await write.coverFromFile(b.id)))
        const done = formatNumber(books.length - errors)
        toast.show(errors ? t("actions.coverErrors", { count: done, errors: formatNumber(errors) }) : t("actions.coverDone", { count: done }))
        return
      }
      case "read":
        if (target.book) await navigate({ to: "/read/$id", params: { id: target.book.id } })
        return
      case "download": {
        const books = (await targetBooks(qc, target)).filter((b) => b.formats.length)
        // one after another: browsers drop clicks that come too fast (and
        // may ask once whether the site may download several files)
        for (const [i, b] of books.entries()) {
          if (i) await sleep(700)
          const a = document.createElement("a")
          a.href = downloadUrl(b.id, sortFormats(b.formats)[0])
          a.download = ""
          a.click()
        }
        if (books.length > 1) toast.show(t("actions.downloading", { count: formatNumber(books.length) }))
        return
      }
      case "copyLink": {
        const ids = await targetIds(qc, target)
        await navigator.clipboard.writeText(ids.map((id) => new URL(`/books/${id}`, location.origin).href).join("\n"))
        toast.show(ids.length === 1 ? t("actions.linkCopied") : t("actions.linksCopied", { count: formatNumber(ids.length) }))
        return
      }
      case "offline": {
        const books = (await targetBooks(qc, target)).filter((b) => readerFormat(b))
        const errors = await eachBook(books, label, (b) => makeOffline(b, readerFormat(b)!))
        const done = formatNumber(books.length - errors)
        toast.show(errors ? t("actions.offlineErrors", { count: done, errors: formatNumber(errors) }) : t("actions.offlineDone", { count: done }))
        return
      }
    }
  } catch (e) {
    toast.show(t("actions.failed", { label, error: errorText(e) }))
  }
}
