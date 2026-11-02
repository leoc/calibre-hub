import { useMemo, useState, type ReactNode } from "react"
import { useQuery } from "@tanstack/react-query"
import { Bookmark, Inbox, Library } from "lucide-react"
import { booksQuery, categoriesQuery, configQuery } from "@/lib/queries"
import { DEFAULT_CONFIG, type Named } from "@/lib/api"
import { hasFilters, toggleTag, unsortedQuery, withFilter, type LibrarySearch } from "@/lib/search"
import { matchNamed } from "@/lib/palette"
import { formatNumber, languageName, t } from "@/i18n"
import { cn } from "@/lib/utils"
import { CategoryTree } from "./category-tree"
import { ThemeSwitch } from "./theme-switch"
import { LibraryLink } from "@/components/library-link"

interface Props {
  search: LibrarySearch
  onNavigate?: () => void
}

const navItem =
  "flex items-center justify-between gap-2 rounded-sm px-2 py-1 text-sm hover:bg-accent eink:min-h-11 eink:text-base"
const active = "bg-accent font-medium eink:bg-black eink:text-white"

export function Sidebar({ search, onNavigate }: Props) {
  const { data: cats } = useQuery(categoriesQuery)
  const { data: config = DEFAULT_CONFIG } = useQuery(configQuery)
  const tagCount = (tag: string) => cats?.tags.find((x) => x.name === tag)?.count
  // books without a category, counted over the whole library
  const { data: unsorted } = useQuery({
    ...booksQuery({ q: unsortedQuery(config.categoryColumn ?? ""), limit: 1 }),
    enabled: !!config.categoryColumn,
  })

  return (
    <nav className="flex h-full flex-col gap-5 overflow-y-auto p-3">
      <div className="space-y-0.5">
        <LibraryLink search={{}} onClick={onNavigate} className={cn(navItem, !hasFilters(search) && active)}>
          <span className="flex items-center gap-2">
            <Library className="size-4" aria-hidden /> {t("nav.all")}
          </span>
        </LibraryLink>
        {config.fastTags.map((tag) => {
          const on = search.tag?.includes(tag)
          const count = tagCount(tag)
          return (
            <LibraryLink key={tag} search={toggleTag(search, tag)} onClick={onNavigate} className={cn(navItem, on && active)}>
              <span className="flex items-center gap-2 capitalize">
                <Bookmark className="size-4" aria-hidden /> {tag}
              </span>
              {count != null && <Count n={count} />}
            </LibraryLink>
          )
        })}
      </div>

      {config.categoryColumn && (!!cats?.kategorie.length || !!unsorted?.total) && (
        <Section title={t("nav.kategorie")}>
          {(!!unsorted?.total || search.unsorted) && (
            <LibraryLink
              search={withFilter(search, { unsorted: search.unsorted ? undefined : true, kategorie: undefined })}
              onClick={onNavigate}
              className={cn(navItem, search.unsorted && active)}
            >
              <span className="flex items-center gap-2">
                <Inbox className="size-4" aria-hidden /> {t("nav.unsorted")}
              </span>
              {unsorted && <Count n={unsorted.total} />}
            </LibraryLink>
          )}
          {!!cats?.kategorie.length && <CategoryTree nodes={cats.kategorie} search={search} onNavigate={onNavigate} />}
        </Section>
      )}

      {cats && (
        <>
          <NamedSection title={t("nav.authors")} items={cats.authors} selected={search.author} make={(n) => withFilter(search, { author: n })} onNavigate={onNavigate} />
          <NamedSection title={t("nav.series")} items={cats.series} selected={search.series} make={(n) => withFilter(search, { series: n })} onNavigate={onNavigate} />
          <NamedSection
            title={t("nav.tags")}
            items={cats.tags.filter((x) => !config.fastTags.includes(x.name))}
            selected={search.tag}
            make={(n) => (n ? toggleTag(search, n) : search)}
            onNavigate={onNavigate}
          />
          {cats.languages.length > 1 && (
            <NamedSection
              title={t("nav.languages")}
              items={cats.languages}
              selected={search.lang}
              make={(n) => withFilter(search, { lang: n })}
              label={languageName}
              onNavigate={onNavigate}
            />
          )}
        </>
      )}

      <div className="mt-auto pt-2">
        <ThemeSwitch />
      </div>
    </nav>
  )
}

function Section({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="space-y-1">
      <h2 className="px-2 text-xs font-semibold tracking-wide text-muted-foreground uppercase eink:text-sm eink:text-black">{title}</h2>
      {children}
    </section>
  )
}

function Count({ n }: { n: number }) {
  return <span className="text-xs text-muted-foreground tabular-nums eink:text-inherit">{formatNumber(n)}</span>
}

const COLLAPSED = 8

// Long lists (authors, tags) show the most frequent ones plus a filter field.
function NamedSection({
  title,
  items,
  selected,
  make,
  label = (n) => n,
  onNavigate,
}: {
  title: string
  items: Named[]
  selected?: string | string[]
  make: (name: string | undefined) => LibrarySearch
  label?: (name: string) => string
  onNavigate?: () => void
}) {
  const [expanded, setExpanded] = useState(false)
  const [filter, setFilter] = useState("")
  const isSel = (n: string) => (Array.isArray(selected) ? selected.includes(n) : selected === n)
  const shown = useMemo(() => {
    const list = filter ? matchNamed(items, filter, 50) : expanded ? [...items].sort((a, b) => a.name.localeCompare(b.name)).slice(0, 300) : matchNamed(items, "", COLLAPSED)
    // keep the selected ones visible
    const missing = items.filter((i) => isSel(i.name) && !list.includes(i))
    return [...missing, ...list]
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [items, filter, expanded, selected])

  if (!items.length) return null
  return (
    <Section title={title}>
      {items.length > COLLAPSED && (
        <input
          value={filter}
          onChange={(e) => setFilter(e.target.value)}
          placeholder={t("nav.filter")}
          aria-label={`${title}: ${t("nav.filter")}`}
          className="mb-1 h-7 w-full rounded-sm border bg-transparent px-2 text-sm eink:h-11 eink:border-2"
        />
      )}
      <ul className="space-y-0.5">
        {shown.map((i) => {
          const sel = isSel(i.name)
          return (
            <li key={i.name}>
              <LibraryLink
                // a single-valued filter toggles off; tags handle that in make()
                search={Array.isArray(selected) ? make(i.name) : make(sel ? undefined : i.name)}
                onClick={onNavigate}
                className={cn(navItem, sel && active)}
              >
                <span className="truncate">{label(i.name)}</span>
                <Count n={i.count} />
              </LibraryLink>
            </li>
          )
        })}
      </ul>
      {!filter && items.length > COLLAPSED && (
        <button onClick={() => setExpanded(!expanded)} className="px-2 py-1 text-xs text-muted-foreground underline-offset-2 hover:underline eink:min-h-11 eink:text-sm eink:text-black eink:underline">
          {expanded ? t("nav.less") : t("nav.more", { count: formatNumber(items.length) })}
        </button>
      )}
    </Section>
  )
}
