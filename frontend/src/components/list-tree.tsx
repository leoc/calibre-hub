import { useState } from "react"
import { Bookmark, ChevronRight, Folder, ListFilter, ListIcon, Star } from "lucide-react"
import { isBelow, nodeCount, nodeSearch, type ListNode } from "@/lib/lists"
import { withFilter } from "@/lib/search"
import { formatNumber, t } from "@/i18n"
import { cn } from "@/lib/utils"
import { LibraryLink } from "@/components/library-link"

interface Props {
  nodes: ListNode[]
  // the node whose page is open
  active?: ListNode
  user?: string
  onNavigate?: () => void
  label?: string
  depth?: number
}

// Lists in the sidebar, nested like the category tree: a node with
// sublists opens with the chevron, or by opening it.
export function ListTree({ nodes, active, user, onNavigate, label, depth = 0 }: Props) {
  // flat favorites keep the full width; with a chevron among them all align
  const gutter = depth > 0 || nodes.some((n) => n.children.length > 0)
  return (
    <ul className="space-y-0.5" aria-label={label}>
      {nodes.map((n) => (
        <Item key={n.key} node={n} active={active} user={user} onNavigate={onNavigate} depth={depth} gutter={gutter} />
      ))}
    </ul>
  )
}

function Item({ node, active, user, onNavigate, depth, gutter }: { node: ListNode; depth: number; gutter: boolean } & Omit<Props, "nodes" | "depth" | "label">) {
  const contains = !!active && active.owner === node.owner && isBelow(node.path, active.path)
  const [open, setOpen] = useState(contains)
  const selected = active?.key === node.key
  const hasChildren = node.children.length > 0
  const count = nodeCount(node)
  const l = node.list
  const Icon = !l ? Folder : l.rule ? ListFilter : l.isDefault ? Bookmark : l.favorite ? Star : ListIcon
  return (
    <li>
      <div className="flex items-center" style={{ paddingLeft: depth * 12 }}>
        {hasChildren ? (
          <button
            type="button"
            onClick={() => setOpen(!open)}
            aria-expanded={open}
            aria-label={t(open ? "list.collapse" : "list.expand", { name: node.name })}
            className="flex size-7 shrink-0 items-center justify-center rounded-sm hover:bg-accent eink:size-11 touch:size-11"
          >
            <ChevronRight className={cn("size-4 transition-transform", open && "rotate-90")} aria-hidden />
          </button>
        ) : (
          gutter && <span className="size-7 shrink-0 eink:size-11 touch:size-11" />
        )}
        <LibraryLink
          search={withFilter({}, nodeSearch(node, user))}
          onClick={() => {
            if (hasChildren) setOpen(true)
            onNavigate?.()
          }}
          className={cn(
            "flex min-w-0 flex-1 items-center justify-between gap-2 rounded-sm px-2 py-1 text-sm hover:bg-accent eink:min-h-11 touch:min-h-11 eink:text-base",
            selected && "bg-accent font-medium eink:bg-black eink:text-white",
          )}
        >
          <span className="flex min-w-0 items-center gap-2">
            <Icon className="size-4 shrink-0" aria-hidden />
            <span className="truncate">{node.name}</span>
          </span>
          {count != null && <span className="text-xs text-muted-foreground tabular-nums eink:text-inherit">{formatNumber(count)}</span>}
        </LibraryLink>
      </div>
      {hasChildren && open && <ListTree nodes={node.children} active={active} user={user} onNavigate={onNavigate} depth={depth + 1} />}
    </li>
  )
}
