import { useContext, useMemo, useState, type ReactNode } from "react"
import { useQuery } from "@tanstack/react-query"
import { Link } from "@tanstack/react-router"
import { CopyCheck, Import, Inbox, Library, ListIcon, Sparkles, Trash2, WandSparkles } from "lucide-react"
import { booksQuery, categoriesQuery, classifyStatusQuery, configQuery, importStatusQuery } from "@/lib/queries"
import { DEFAULT_CONFIG, type Named } from "@/lib/api"
import { intakeStatusQuery } from "@/lib/intake"
import { favoriteTree, findNode, flattenListTree, useListTree } from "@/lib/lists"
import { ListTree } from "./list-tree"
import { hasFilters, togglePrivateTag, toggleTag, unsortedQuery, withFilter, type LibrarySearch } from "@/lib/search"
import { matchNamed } from "@/lib/palette"
import { formatNumber, languageName, t } from "@/i18n"
import { cn } from "@/lib/utils"
import { useIsAdmin } from "@/lib/session"
import { CategoryTree } from "./category-tree"
import { ThemeSwitch } from "./theme-switch"
import { KeyboardSwitch } from "./keyboard"
import { LibraryLink, ReplaceHistory } from "@/components/library-link"

interface Props {
  search: LibrarySearch
  onNavigate?: () => void
}

const navItem =
  "flex items-center justify-between gap-2 rounded-sm px-2 py-1 text-sm hover:bg-accent eink:min-h-11 touch:min-h-11 eink:text-base"
const active = "bg-accent font-medium eink:bg-black eink:text-white"

