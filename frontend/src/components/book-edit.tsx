import { lazy, Suspense, useMemo, useRef, useState, type FormEvent, type ReactNode } from "react"
import { useQuery } from "@tanstack/react-query"
import { useBlocker } from "@tanstack/react-router"
import { Plus, Star, Trash2 } from "lucide-react"
import { DEFAULT_CONFIG, type Book } from "@/lib/api"
import { categoriesQuery, configQuery } from "@/lib/queries"
import { ConflictError, useUpdateBook } from "@/lib/mutations"
import { changedFields, toForm, toPatch, type BookForm } from "@/lib/book-form"
import { flattenTree } from "@/lib/palette"
import { languageName, t } from "@/i18n"
import type { MessageKey } from "@/i18n/de"
import { cn } from "@/lib/utils"
import { Button } from "./ui/button"
import { Input } from "./ui/input"
import { ChipsInput, Combobox } from "./ui/suggest"
import { CoverEditor } from "./cover-editor"

const RichTextEditor = lazy(() => import("./rich-text-editor"))

const LABEL: Record<keyof BookForm, MessageKey> = {
  title: "edit.title",
  authors: "book.authors",
  series: "book.series",
  seriesIndex: "book.volume",
  kategorie: "book.kategorie",
  tags: "book.tags",
  languages: "book.languages",
  publisher: "book.publisher",
  pubdate: "book.published",
  rating: "book.rating",
  identifiers: "book.identifiers",
  comments: "edit.comments",
}

// ISO 639-2 codes calibre uses; plus whatever the library already has
const COMMON_LANGS = ["deu", "eng", "fra", "spa", "ita", "nld", "por", "rus", "pol", "swe", "jpn"]

