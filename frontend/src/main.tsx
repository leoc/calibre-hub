import { StrictMode } from "react"
import { createRoot } from "react-dom/client"
import { MutationCache, QueryCache, QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { RouterProvider } from "@tanstack/react-router"
import { ApiError } from "./lib/api"
import { ThemeProvider } from "./lib/theme"
import { makeRouter } from "./router"
import "./index.css"

// A 401 anywhere means the session ran out: back to the login.
const onError = (e: unknown) => {
  if (e instanceof ApiError && e.status === 401 && router.state.location.pathname !== "/login") {
    queryClient.removeQueries({ queryKey: ["session"] })
    router.navigate({ to: "/login", search: { redirect: router.state.location.href } })
  }
}

const queryClient = new QueryClient({
  queryCache: new QueryCache({ onError }),
  mutationCache: new MutationCache({ onError }),
  defaultOptions: {
    queries: {
      retry: (n, e) => !(e instanceof ApiError && e.status < 500) && n < 2,
      refetchOnWindowFocus: false,
    },
  },
})
const router = makeRouter(queryClient)

async function start() {
  if (import.meta.env.MODE === "mock") {
    const { worker } = await import("./mocks/browser")
    await worker.start({ quiet: true })
  }
  createRoot(document.getElementById("root")!).render(
    <StrictMode>
      <ThemeProvider>
        <QueryClientProvider client={queryClient}>
          <RouterProvider router={router} />
        </QueryClientProvider>
      </ThemeProvider>
    </StrictMode>,
  )
}

start()
