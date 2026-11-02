import { defineConfig } from "vitest/config"
import react from "@vitejs/plugin-react"
import tailwindcss from "@tailwindcss/vite"
import path from "node:path"
import fs from "node:fs"
import crypto from "node:crypto"

// `pnpm dev` proxies to the deployed hub (log in with the real user),
// `pnpm dev:mock` serves MSW mock data instead.
const target = process.env.HUB_URL ?? "https://hub.nor.sh"

export default defineConfig(({ mode }) => ({
  plugins: [
    react(),
    tailwindcss(),
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
