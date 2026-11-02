import { delay, http, HttpResponse } from "msw"
import { setupWorker } from "msw/browser"
import { handlers } from "./handlers"

// MSW answers inside the page, so an offline browser (e2e:
// context.setOffline) would still get answers; offline the API fails
// like the network would
const offline = http.all("/api/*", () => (navigator.onLine ? undefined : HttpResponse.error()))

export const worker = setupWorker(offline, ...handlers)

// Lets screenshot scripts and e2e tests switch states (errors, slow
// responses) at runtime: window.__msw.worker.use(window.__msw.http.get(…)).
Object.assign(window, { __msw: { worker, http, HttpResponse, delay } })