export function BookEdit({ book, onDone }: { book: Book; onDone: () => void }) {
  const { data: config = DEFAULT_CONFIG } = useQuery(configQuery)
  const { data: cats } = useQuery(categoriesQuery)
  const [base, setBase] = useState(book)
  const original = useMemo(() => toForm(base, config.categoryColumn), [base, config.categoryColumn])
  const [form, setForm] = useState(original)
  const [conflict, setConflict] = useState<Book | null>(null)
  const conflictRef = useRef<HTMLDivElement>(null)
  const update = useUpdateBook(book.id)
  const patch = toPatch(original, form, base.lastModified)
  const dirty = patch !== null

  // leaving after a successful save must not ask
  const leaving = useRef(false)
  useBlocker({
    shouldBlockFn: () => dirty && !leaving.current && !window.confirm(t("edit.leave")),
    enableBeforeUnload: () => dirty && !leaving.current,
  })
  const done = () => {
    leaving.current = true
    onDone()
  }

  const set = <K extends keyof BookForm>(k: K) => (v: BookForm[K]) => setForm((f) => ({ ...f, [k]: v }))

  async function save(e?: FormEvent) {
    e?.preventDefault()
    if (!patch) return done()
    try {
      await update.mutateAsync(patch)
      done()
    } catch (err) {
      if (err instanceof ConflictError) {
        setConflict(err.current)
        requestAnimationFrame(() => conflictRef.current?.scrollIntoView({ block: "start" }))
      }
    }
  }

  const languages = useMemo(() => {
    const have = cats?.languages ?? []
    return [...have, ...COMMON_LANGS.filter((c) => !have.some((h) => h.name === c)).map((name) => ({ name, count: 0 }))]
  }, [cats])
  // shown and typed as "A › B", stored as "A.B"
  const kategorien = useMemo(() => flattenTree(cats?.kategorie ?? []).map((k) => ({ ...k, name: k.name.replaceAll(".", " › ") })), [cats])

  return (
    <form onSubmit={save} className="space-y-5 pb-20" aria-label={t("edit.heading")}>
      {conflict && (
        <Conflict
          ref={conflictRef}
          mine={form}
          theirs={toForm(conflict, config.categoryColumn)}
          onKeepMine={() => {
            // retry against the new version, keeping my changes on top
            setBase(conflict)
            setConflict(null)
          }}
          onTakeTheirs={() => {
            setBase(conflict)
            setForm(toForm(conflict, config.categoryColumn))
            setConflict(null)
          }}
        />
      )}
      <div className="flex flex-col gap-5 sm:flex-row">
        {/* a new cover bumps lastModified; keep the form's precondition in step */}
        <CoverEditor book={base} onChanged={(b) => setBase((prev) => ({ ...prev, lastModified: b.lastModified }))} />
        <div className="min-w-0 flex-1 space-y-4">
          <Field label={t("edit.title")}>
            <Input value={form.title} onChange={(e) => set("title")(e.target.value)} required aria-invalid={!form.title.trim()} />
          </Field>
          <Field label={t("book.authors")} as="div">
            <ChipsInput aria-label={t("book.authors")} value={form.authors} onChange={set("authors")} suggestions={cats?.authors ?? []} />
          </Field>
          <div className="grid grid-cols-[1fr_6rem] gap-3">
            <Field label={t("book.series")} as="div">
              <Combobox aria-label={t("book.series")} value={form.series} onChange={set("series")} suggestions={cats?.series ?? []} />
            </Field>
            <Field label={t("book.volume")}>
              <Input inputMode="decimal" value={form.seriesIndex} onChange={(e) => set("seriesIndex")(e.target.value)} disabled={!form.series.trim()} />
            </Field>
          </div>
        </div>
      </div>

      {config.categoryColumn && (
        <Field label={t("book.kategorie")} as="div" hint={t("edit.kategorieHint")}>
          <Combobox
            aria-label={t("book.kategorie")}
            value={form.kategorie}
            onChange={set("kategorie")}
            suggestions={kategorien}
          />
        </Field>
      )}
      <Field label={t("book.tags")} as="div">
        <ChipsInput aria-label={t("book.tags")} value={form.tags} onChange={set("tags")} suggestions={cats?.tags ?? []} />
      </Field>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label={t("book.languages")} as="div">
          <ChipsInput aria-label={t("book.languages")} value={form.languages} onChange={set("languages")} suggestions={languages} render={languageName} allowNew={false} />
        </Field>
        <Field label={t("book.publisher")}>
          <Input value={form.publisher} onChange={(e) => set("publisher")(e.target.value)} />
        </Field>
        <Field label={t("book.published")}>
          <Input type="date" value={form.pubdate} onChange={(e) => set("pubdate")(e.target.value)} />
        </Field>
        <Field label={t("book.rating")} as="div">
          <Stars value={form.rating} onChange={set("rating")} />
        </Field>
      </div>
      <Field label={t("book.identifiers")} as="div">
        <Identifiers value={form.identifiers} onChange={set("identifiers")} />
      </Field>
      <Field label={t("edit.comments")} as="div">
        <Suspense fallback={<div className="h-40 rounded-md border" />}>
          <RichTextEditor label={t("edit.comments")} value={form.comments} onChange={set("comments")} />
        </Suspense>
      </Field>

      {update.error && !(update.error instanceof ConflictError) && (
        <p role="alert" className="text-sm text-destructive eink:font-bold">
          {t("edit.error")}: {update.error.message}
        </p>
      )}

      <div className="sticky bottom-0 -mx-4 flex flex-wrap items-center justify-end gap-2 border-t bg-background px-4 py-3 sm:-mx-6 sm:px-6 eink:border-t-2">
        <span className="mr-auto hidden text-sm text-muted-foreground sm:inline eink:text-black">{dirty ? t("edit.unsaved") : t("edit.noChanges")}</span>
        <Button type="button" variant="outline" onClick={onDone}>
          {t("edit.cancel")}
        </Button>
        <Button type="submit" disabled={!dirty || update.isPending || !form.title.trim()}>
          {update.isPending ? t("edit.saving") : t("edit.save")}
        </Button>
      </div>
    </form>
  )
}

