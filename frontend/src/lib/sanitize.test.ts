import { sanitize } from "./sanitize"

// Book comments (descriptions) are HTML from book files and metadata
// sources; only the tags of the hub's Sanitizer (src/calibre_hub/sanitizer.cr)
// stay, links only to http(s) and mail (review #8411 H1).
const links = (html: string) => {
  const div = document.createElement("div")
  div.innerHTML = sanitize(html)
  return [...div.querySelectorAll("a")].map((a) => a.getAttribute("href"))
}

describe("sanitize", () => {
  it("keeps the formatting of a description", () => {
    expect(sanitize("<p>Ein <b>Buch</b> über <i>Zeit</i>.</p><ul><li>eins</li></ul><h3>Kapitel</h3><br><blockquote>Zitat</blockquote>")).toBe(
      "<p>Ein <b>Buch</b> über <i>Zeit</i>.</p><ul><li>eins</li></ul><h3>Kapitel</h3><br><blockquote>Zitat</blockquote>",
    )
  })

  it("keeps http(s) and mailto links, opened safely", () => {
    const div = document.createElement("div")
    div.innerHTML = sanitize('<a href="https://example.org/x" target="_top">x</a><a href="mailto:a@b.c">m</a>')
    expect([...div.querySelectorAll("a")].map((a) => [a.getAttribute("href"), a.getAttribute("rel"), a.getAttribute("target")])).toEqual([
      ["https://example.org/x", "noopener noreferrer", null],
      ["mailto:a@b.c", "noopener noreferrer", null],
    ])
  })

  it("drops script URLs, also hidden behind whitespace, entities or xlink", () => {
    expect(links('<a href="java&#9;script:alert(1)">a</a>')).toEqual([null])
    expect(links('<a href="&#106;avascript:alert(1)">a</a>')).toEqual([null])
    expect(links('<a href=" data:text/html,<script>alert(1)</script>">a</a>')).toEqual([null])
    expect(links('<a href="/api/books/bulk">relative</a>')).toEqual([null])
    expect(sanitize('<svg><a xlink:href="javascript:alert(1)"><text>x</text></a></svg>')).not.toMatch(/svg|xlink|javascript/)
    expect(sanitize('<math><mtext><a href="javascript:alert(1)">x</a></mtext></math>')).not.toMatch(/javascript|math/)
  })

  it("drops elements and attributes outside the allowlist", () => {
    const out = sanitize(
      '<base href="https://evil.example/"><img src=x onerror="alert(1)"><p style="color:red" class="c" onclick="x()">t</p><form action="/x"><input name="a"></form><iframe src="/"></iframe><script>alert(1)</script><style>*{}</style><details open ontoggle="x()">d</details>',
    )
    expect(out).not.toMatch(/base|img|onerror|style|onclick|form|input|iframe|script|ontoggle|alert/)
    expect(out).toContain("<p>t</p>")
  })
})
