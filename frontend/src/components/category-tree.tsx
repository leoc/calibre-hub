import { useState } from "react"
import { ChevronRight } from "lucide-react"
import type { CategoryNode } from "@/lib/api"
import { withFilter, type LibrarySearch } from "@/lib/search"
import { formatNumber } from "@/i18n"
import { cn } from "@/lib/utils"
import { LibraryLink } from "@/components/library-link"

interface Props {
  nodes: CategoryNode[]
  search: LibrarySearch
  onNavigate?: () => void
  depth?: number
}

// "A.B.C": a node is open when it is the selected category or above it.
const isAncestor = (path: string, selected?: string) => !!selected && (selected === path || selected.startsWith(`${path}.`))

export function CategoryTree({ nodes, search, onNavigate, depth = 0 }: Props) {
  return (
    <ul role={depth === 0 ? "tree" : "group"} className="space-y-0.5">
      {nodes.map((n) => (
        <TreeItem key={n.path} node={n} search={search} onNavigate={onNavigate} depth={depth} />
      ))}
    </ul>
  )
}

function TreeItem({ node, search, onNavigate, depth }: { node: CategoryNode } & Required<Pick<Props, "search" | "depth">> & Pick<Props, "onNavigate">) {
  const [open, setOpen] = useState(() => isAncestor(node.path, search.kategorie))
  const selected = search.kategorie === node.path
  const hasChildren = node.children.length > 0
  return (
    <li role="treeitem" aria-expanded={hasChildren ? open : undefined} aria-selected={selected}>
      <div className="flex items-center" style={{ paddingLeft: depth * 12 }}>
        {hasChildren ? (
          <button
            onClick={() => setOpen(!open)}
            aria-label={node.name}
            className="flex size-7 shrink-0 items-center justify-center rounded-sm hover:bg-accent eink:size-11"
          >
            <ChevronRight className={cn("size-4 transition-transform", open && "rotate-90")} aria-hidden />
          </button>
        ) : (
          <span className="size-7 shrink-0 eink:size-11" />
        )}
        <LibraryLink
          search={withFilter(search, { kategorie: selected ? undefined : node.path, unsorted: undefined })}
          onClick={() => {
            if (hasChildren) setOpen(true)
            onNavigate?.()
          }}
          className={cn(
            "flex min-w-0 flex-1 items-center justify-between gap-2 rounded-sm px-2 py-1 text-sm hover:bg-accent eink:min-h-11 eink:text-base",
            selected && "bg-accent font-medium eink:bg-black eink:text-white",
          )}
        >
          <span className="truncate">{node.name}</span>
          <span className="text-xs text-muted-foreground tabular-nums eink:text-inherit">{formatNumber(node.count)}</span>
        </LibraryLink>
      </div>
      {hasChildren && open && <CategoryTree nodes={node.children} search={search} onNavigate={onNavigate} depth={depth + 1} />}
    </li>
  )
}
