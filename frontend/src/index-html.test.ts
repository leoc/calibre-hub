import fs from "node:fs"
import path from "node:path"

// The hub's Content-Security-Policy allows only the app's own script files
// (script-src 'self', src/calibre_hub/security_headers.cr): index.html must
// not have inline scripts or event handler attributes.
describe("index.html", () => {
  const html = fs.readFileSync(path.resolve(import.meta.dirname, "../index.html"), "utf8")

  it("loads every script from a file", () => {
    const scripts = [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)]
    expect(scripts.length).toBeGreaterThan(0)
    for (const [, attrs, body] of scripts) {
      expect(attrs).toMatch(/\ssrc=/)
      expect(body.trim()).toBe("")
    }
  })

  it("has no event handler attributes", () => {
    expect(html).not.toMatch(/\son[a-z]+\s*=/i)
  })
})
