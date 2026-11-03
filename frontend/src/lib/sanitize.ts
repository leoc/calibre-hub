import DOMPurify from "dompurify"

// Book comments (descriptions) are HTML from book files and metadata
// sources. The hub cleans them already (src/calibre_hub/sanitizer.cr); this
// is the same allowlist again before they go into the page: these tags
// without attributes, links only to http(s) and mail, opened without
// referrer. Everything else goes, script-like elements with their content.
const TAGS = ["p", "br", "b", "strong", "i", "em", "u", "s", "ul", "ol", "li", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6", "a", "span", "div"]
const SCHEMES = new Set(["http:", "https:", "mailto:"])

const purify = DOMPurify(window)
purify.addHook("afterSanitizeAttributes", (node) => {
  if (node.nodeName !== "A") return
  const href = node.getAttribute("href")
  // no base: relative links don't count
  if (!(href != null && URL.canParse(href) && SCHEMES.has(new URL(href).protocol))) node.removeAttribute("href")
  else node.setAttribute("rel", "noopener noreferrer")
})

export function sanitize(html: string): string {
  return purify.sanitize(html, {
    ALLOWED_TAGS: TAGS,
    ALLOWED_ATTR: ["href"],
    ALLOW_DATA_ATTR: false,
    ALLOW_ARIA_ATTR: false,
  })
}
