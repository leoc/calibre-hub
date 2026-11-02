import { Link } from "@tanstack/react-router"
import type { ComponentProps } from "react"
import { librarySearchSchema, type LibrarySearch } from "@/lib/search"

const KEYS = Object.keys(librarySearchSchema.shape) as (keyof LibrarySearch)[]

// Link into the library. Missing keys are spelled out as undefined so the
// router marks it active (aria-current) only on an exact match of the state.
export function LibraryLink({ search, ...props }: { search: LibrarySearch } & Omit<ComponentProps<typeof Link>, "to" | "search">) {
  const full = Object.fromEntries(KEYS.map((k) => [k, search[k]])) as LibrarySearch
  return <Link to="/" search={() => full as never} activeOptions={{ exact: true, includeSearch: true, explicitUndefined: true }} {...props} />
}
