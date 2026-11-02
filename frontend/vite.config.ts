import { defineConfig } from "vitest/config"
import react from "@vitejs/plugin-react"
import tailwindcss from "@tailwindcss/vite"
import path from "node:path"
import fs from "node:fs"

// `pnpm dev` proxies to the deployed hub (log in with the real user),
// `pnpm dev:mock` serves MSW mock data instead.
const target = process.env.HUB_URL ?? "https://hub.nor.sh"

export default defineConfig(({ mode }) => ({
  plugins: [
    react(),
    tailwindcss(),
    {
      // the MSW worker lives in public/ for dev:mock only
      name: "drop-mock-worker",
      apply: "build",
      closeBundle: () => fs.rmSync(path.resolve(__dirname, "dist/mockServiceWorker.js"), { force: true }),
    },
  ],
  resolve: { alias: { "@": path.resolve(__dirname, "src") } },
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
