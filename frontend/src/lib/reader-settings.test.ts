import {
  DEFAULT_READER_SETTINGS,
  absoluteFontUrls,
  bookCSS,
  effectiveSettings,
  normalize,
  rendererAttributes,
  scaleFontSizes,
  scaleFontSizesInMarkup,
  scaledSize,
  stepFontSize,
  type ReaderSettings,
} from "./reader-settings"

const s = (patch: Partial<ReaderSettings> = {}): ReaderSettings => ({ ...DEFAULT_READER_SETTINGS, ...patch })
const SCALE = "var(--hub-font-scale, 1)"

describe("reader settings", () => {
  it("completes and checks what the hub sends", () => {
    expect(normalize(null)).toEqual(DEFAULT_READER_SETTINGS)
    expect(normalize({ fontSize: 135, theme: "sepia", columns: "2", zoom: 3 })).toEqual(s({ fontSize: 135, theme: "sepia", columns: "2" }))
    expect(normalize({ fontSize: 1000, theme: "night", justify: "yes", lineHeight: 0.5 })).toEqual(DEFAULT_READER_SETTINGS)
  })

  it("steps the font size from any size", () => {
    expect(stepFontSize(100, 1)).toBe(110)
    expect(stepFontSize(100, -1)).toBe(90)
    expect(stepFontSize(105, 1)).toBe(110)
    expect(stepFontSize(70, -1)).toBe(70)
    expect(stepFontSize(300, 1)).toBe(300)
  })

  it("never animates or scrolls on E-Ink, in black on white", () => {
    const e = effectiveSettings(s({ animated: true, flow: "scrolled", theme: "dark" }), true)
    expect(e).toMatchObject({ animated: false, flow: "paginated", theme: "eink" })
    expect(effectiveSettings(s({ theme: "dark" }), false).theme).toBe("dark")
  })

  // The bug (02.11.): the size was set on <body> only, which books with
  // absolute sizes (font-size: small on every paragraph) ignore
  it("makes absolute font sizes in the book follow the reader's size", () => {
    expect(scaledSize("small")).toBe(`calc(13px * ${SCALE})`)
    expect(scaledSize("12pt")).toBe(`calc(16px * ${SCALE})`)
    expect(scaledSize("14px")).toBe(`calc(14px * ${SCALE})`)
    expect(scaledSize("1.2rem")).toBe(`calc(1.2rem * ${SCALE})`)
    expect(scaledSize("1.2em")).toBeNull()
    expect(scaledSize("80%")).toBeNull()
    expect(scaledSize("inherit")).toBeNull()

    const css = `p.text { font-size: small; line-height: 1.2 }
.big{font-size:18px!important}
h1 { font-size: 1.5em; }
.n { font: italic bold 12pt/1.4 "Times New Roman", serif; }
.f { font-family: Georgia; font: inherit; }
@media (min-width: 40em) { .w { font-size: 10pt } }`
    const out = scaleFontSizes(css)
    expect(out).toContain(`p.text { font-size: calc(13px * ${SCALE}); line-height: 1.2 }`)
    expect(out).toContain(`.big{font-size:calc(18px * ${SCALE})!important}`)
    expect(out).toContain("h1 { font-size: 1.5em; }")
    expect(out).toContain(`font: italic bold calc(16px * ${SCALE})/1.4 "Times New Roman", serif;`)
    expect(out).toContain(".f { font-family: Georgia; font: inherit; }")
    expect(out).toContain(`.w { font-size: calc(13.333px * ${SCALE}) }`)
  })

  it("leaves the root's size alone, so rem sizes scale once", () => {
    expect(scaleFontSizes("html { font-size: 10px } p { font-size: 1.6rem }")).toBe(`html { font-size: 10px } p { font-size: calc(1.6rem * ${SCALE}) }`)
    expect(scaleFontSizes(":root{font-size:62.5%}")).toBe(":root{font-size:62.5%}")
    expect(scaleFontSizes(".html-note { font-size: small }")).toContain("calc(13px")
  })

  it("scales sizes in a document's styles and style attributes", () => {
    const html = `<html><head><style>p { font-size: 11pt; }</style></head><body><p style="font-size: small; color: red">x</p><p style='font-size:1em'>y</p><p>font-size: small</p></body></html>`
    const out = scaleFontSizesInMarkup(html)
    expect(out).toContain(`<style>p { font-size: calc(14.667px * ${SCALE}); }</style>`)
    expect(out).toContain(`style="font-size: calc(13px * ${SCALE}); color: red"`)
    expect(out).toContain(`style='font-size:1em'`)
    // text is text
    expect(out).toContain("<p>font-size: small</p>")
  })

  it("writes the size, line height, justification and hyphenation into the book's stylesheet", () => {
    const css = bookCSS(s({ fontSize: 120, lineHeight: 1.8, justify: false, hyphenate: false }))
    expect(css).toContain("--hub-font-scale: 1.2;")
    expect(css).toContain("font-size: 120% !important;")
    expect(css).toMatch(/p, li, blockquote, dd \{ line-height: 1\.8; \}/)
    expect(css).toContain("text-align: start;")
    expect(css).toContain("hyphens: manual;")
    // the book's own fonts and colors stay
    expect(css).not.toContain("font-family")
    expect(css).not.toMatch(/color: inherit/)
  })

  it("forces the settings against the book's style when asked", () => {
    const css = bookCSS(s({ override: true, fontFamily: "literata", lineHeight: 1.6 }), "@font-face { font-family: 'Literata Variable'; }")
    expect(css.startsWith("@font-face")).toBe(true)
    expect(css).toContain(`font-family: "Literata Variable", Georgia, serif !important;`)
    expect(css).toContain("line-height: 1.6 !important;")
    expect(css).toContain("text-align: justify !important;")
    expect(css).toContain("color: inherit !important;")
  })

  it("colors the page by the reader's theme, not the app's", () => {
    expect(bookCSS(s({ theme: "sepia" }))).toContain("background: #f4ecd8 !important;")
    const dark = bookCSS(s({ theme: "dark" }))
    expect(dark).toContain("color-scheme: dark;")
    expect(dark).toContain("color: #e4e4e7 !important;")
    expect(bookCSS(s({ theme: "eink" }))).toContain("a { text-decoration: underline !important; }")
    // light keeps the book's colors
    expect(bookCSS(s({ theme: "light" }))).toContain("color: #1c1917;")
  })

  it("sets the paginator's attributes", () => {
    expect(rendererAttributes(s(), 1400)).toEqual({ flow: "paginated", gap: "6%", "max-inline-size": "720px", "max-column-count": "2", animated: "" })
    expect(rendererAttributes(s({ columns: "1", animated: false, flow: "scrolled", margin: 10, maxWidth: 900 }), 1400)).toEqual({
      flow: "scrolled",
      gap: "10%",
      "max-inline-size": "900px",
      "max-column-count": "1",
      animated: null,
    })
    // two columns: each at most half the width
    expect(rendererAttributes(s({ columns: "2", maxWidth: 960 }), 1200)["max-inline-size"]).toBe("600px")
    expect(rendererAttributes(s({ columns: "2", maxWidth: 560 }), 1600)["max-inline-size"]).toBe("560px")
  })

  it("points the bundled fonts at the hub, also from the book's blob: documents", () => {
    const css = `src: url(/assets/literata-latin.woff2) format('woff2'); src: url("/node_modules/x.woff2"); src: url(data:font/woff2;base64,AA); src: url(//cdn/x)`
    expect(absoluteFontUrls(css, "https://hub.example")).toBe(
      `src: url(https://hub.example/assets/literata-latin.woff2) format('woff2'); src: url("https://hub.example/node_modules/x.woff2"); src: url(data:font/woff2;base64,AA); src: url(//cdn/x)`,
    )
  })
})
