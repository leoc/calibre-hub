import { QueryClient } from "@tanstack/react-query"
import { createRootRouteWithContext, createRoute, createRouter, lazyRouteComponent, Outlet, redirect } from "@tanstack/react-router"
import { z } from "zod"
import { ApiError } from "./lib/api"
import { sessionQuery } from "./lib/queries"
import { flag, librarySearchSchema } from "./lib/search"
import { AppShell } from "./components/app-shell"
import { LoginPage } from "./routes/login"
import { LibraryPage } from "./routes/library"
import { BookPage } from "./routes/book"
import { TrashPage } from "./routes/trash"
import { SuggestionsPage } from "./routes/suggestions"
import { MetadataPage } from "./routes/metadata"
import { ListsPage } from "./routes/lists"
import { DuplicatesPage } from "./routes/duplicates"
import { ErrorView } from "./components/error-view"
import { parseSearch, stringifySearch } from "./lib/url-search"

const rootRoute = createRootRouteWithContext<{ queryClient: QueryClient }>()({
  component: Outlet,
  errorComponent: ErrorView,
})

const loginRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/login",
  validateSearch: z.object({ redirect: z.string().optional().catch(undefined) }),
  component: LoginPage,
})

async function requireSession({ context, location }: { context: { queryClient: QueryClient }; location: { href: string } }) {
  try {
    await context.queryClient.ensureQueryData(sessionQuery)
  } catch (e) {
    if (e instanceof ApiError && e.status === 401) {
      throw redirect({ to: "/login", search: { redirect: location.href } })
    }
    throw e
  }
}

// Everything behind the login
const appRoute = createRoute({
  getParentRoute: () => rootRoute,
  id: "_app",
  beforeLoad: requireSession,
  component: AppShell,
})

// The reader: behind the login, but full screen without the app's header,
// sidebar and library keys
const readerRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/read/$id",
  beforeLoad: requireSession,
  params: {
    parse: ({ id }) => ({ id: z.coerce.number().int().parse(id) }),
    stringify: ({ id }) => ({ id: String(id) }),
  },
  validateSearch: z.object({ format: z.string().regex(/^[A-Za-z0-9]{1,10}$/).optional().catch(undefined) }),
  // its own chunk; foliate-js and pdf.js load from there when a book opens
  component: lazyRouteComponent(() => import("./routes/reader"), "ReaderPage"),
})

const libraryRoute = createRoute({
  getParentRoute: () => appRoute,
  path: "/",
  validateSearch: librarySearchSchema,
  component: LibraryPage,
})

const bookRoute = createRoute({
  getParentRoute: () => appRoute,
  path: "/books/$id",
  params: {
    parse: ({ id }) => ({ id: z.coerce.number().int().parse(id) }),
    stringify: ({ id }) => ({ id: String(id) }),
  },
  validateSearch: z.object({ edit: flag }),
  component: BookPage,
})

const trashRoute = createRoute({
  getParentRoute: () => appRoute,
  path: "/trash",
  component: TrashPage,
})

const suggestionsRoute = createRoute({
  getParentRoute: () => appRoute,
  path: "/suggestions",
  component: SuggestionsPage,
})

const metadataRoute = createRoute({
  getParentRoute: () => appRoute,
  path: "/metadata",
  component: MetadataPage,
})

const listsRoute = createRoute({
  getParentRoute: () => appRoute,
  path: "/lists",
  component: ListsPage,
})

const duplicatesRoute = createRoute({
  getParentRoute: () => appRoute,
  path: "/duplicates",
  component: DuplicatesPage,
})

const routeTree = rootRoute.addChildren([loginRoute, readerRoute, appRoute.addChildren([libraryRoute, bookRoute, trashRoute, suggestionsRoute, metadataRoute, listsRoute, duplicatesRoute])])

export function makeRouter(queryClient: QueryClient) {
  return createRouter({
    routeTree,
    context: { queryClient },
    defaultPreload: "intent",
    defaultPreloadStaleTime: 0,
    scrollRestoration: true,
    parseSearch,
    stringifySearch,
  })
}

declare module "@tanstack/react-router" {
  interface Register {
    router: ReturnType<typeof makeRouter>
  }
}