export function Sidebar({ search, onNavigate }: Props) {
  // inside the phone drawer: links replace its history entry
  const replace = useContext(ReplaceHistory) || undefined
  const { data: cats } = useQuery(categoriesQuery)
  const { data: config = DEFAULT_CONFIG } = useQuery(configQuery)
  // the library's upkeep (suggestions, metadata, duplicates, trash) is for admins
  const admin = useIsAdmin()
  // books without a category, counted over the whole library
  const { data: unsorted, isPending: unsortedPending } = useQuery({
    ...booksQuery({ q: unsortedQuery(config.categoryColumn ?? ""), limit: 1 }),
    enabled: !!config.categoryColumn,
  })
  const { data: classify } = useQuery({ ...classifyStatusQuery, enabled: !!config.classify && admin })
  // the backlog import's page, when it is on (no polling from here)
  const { data: imports } = useQuery({ ...importStatusQuery, enabled: admin, refetchInterval: false })
  // how many are in the Eingang, polled on its own page only
  const { data: intake } = useQuery({ ...intakeStatusQuery(), enabled: admin && !!imports?.enabled, refetchInterval: false })

  return (
    <nav className="flex h-full flex-col gap-5 overflow-y-auto p-3">
      <div className="space-y-0.5">
        <LibraryLink search={{}} onClick={onNavigate} className={cn(navItem, !hasFilters(search) && active)}>
          <span className="flex items-center gap-2">
            <Library className="size-4" aria-hidden /> {t("nav.all")}
          </span>
        </LibraryLink>
      </div>

      <ListsSection search={search} onNavigate={onNavigate} />

      {config.categoryColumn && (!!cats?.kategorie.length || unsortedPending || !!unsorted?.total) && (
        <Section title={t("nav.kategorie")}>
          {/* kept while its count loads, so the tree below doesn't jump */}
          {(unsortedPending || !!unsorted?.total || search.unsorted) && (
            <LibraryLink
              search={withFilter(search, { unsorted: search.unsorted ? undefined : true, kategorie: undefined })}
              onClick={onNavigate}
              className={cn(navItem, search.unsorted && active)}
            >
              <span className="flex items-center gap-2">
                <Inbox className="size-4" aria-hidden /> {t("nav.unsorted")}
              </span>
              {unsorted ? <Count n={unsorted.total} /> : unsortedPending && <CountPlaceholder />}
            </LibraryLink>
          )}
          {!!cats?.kategorie.length && <CategoryTree nodes={cats.kategorie} search={search} onNavigate={onNavigate} />}
        </Section>
      )}

      {cats && (
        <>
          <NamedSection title={t("nav.authors")} items={cats.authors} selected={search.author} make={(n) => withFilter(search, { author: n })} onNavigate={onNavigate} />
          <NamedSection title={t("nav.series")} items={cats.series} selected={search.series} make={(n) => withFilter(search, { series: n })} onNavigate={onNavigate} />
          {/* the user's own tags first: few, and only theirs */}
          <NamedSection
            title={t("nav.privateTags")}
            items={cats.privateTags ?? []}
            selected={search.ptag ?? []}
            make={(n) => (n ? togglePrivateTag(search, n) : search)}
            onNavigate={onNavigate}
          />
          <NamedSection
            title={t("nav.tags")}
            items={cats.tags}
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

      <div className="mt-auto space-y-2 pt-2">
        {config.classify && admin && (
          <Link to="/suggestions" replace={replace} onClick={onNavigate} className={navItem} activeProps={{ className: active }}>
            <span className="flex items-center gap-2">
              <Sparkles className="size-4" aria-hidden /> {t("suggest.title")}
            </span>
            {!!classify?.pending && <Count n={classify.pending} />}
          </Link>
        )}
        {config.metadata && admin && (
          <Link to="/metadata" replace={replace} onClick={onNavigate} className={navItem} activeProps={{ className: active }}>
            <span className="flex items-center gap-2">
              <WandSparkles className="size-4" aria-hidden /> {t("meta.title")}
            </span>
          </Link>
        )}
        {imports?.enabled && admin && (
          <Link to="/eingang" replace={replace} onClick={onNavigate} className={navItem} activeProps={{ className: active }}>
            <span className="flex items-center gap-2">
              <Inbox className="size-4" aria-hidden /> {t("intake.title")}
            </span>
            {intake?.progress && <Count n={intake.progress.total} />}
          </Link>
        )}
        {imports?.enabled && admin && (
          <Link to="/import" replace={replace} onClick={onNavigate} className={navItem} activeProps={{ className: active }}>
            <span className="flex items-center gap-2">
              <Import className="size-4" aria-hidden /> {t("import.page")}
            </span>
          </Link>
        )}
        {admin && (
          <Link to="/duplicates" replace={replace} onClick={onNavigate} className={navItem} activeProps={{ className: active }}>
            <span className="flex items-center gap-2">
              <CopyCheck className="size-4" aria-hidden /> {t("dup.title")}
            </span>
          </Link>
        )}
        {admin && (
          <Link to="/trash" replace={replace} onClick={onNavigate} className={navItem} activeProps={{ className: active }}>
            <span className="flex items-center gap-2">
              <Trash2 className="size-4" aria-hidden /> {t("trash.title")}
            </span>
          </Link>
        )}
        <ThemeSwitch />
        {/* keyboard control is for wide screens; phones stay as they are */}
        <KeyboardSwitch className="hidden sm:grid" />
      </div>
    </nav>
  )
}

// Reading lists: the favorites (and the open list, so it shows as active),
// then "Alle Listen" with the overview
function ListsSection({ search, onNavigate }: Props) {
  const { lists, tree, user } = useListTree()
  const replace = useContext(ReplaceHistory) || undefined
  if (!lists || !tree) return null
  // a favorite with its sublists; the open list also when it is none
  const favorites = favoriteTree(tree)
  const current = findNode(tree, search, user)
  const shown = current && !flattenListTree(favorites).includes(current) ? [...favorites, { ...current, depth: 0, children: [] }] : favorites
  return (
    <Section title={t("nav.lists")}>
      {!!shown.length && <ListTree nodes={shown} active={current} user={user} onNavigate={onNavigate} label={t("nav.lists")} />}
      <Link to="/lists" replace={replace} onClick={onNavigate} className={navItem} activeProps={{ className: active }}>
        <span className="flex items-center gap-2">
          <ListIcon className="size-4" aria-hidden /> {t("nav.allLists")}
        </span>
        <Count n={lists.length} />
      </Link>
    </Section>
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

function CountPlaceholder() {
  return <span aria-hidden className="h-3 w-5 animate-pulse rounded-sm bg-muted eink:hidden" />
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
    const list = filter ? matchNamed(items, filter, 50) : expanded ? [...items].sort((a, b) => a.name.localeCompare(b.name, "de", { numeric: true })).slice(0, 300) : matchNamed(items, "", COLLAPSED)
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
          className="mb-1 h-7 w-full rounded-sm border bg-transparent px-2 text-sm eink:h-11 touch:h-11 touch:text-base eink:border-2"
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
        <button onClick={() => setExpanded(!expanded)} className="px-2 py-1 text-xs text-muted-foreground underline-offset-2 hover:underline eink:min-h-11 touch:min-h-11 eink:text-sm eink:text-black eink:underline">
          {expanded ? t("nav.less") : t("nav.more", { count: formatNumber(items.length) })}
        </button>
      )}
    </Section>
  )
}
