import { addBookCSP, BOOK_CSP, bookSandbox, isWebKit, protectDocument, stripScripts } from "foliate-js/book-security.js"

// What keeps a book's scripts from running in the reader
// (vendor/foliate-js/book-security.js): the iframe sandbox, what is removed
// from a book's documents and the CSP put into them.
const xhtml = (body: string) =>
  new DOMParser().parseFromString(
    `<html xmlns="http://www.w3.org/1999/xhtml" xmlns:xlink="http://www.w3.org/1999/xlink"><head><script>1</script><meta http-equiv="Refresh" content="0;url=https://x.example/"/></head><body onload="x()">${body}</body></html>`,
    "application/xhtml+xml",
  )

describe("stripScripts", () => {
  it("removes scripts, handlers, meta refresh and javascript: URLs", () => {
    const doc = stripScripts(
      xhtml(
        `<p onclick="x()" class="a">Text</p><a href="java&#9;script:x()">a</a><a href=" JavaScript:x()">b</a><a href="https://ok.example/">c</a>` +
          `<svg xmlns="http://www.w3.org/2000/svg" onload="x()"><script>2</script><a xlink:href="javascript:x()"><text>d</text></a></svg><img src="i.png" onerror="x()"/>`,
      ),
    )
    const html = new XMLSerializer().serializeToString(doc)
    expect(html).not.toMatch(/script>|onload|onclick|onerror|javascript|Refresh/i)
    expect(doc.querySelector("p")?.getAttribute("class")).toBe("a")
    expect(doc.querySelector("img")?.getAttribute("src")).toBe("i.png")
    expect([...doc.querySelectorAll("a")].map((a) => a.getAttribute("href"))).toEqual([null, null, "https://ok.example/", null])
  })
})

const UA = {
  safariMac: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15",
  safariIPhone: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1",
  chromeIPhone: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/130.0.6723.90 Mobile/15E148 Safari/604.1",
  firefoxIPad: "Mozilla/5.0 (iPad; CPU OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) FxiOS/132.0 Mobile/15E148 Safari/605.1.15",
  epiphany: "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
  chromeMac: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36",
  chromeAndroid: "Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36",
  booxWebView: "Mozilla/5.0 (Linux; Android 12; NoteAir3 Build/SKQ1; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/120.0 Safari/537.36",
  edge: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0",
  firefox: "Mozilla/5.0 (X11; Linux x86_64; rv:132.0) Gecko/20100101 Firefox/132.0",
}
const win = (userAgent: string, extra: { maxTouchPoints?: number; GestureEvent?: unknown } = {}) => ({
  navigator: { userAgent, maxTouchPoints: extra.maxTouchPoints ?? 0 },
  GestureEvent: extra.GestureEvent,
})

describe("isWebKit and bookSandbox", () => {
  it("knows WebKit: Safari, every browser on iOS and iPadOS, other WebKit browsers", () => {
    for (const ua of [UA.safariMac, UA.safariIPhone, UA.chromeIPhone, UA.firefoxIPad, UA.epiphany]) expect(isWebKit(win(ua))).toBe(true)
    // iPadOS asks for desktop sites as a Mac, but has touch
    expect(isWebKit(win(UA.safariMac, { maxTouchPoints: 5 }))).toBe(true)
    // Safari's gesture events, whatever the user agent says
    expect(isWebKit(win(UA.chromeMac, { GestureEvent: class {} }))).toBe(true)
  })

  it("Chromium, its WebViews and Firefox are not WebKit", () => {
    for (const ua of [UA.chromeMac, UA.chromeAndroid, UA.booxWebView, UA.edge, UA.firefox]) expect(isWebKit(win(ua))).toBe(false)
  })

  it("allows scripts in the frames on WebKit only, always same origin", () => {
    expect(bookSandbox(false)).toBe("allow-same-origin")
    expect(bookSandbox(true)).toBe("allow-same-origin allow-scripts")
  })
})

describe("addBookCSP", () => {
  const csp = (doc: Document) => [...doc.getElementsByTagNameNS("*", "meta")].find((m) => m.getAttribute("http-equiv") === "Content-Security-Policy")

  it("puts script-src 'none' first into the head of XHTML and HTML documents", () => {
    expect(BOOK_CSP).toContain("script-src 'none'")
    // the app may be framed by its own origin, a book may not do that
    expect(BOOK_CSP).toContain("frame-src 'none'")
    const doc = addBookCSP(xhtml("<p>t</p>"))
    const meta = csp(doc)!
    expect(meta.getAttribute("content")).toBe(BOOK_CSP)
    expect(meta.parentElement?.localName).toBe("head")
    expect(meta.parentElement?.firstElementChild).toBe(meta)
    expect(meta.namespaceURI).toBe("http://www.w3.org/1999/xhtml")
    const html = addBookCSP(new DOMParser().parseFromString("<p>t</p>", "text/html"))
    expect(csp(html)?.parentElement).toBe(html.head)
  })

  it("makes a head when the document has none", () => {
    const doc = addBookCSP(new DOMParser().parseFromString('<html xmlns="http://www.w3.org/1999/xhtml"><body><p>t</p></body></html>', "application/xhtml+xml"))
    expect(doc.documentElement.firstElementChild?.localName).toBe("head")
    expect(new XMLSerializer().serializeToString(doc)).toMatch(/<head><meta http-equiv="Content-Security-Policy" content="script-src 'none';[^"]*" ?\/><\/head><body>/)
  })

  it("protectDocument strips and adds the policy", () => {
    const doc = protectDocument(xhtml('<p onclick="x()">t</p>'))
    expect(csp(doc)).toBeTruthy()
    expect(new XMLSerializer().serializeToString(doc)).not.toMatch(/<script|onclick/)
  })
})
