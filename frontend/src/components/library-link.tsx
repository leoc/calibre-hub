import { Link } from "@tanstack/react-router"
import { createContext, useContext, type ComponentProps } from "react"
import { librarySearchSchema, type LibrarySearch } from "@/lib/search"

const KEYS = Object.keys(librarySearchSchema.shape) as (keyof LibrarySearch)[]

// Links inside an overlay with its own history entry (the phone drawer)
// replace that entry, so Back afterwards does not land on the closed drawer.
export const ReplaceHistory = createContext(false)

// Link into the library. Missing keys are spelled out as undefined so the
// router marks it active (aria-current) only on an exact match of the state.
export function LibraryLink({ search, ...props }: { search: LibrarySearch } & Omit<ComponentProps<typeof Link>, "to" | "search">) {
  const replace = useContext(ReplaceHistory)
  const full = Object.fromEntries(KEYS.map((k) => [k, search[k]])) as LibrarySearch
  return <Link to="/" search={() => full as never} replace={replace || undefined} activeOptions={{ exact: true, includeSearch: true, explicitUndefined: true }} {...props} />
}