function Field({ label, hint, as = "label", children }: { label: string; hint?: string; as?: "label" | "div"; children: ReactNode }) {
  const Tag = as
  return (
    <Tag className="block space-y-1.5">
      <span className="text-sm font-medium eink:text-base">{label}</span>
      {children}
      {hint && <span className="block text-xs text-muted-foreground eink:text-sm eink:text-black">{hint}</span>}
    </Tag>
  )
}

function Stars({ value, onChange }: { value: number; onChange: (n: number) => void }) {
  return (
    <div role="radiogroup" aria-label={t("book.rating")} className="flex h-9 items-center gap-0.5 eink:h-12">
      {[1, 2, 3, 4, 5].map((n) => (
        <button
          key={n}
          type="button"
          role="radio"
          aria-checked={value === n}
          aria-label={t("edit.stars", { n })}
          onClick={() => onChange(value === n ? 0 : n)}
          className="rounded-sm p-1 hover:bg-accent eink:p-2"
        >
          <Star className={cn("size-5", n <= value && "fill-current")} />
        </button>
      ))}
    </div>
  )
}

function Identifiers({ value, onChange }: { value: [string, string][]; onChange: (v: [string, string][]) => void }) {
  const setRow = (i: number, row: [string, string]) => onChange(value.map((r, j) => (j === i ? row : r)))
  return (
    <div className="space-y-2">
      {value.map(([k, v], i) => (
        <div key={i} className="grid grid-cols-[7rem_1fr_auto] gap-2">
          <Input value={k} onChange={(e) => setRow(i, [e.target.value, v])} placeholder="isbn" aria-label={t("edit.idType")} />
          <Input value={v} onChange={(e) => setRow(i, [k, e.target.value])} aria-label={t("edit.idValue")} />
          <Button type="button" variant="ghost" size="icon" onClick={() => onChange(value.filter((_, j) => j !== i))} aria-label={t("edit.remove")}>
            <Trash2 />
          </Button>
        </div>
      ))}
      <Button type="button" variant="outline" size="sm" onClick={() => onChange([...value, ["", ""]])}>
        <Plus /> {t("edit.addId")}
      </Button>
    </div>
  )
}

function Conflict({
  ref,
  mine,
  theirs,
  onKeepMine,
  onTakeTheirs,
}: {
  ref: React.Ref<HTMLDivElement>
  mine: BookForm
  theirs: BookForm
  onKeepMine: () => void
  onTakeTheirs: () => void
}) {
  const fields = changedFields(mine, theirs)
  const show = (v: BookForm[keyof BookForm]) =>
    Array.isArray(v) ? v.map((x) => (Array.isArray(x) ? x.join(": ") : x)).join(", ") || "–" : String(v || "–").replace(/<[^>]+>/g, " ").slice(0, 120)
  return (
    <div ref={ref} role="alert" className="scroll-mt-4 space-y-3 rounded-md border-2 border-destructive p-4 eink:border-black">
      <p className="font-medium">{t("edit.conflict")}</p>
      <dl className="grid grid-cols-[auto_1fr_1fr] gap-x-4 gap-y-1 text-sm">
        <span />
        <span className="font-medium">{t("edit.mine")}</span>
        <span className="font-medium">{t("edit.theirs")}</span>
        {fields.map((f) => (
          <div key={f} className="contents">
            <dt className="text-muted-foreground eink:text-black">{t(LABEL[f])}</dt>
            <dd className="break-words">{show(mine[f])}</dd>
            <dd className="break-words">{show(theirs[f])}</dd>
          </div>
        ))}
      </dl>
      <div className="flex flex-wrap gap-2">
        <Button type="button" onClick={onKeepMine}>
          {t("edit.keepMine")}
        </Button>
        <Button type="button" variant="outline" onClick={onTakeTheirs}>
          {t("edit.takeTheirs")}
        </Button>
      </div>
    </div>
  )
}
