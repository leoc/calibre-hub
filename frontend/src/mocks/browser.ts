import { delay, http, HttpResponse } from "msw"
import { setupWorker } from "msw/browser"
import { handlers } from "./handlers"

export const worker = setupWorker(...handlers)

// Lets screenshot scripts and e2e tests switch states (errors, slow
// responses) at runtime: window.__msw.worker.use(window.__msw.http.get(…)).
Object.assign(window, { __msw: { worker, http, HttpResponse, delay } })
