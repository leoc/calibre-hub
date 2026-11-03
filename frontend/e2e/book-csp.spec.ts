import { expect, test } from "@playwright/test"

// The reader's book pages are blob: documents in frames that allow scripts
// on WebKit (vendor/foliate-js/book-security.js). In a real browser: the
// policy put into a book document keeps its scripts from running even
// then, and without it the app's own policy, which blob: documents
// inherit, does (when the server sends it: HUB_CSP=1 / the hub).

interface Run {
  ran: string[]
}

const BOOK = `<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>t</title><script>parent.__ran.push("inline")</script></head>
<body onload="parent.__ran.push('onload')"><p>t</p><img src="data:," onerror="parent.__ran.push('onerror')"/></body></html>`

// loads the document in a frame like foliate-js does and reports which
// scripts ran
async function load(page: import("@playwright/test").Page, how: "xhtml+policy" | "html+policy" | "xhtml") {
  return page.evaluate(
    async ({ book, how }) => {
      // served by the dev server as it is (not a module of the test)
      const path = "/vendor/foliate-js/book-security.js"
      const sec = (await import(/* @vite-ignore */ path)) as typeof import("foliate-js/book-security.js")
      const w = window as unknown as { __ran: string[] }
      w.__ran = []
      let src: string
      if (how === "html+policy") {
        // comic and PDF pages: HTML from a template with BOOK_CSP_META
        src = `<!DOCTYPE html><html><head><meta charset="utf-8">${sec.BOOK_CSP_META}<script>parent.__ran.push("inline")</script></head><body onload="parent.__ran.push('onload')"><p>t</p></body></html>`
      } else {
        const doc = new DOMParser().parseFromString(book, "application/xhtml+xml")
        if (how === "xhtml+policy") sec.addBookCSP(doc)
        src = new XMLSerializer().serializeToString(doc)
      }
      const url = URL.createObjectURL(new Blob([src], { type: how === "html+policy" ? "text/html" : "application/xhtml+xml" }))
      const frame = document.createElement("iframe")
      frame.setAttribute("sandbox", sec.bookSandbox(true))
      await new Promise((resolve) => {
        frame.addEventListener("load", resolve, { once: true })
        frame.src = url
        document.body.append(frame)
      })
      await new Promise((r) => setTimeout(r, 300))
      frame.remove()
      return { ran: [...w.__ran] } as Run
    },
    { book: BOOK, how },
  )
}

test.beforeEach(async ({ page }) => {
  await page.goto("/")
  await page.waitForFunction(() => navigator.serviceWorker?.controller != null)
})

test("a book document with the policy runs no scripts, even in a frame that allows them", async ({ page }) => {
  expect(await load(page, "xhtml+policy")).toEqual({ ran: [] })
  expect(await load(page, "html+policy")).toEqual({ ran: [] })
})

test("without the policy, only the app's inherited policy stops them", async ({ page }) => {
  const { ran } = await load(page, "xhtml")
  if (process.env.HUB_CSP) expect(ran).toEqual([])
  // the mock dev server sends no policy: the frame would run them, which
  // shows the test above is not empty
  else expect(ran.sort()).toEqual(["inline", "onerror", "onload"])
})
