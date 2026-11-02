import { useState, type FormEvent } from "react"
import { useQuery } from "@tanstack/react-query"
import { useNavigate } from "@tanstack/react-router"
import { ListFilter, Plus, X } from "lucide-react"
import { ApiError, SHELF_FIELDS, type Named, type ShelfCondition, type ShelfField, type ShelfRule } from "@/lib/api"
import { categoriesQuery } from "@/lib/queries"
import { categorySuggestions } from "@/lib/kategorie"
import { useCreateList } from "@/lib/lists"
import { emptyCondition, fromForm, ruleComplete, ruleSummary, shelfDialog, toForm, useShelfDialog, type ShelfDraft } from "@/lib/shelves"
import { withFilter } from "@/lib/search"
import { leaveOverlays } from "@/lib/back-to-close"
import { languageName, t } from "@/i18n"
import { cn } from "@/lib/utils"
import { Button } from "./ui/button"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "./ui/dialog"
import { Input } from "./ui/input"
import { Combobox } from "./ui/suggest"

const select = "h-9 rounded-md border bg-background px-2 text-sm eink:h-12 touch:h-11 eink:border-2 eink:text-base"

// The conditions of a shelf: AND/OR, then one row per condition (field,
// is / is not, value with suggestions from the library), "+ Regel"
export function RuleEditor({ rule, onChange }: { rule: ShelfRule; onChange: (rule: ShelfRule) => void }) {
  const { data: cats } = useQuery(categoriesQuery)
  const suggestions = (field: ShelfField): Named[] => {
    if (!cats) return []
    if (field === "tag") return cats.tags
    if (field === "kategorie") return categorySuggestions(cats.kategorie)
    if (field === "author") return cats.authors
    if (field === "series") return cats.series
    if (field === "language") return cats.languages
    return []
  }
  const set = (i: number, patch: Partial<ShelfCondition>) =>
    onChange({ ...rule, conditions: rule.conditions.map((c, j) => (j === i ? { ...c, ...patch } : c)) })
  return (
    <fieldset className="space-y-3">
      <legend className="mb-1 text-sm font-medium">{t("shelf.rules")}</legend>
      {rule.conditions.length > 1 && (
        <label className="flex flex-wrap items-center gap-2 text-sm">
          <span>{t("shelf.match")}</span>
          <select value={rule.match} onChange={(e) => onChange({ ...rule, match: e.target.value as ShelfRule["match"] })} className={select}>
            <option value="all">{t("shelf.match.all")}</option>
            <option value="any">{t("shelf.match.any")}</option>
          </select>
        </label>
      )}
      <ol className="space-y-3">
        {rule.conditions.map((c, i) => (
          <li key={i} className="space-y-1">
            {i > 0 && <p className="text-xs font-medium tracking-wide text-muted-foreground uppercase eink:text-black">{t(rule.match === "any" ? "shelf.or" : "shelf.and")}</p>}
            <div className="flex flex-wrap items-start gap-2" role="group" aria-label={`${t("shelf.rule")} ${i + 1}`}>
              <select aria-label={t("shelf.field")} value={c.field} onChange={(e) => set(i, { field: e.target.value as ShelfField, value: "" })} className={select}>
                {SHELF_FIELDS.map((f) => (
                  <option key={f} value={f}>
                    {t(`shelf.field.${f}`)}
                  </option>
                ))}
              </select>
              <select aria-label={t("shelf.op")} value={c.not ? "not" : "is"} onChange={(e) => set(i, { not: e.target.value === "not" || undefined })} className={select}>
                <option value="is">{t(c.field === "text" ? "shelf.op.textIs" : "shelf.op.is")}</option>
                <option value="not">{t(c.field === "text" ? "shelf.op.textNot" : "shelf.op.not")}</option>
              </select>
              {c.field === "text" ? (
                <Input aria-label={t("shelf.value")} value={c.value} onChange={(e) => set(i, { value: e.target.value })} placeholder={t("shelf.textHint")} className="min-w-40 flex-1" maxLength={500} />
              ) : (
                <Combobox
                  aria-label={t("shelf.value")}
                  value={c.value}
                  onChange={(v) => set(i, { value: v })}
                  suggestions={suggestions(c.field)}
                  render={c.field === "language" ? (code) => `${languageName(code)} (${code})` : undefined}
                  className="min-w-40 flex-1"
                />
              )}
              <Button
                type="button"
                variant="ghost"
                size="icon"
                aria-label={t("shelf.removeCondition", { n: i + 1 })}
                title={t("shelf.removeCondition", { n: i + 1 })}
                disabled={rule.conditions.length === 1}
                onClick={() => onChange({ ...rule, conditions: rule.conditions.filter((_, j) => j !== i) })}
                className="shrink-0 eink:size-12 touch:size-11"
              >
                <X />
              </Button>
            </div>
          </li>
        ))}
      </ol>
      <Button type="button" variant="outline" size="sm" disabled={rule.conditions.length >= 20} onClick={() => onChange({ ...rule, conditions: [...rule.conditions, emptyCondition()] })}>
        <Plus /> {t("shelf.addCondition")}
      </Button>
    </fieldset>
  )
}

