import { useCallback } from "react"
import { useNavigate, useRouterState } from "@tanstack/react-router"
import { librarySearchSchema, type LibrarySearch } from "./search"

// Library search state from anywhere in the app (empty outside the library).
export function useLibrarySearch(): LibrarySearch {
  const { pathname, search } = useRouterState({ select: (s) => s.location })
  return pathname === "/" ? librarySearchSchema.parse(search) : {}
}

export function useGoLibrary() {
  const navigate = useNavigate()
  return useCallback(
    (search: LibrarySearch, opts: { replace?: boolean } = {}) => navigate({ to: "/", search, replace: opts.replace }),
    [navigate],
  )
}
