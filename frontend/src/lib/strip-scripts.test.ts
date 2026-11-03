import { stripScripts } from "foliate-js/strip-scripts.js"

// What foliate-js removes from a book's documents before they are shown
// (vendor/foliate-js/strip-scripts.js); the iframes run no scripts anyway.
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
