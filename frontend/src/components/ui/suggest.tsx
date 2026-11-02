import { useId, useState, type KeyboardEvent, type ReactNode } from "react"
import { X } from "lucide-react"
import type { Named } from "@/lib/api"
import { matchNamed } from "@/lib/palette"
import { cn } from "@/lib/utils"

const field =
  "flex min-h-9 w-full flex-wrap items-center gap-1 rounded-md border border-input bg-transparent px-2 py-1 text-base shadow-xs focus-within:border-ring focus-within:ring-[3px] focus-within:ring-ring/50 md:text-sm eink:min-h-12 touch:min-h-11 eink:border-2 eink:text-lg"

interface ListProps {
  id: string
  items: Named[]
  active: number
  onPick: (name: string) => void
  render?: (name: string) => ReactNode
  create?: string
}

function SuggestList({ id, items, active, onPick, render = (n) => n, create }: ListProps) {
  if (!items.length && !create) return null
  return (
    <ul id={id} role="listbox" className="absolute top-full right-0 left-0 z-50 mt-1 max-h-64 overflow-y-auto rounded-md border bg-popover p-1 shadow-md eink:border-2">
      {items.map((i, idx) => (
        <li
          key={i.name}
          role="option"
          aria-selected={idx === active}
          // mousedown so the input keeps focus
          onMouseDown={(e) => {
            e.preventDefault()
            onPick(i.name)
          }}
          className="flex cursor-default items-center justify-between gap-2 rounded-sm px-2 py-1.5 text-sm aria-selected:bg-accent aria-selected:text-accent-foreground eink:min-h-11 touch:min-h-11 eink:text-base"
        >
          <span className="truncate">{render(i.name)}</span>
          <span className="text-xs text-muted-foreground tabular-nums">{i.count}</span>
        </li>
      ))}
      {create && (
        <li
          role="option"
          aria-selected={active === items.length}
          onMouseDown={(e) => {
            e.preventDefault()
            onPick(create)
          }}
          className="rounded-sm px-2 py-1.5 text-sm italic aria-selected:bg-accent eink:min-h-11 touch:min-h-11"
        >
          „{render(create)}“ neu
        </li>
      )}
    </ul>
  )
}

function useSuggest(items: Named[], text: string, exclude: string[], open: boolean) {
  const shown = open ? matchNamed(items.filter((i) => !exclude.includes(i.name)), text, 8) : []
  const trimmed = text.trim()
  const create = trimmed && !items.some((i) => i.name.toLowerCase() === trimmed.toLowerCase()) && !exclude.includes(trimmed) ? trimmed : undefined
  return { shown, create, count: shown.length + (create ? 1 : 0) }
}

