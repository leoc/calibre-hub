// The app offline: built into dist/sw.js by vite.config.ts, which fills in
// the built files and a version (a hash over their contents).
//
// - install: the whole build (app shell, reader, foliate-js, pdf.js) into
//   "hub-shell-<version>"; activate: older shells are deleted
// - navigations: the network first; offline, or the hub answering 5xx,
//   index.html from the cache (the app then shows the books stored offline)
// - other files of the build: from the cache, else the network
// - /api/, /get/, /opds and /healthz are never touched or cached. Books
//   made available offline live in "hub-books", written by the page itself
//   (src/lib/offline.ts).
/* global self, caches, fetch, Response, Request, URL */

const VERSION = "__VERSION__"
const FILES = __FILES__
const SHELL = `hub-shell-${VERSION}`
const PASS = ["/api/", "/get/", "/opds", "/healthz"]

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches
      .open(SHELL)
      .then((cache) => cache.addAll(FILES.map((f) => new Request(f, { cache: "reload" }))))
      .then(() => self.skipWaiting()),
  )
})

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k.startsWith("hub-shell-") && k !== SHELL).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  )
})

const shell = () => caches.match("/index.html", { cacheName: SHELL, ignoreVary: true })

self.addEventListener("fetch", (event) => {
  const req = event.request
  if (req.method !== "GET") return
  const url = new URL(req.url)
  if (url.origin !== self.location.origin) return
  if (PASS.some((p) => url.pathname === p.replace(/\/$/, "") || url.pathname.startsWith(p))) return

  if (req.mode === "navigate") {
    event.respondWith(
      fetch(req)
        .then((res) => (res.status >= 500 ? shell().then((s) => s || res) : res))
        .catch(() => shell().then((s) => s || Response.error())),
    )
    return
  }
  // ignoreVary: module scripts ask with an Origin header, the precache did not
  event.respondWith(caches.match(req, { cacheName: SHELL, ignoreVary: true }).then((hit) => hit || fetch(req)))
})
