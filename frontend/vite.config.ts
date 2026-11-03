import { defineConfig } from "vitest/config"
import type { Plugin } from "vite"
import react from "@vitejs/plugin-react"
import tailwindcss from "@tailwindcss/vite"
import path from "node:path"
import fs from "node:fs"
import crypto from "node:crypto"

// `pnpm dev` proxies to the deployed hub (log in with the real user),
// `pnpm dev:mock` serves MSW mock data instead.
const target = process.env.HUB_URL ?? "https://hub.nor.sh"

// HUB_CSP=1: the dev server sends the hub's Content-Security-Policy (read
// from src/calibre_hub/security_headers.cr, so it is the same), plus what
// dev needs only: a nonce for Vite's inline scripts and its HMR websocket.
// Violations are reported to /__csp-report and printed as "CSP violation".
// `HUB_CSP=1 pnpm e2e` runs every test under it.
function hubCsp(): Plugin {
  const nonce = crypto.randomBytes(16).toString("base64")
  const policy = () => {
    const cr = fs.readFileSync(path.resolve(import.meta.dirname, "../src/calibre_hub/security_headers.cr"), "utf8")
    const block = /APP_CSP = \{([\s\S]*?)\}\.join/.exec(cr)?.[1]
    if (!block) throw new Error("APP_CSP not found in security_headers.cr")
    return [...block.matchAll(/"([^"]+)"/g)]
      .map(([, d]) => d)
      .map((d) => (d.startsWith("script-src ") ? `${d} 'nonce-${nonce}'` : d.startsWith("connect-src ") ? `${d} ws://localhost:*` : d))
      .concat("report-uri /__csp-report")
      .join("; ")
  }
  return {
    name: "hub-csp",
    apply: "serve",
    config: () => ({ html: { cspNonce: nonce } }),
    configureServer(server) {
      const csp = policy()
      server.middlewares.use((req, res, next) => {
        if (req.url === "/__csp-report" && req.method === "POST") {
          let body = ""
          req.on("data", (c) => (body += c))
          req.on("end", () => {
            console.error(`CSP violation: ${body}`)
            res.statusCode = 204
            res.end()
          })
          return
        }
        res.setHeader("Content-Security-Policy", csp)
        next()
      })
    },
  }
}

export default defineConfig(({ mode }) => ({
  plugins: [
    react(),
    tailwindcss(),
    ...(process.env.HUB_CSP ? [hubCsp()] : []),
    {
      // the MSW worker lives in public/ for dev:mock only; the app's own
      // service worker (src/service-worker.js) precaches every built file
      name: "service-worker",
      apply: "build",
      closeBundle: () => {
        const dist = path.resolve(import.meta.dirname, "dist")
        fs.rmSync(path.join(dist, "mockServiceWorker.js"), { force: true })
        const files = fs
          .readdirSync(dist, { recursive: true, encoding: "utf8" })
          .map((f) => f.split(path.sep).join("/"))
          .filter((f) => f !== "sw.js" && f !== "mockServiceWorker.js" && fs.statSync(path.join(dist, f)).isFile())
          .sort()
        const hash = crypto.createHash("sha256")
        for (const f of files) hash.update(f).update(fs.readFileSync(path.join(dist, f)))
        const sw = fs
          .readFileSync(path.resolve(import.meta.dirname, "src/service-worker.js"), "utf8")
          .replace('"__VERSION__"', JSON.stringify(hash.digest("hex").slice(0, 12)))
          .replace("__FILES__", JSON.stringify(files.map((f) => `/${f}`)))
        fs.writeFileSync(path.join(dist, "sw.js"), sw)
      },
    },
  ],
  // foliate-js is vendored at a fixed commit (vendor/foliate-js/README.md)
  resolve: { alias: { "@": path.resolve(import.meta.dirname, "src"), "foliate-js": path.resolve(import.meta.dirname, "vendor/foliate-js") } },
  server: {
    port: 5173,
    proxy:
      mode === "mock"
        ? undefined
        : {
            "/api": {
              target,
              changeOrigin: true,
              // the hub sets a Secure cookie; drop Secure/Domain for http://localhost
              cookieDomainRewrite: "",
              configure: (proxy) =>
                proxy.on("proxyRes", (res) => {
                  const c = res.headers["set-cookie"]
                  if (c) res.headers["set-cookie"] = c.map((v) => v.replace(/;\s*Secure/i, ""))
                }),
            },
          },
  },
  build: { chunkSizeWarningLimit: 700 },
  test: {
    environment: "jsdom",
    globals: true,
    setupFiles: ["src/test-setup.ts"],
    include: ["src/**/*.test.{ts,tsx}"],
  },
}))