// Several values as chips (authors, tags, languages) with suggestions.
export function ChipsInput({
  value,
  onChange,
  suggestions,
  placeholder,
  render,
  allowNew = true,
  "aria-label": ariaLabel,
}: {
  value: string[]
  onChange: (v: string[]) => void
  suggestions: Named[]
  placeholder?: string
  render?: (name: string) => ReactNode
  allowNew?: boolean
  "aria-label"?: string
}) {
  const [text, setText] = useState("")
  const [open, setOpen] = useState(false)
  const [active, setActive] = useState(0)
  const id = useId()
  const { shown, create, count } = useSuggest(suggestions, text, value, open)
  const add = (name: string) => {
    if (!value.includes(name)) onChange([...value, name])
    setText("")
    setActive(0)
    // reopens when typing again; an open list would cover what comes below
    setOpen(false)
  }
  const onKeyDown = (e: KeyboardEvent<HTMLInputElement>) => {
    if (e.key === "ArrowDown") setActive((a) => Math.min(a + 1, count - 1))
    else if (e.key === "ArrowUp") setActive((a) => Math.max(a - 1, 0))
    else if ((e.key === "Enter" || e.key === "Tab" || e.key === ",") && text.trim()) {
      const pick = shown[active]?.name ?? (allowNew ? create : undefined)
      if (pick) {
        e.preventDefault()
        add(pick)
      }
    } else if (e.key === "Backspace" && !text && value.length) onChange(value.slice(0, -1))
    else if (e.key === "Escape") setOpen(false)
    else return
    if (e.key !== "Tab" && e.key !== "Backspace") e.preventDefault()
  }
  return (
    <div className="relative">
      <div className={field}>
        {value.map((v) => (
          <span key={v} className="inline-flex items-center gap-1 rounded-sm bg-secondary px-1.5 py-0.5 text-sm eink:border eink:border-black">
            {render ? render(v) : v}
            <button type="button" onClick={() => onChange(value.filter((x) => x !== v))} aria-label={`${v} entfernen`} className="flex items-center justify-center rounded-xs p-0.5 hover:bg-accent eink:-my-1 eink:size-11 eink:p-0 touch:-my-1.5 touch:size-11 touch:p-0">
              <X className="size-3 eink:size-5" />
            </button>
          </span>
        ))}
        <input
          value={text}
          onChange={(e) => {
            setText(e.target.value)
            setOpen(true)
            setActive(0)
          }}
          onFocus={() => setOpen(true)}
          onBlur={() => setOpen(false)}
          onKeyDown={onKeyDown}
          placeholder={value.length ? undefined : placeholder}
          aria-label={ariaLabel}
          role="combobox"
          aria-expanded={open && count > 0}
          aria-controls={id}
          className="min-w-24 flex-1 bg-transparent py-0.5 outline-none"
        />
      </div>
      {open && <SuggestList id={id} items={shown} active={active} onPick={add} render={render} create={allowNew ? create : undefined} />}
    </div>
  )
}

// One value with suggestions (series, category, publisher); free text allowed.
export function Combobox({
  value,
  onChange,
  suggestions,
  placeholder,
  render,
  className,
  "aria-label": ariaLabel,
}: {
  value: string
  onChange: (v: string) => void
  suggestions: Named[]
  placeholder?: string
  render?: (name: string) => ReactNode
  className?: string
  "aria-label"?: string
}) {
  const [open, setOpen] = useState(false)
  const [active, setActive] = useState(-1)
  const id = useId()
  const { shown } = useSuggest(suggestions, value, [], open)
  const list = shown.filter((i) => i.name !== value)
  const onKeyDown = (e: KeyboardEvent<HTMLInputElement>) => {
    if (e.key === "ArrowDown") setActive((a) => Math.min(a + 1, list.length - 1))
    else if (e.key === "ArrowUp") setActive((a) => Math.max(a - 1, -1))
    else if (e.key === "Enter" && active >= 0 && list[active]) {
      onChange(list[active].name)
      setOpen(false)
    } else if (e.key === "Escape") setOpen(false)
    else return
    e.preventDefault()
  }
  return (
    <div className={cn("relative", className)}>
      <div className={cn(field, "flex-nowrap")}>
        <input
          value={value}
          onChange={(e) => {
            onChange(e.target.value)
            setOpen(true)
            setActive(-1)
          }}
          onFocus={() => setOpen(true)}
          onBlur={() => setOpen(false)}
          onKeyDown={onKeyDown}
          placeholder={placeholder}
          aria-label={ariaLabel}
          role="combobox"
          aria-expanded={open && list.length > 0}
          aria-controls={id}
          className="min-w-0 flex-1 bg-transparent py-0.5 outline-none"
        />
        {value && (
          <button type="button" onClick={() => onChange("")} aria-label="leeren" className="flex items-center justify-center rounded-xs p-0.5 hover:bg-accent eink:-my-1 eink:size-11 eink:p-0 touch:-my-1.5 touch:size-11 touch:p-0">
            <X className="size-3.5 eink:size-5" />
          </button>
        )}
      </div>
      {open && (
        <SuggestList
          id={id}
          items={list}
          active={active}
          onPick={(n) => {
            onChange(n)
            setOpen(false)
          }}
          render={render}
        />
      )}
    </div>
  )
}