// The rule in one line, with the search's error when calibre rejected it
export function RuleLine({ rule, error, className }: { rule: ShelfRule; error?: string | null; className?: string }) {
  return (
    <>
      <p className={cn("flex items-start gap-2 text-sm", className)}>
        <ListFilter className="mt-0.5 size-4 shrink-0" aria-label={t("shelf.label")} />
        <span>{ruleSummary(rule)}</span>
      </p>
      {error && (
        <p role="alert" className="text-sm text-destructive eink:font-bold eink:text-black">
          {t("shelf.error", { error })}
        </p>
      )}
    </>
  )
}

// Mounted once in the app shell
export function ShelfDialogHost() {
  const draft = useShelfDialog()
  return draft ? <NewShelfDialog draft={draft} onClose={shelfDialog.close} /> : null
}

// "Neues Regal": name, rule, favorite; opens the new shelf
function NewShelfDialog({ draft, onClose }: { draft: ShelfDraft; onClose: () => void }) {
  const create = useCreateList()
  const navigate = useNavigate()
  const [name, setName] = useState(draft.name ?? "")
  const [rule, setRule] = useState<ShelfRule>(() => toForm(draft.rule))
  const [favorite, setFavorite] = useState(true)
  const submit = (e: FormEvent) => {
    e.preventDefault()
    create.mutate(
      { name: name.trim(), favorite, rule: fromForm(rule) },
      {
        onSuccess: (l) => {
          const left = leaveOverlays()
          onClose()
          left.then(() => navigate({ to: "/", search: withFilter({}, { list: l.id }) }))
        },
      },
    )
  }
  const error = create.error
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="sm:max-w-xl">
        <DialogTitle className="text-lg font-semibold">{t("shelf.newTitle")}</DialogTitle>
        <DialogDescription>{t("shelf.hint")}</DialogDescription>
        <form onSubmit={submit} className="space-y-4">
          <label className="block space-y-1 text-sm">
            <span className="font-medium">{t("shelf.name")}</span>
            <Input autoFocus value={name} onChange={(e) => setName(e.target.value)} required maxLength={120} />
            <span className="block text-xs text-muted-foreground eink:text-black">{t("list.nameHint")}</span>
          </label>
          <RuleEditor rule={rule} onChange={setRule} />
          <label className="flex items-center gap-3 text-sm eink:min-h-11 touch:min-h-11 eink:text-base">
            <input type="checkbox" checked={favorite} onChange={(e) => setFavorite(e.target.checked)} className="size-4 eink:size-6" />
            {t("list.favorite")}
          </label>
          {error && (
            <p role="alert" className="text-sm text-destructive">
              {error instanceof ApiError && error.status === 409 ? t("list.taken") : error instanceof ApiError ? error.message : String(error)}
            </p>
          )}
          <div className="flex justify-end gap-2">
            <Button type="button" variant="outline" onClick={onClose}>
              {t("edit.cancel")}
            </Button>
            <Button type="submit" disabled={!name.trim() || !ruleComplete(rule) || create.isPending}>
              {t("list.create")}
            </Button>
          </div>
        </form>
      </DialogContent>
    </Dialog>
  )
}
