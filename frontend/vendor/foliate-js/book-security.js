// calibre-hub addition (not upstream, see README.md): books are rendered in
// same-origin iframes, so anything a book could run would act with the
// app's session. Three lines keep book scripts from running:
// 1. the iframe sandbox: no `allow-scripts`, except on WebKit (below)
// 2. stripScripts: script elements (HTML and SVG), event handler
//    attributes, `javascript:` URLs and meta refresh are removed
// 3. a Content-Security-Policy in every book document (addBookCSP,
//    BOOK_CSP_META) with `script-src 'none'`, on top of the app's policy
//    the blob: documents inherit where the browser implements that

// WebKit fires no events in frames sandboxed without `allow-scripts`
// (https://bugs.webkit.org/show_bug.cgi?id=218086): no keys, clicks or
// swipes inside the page. There the frames get `allow-scripts`, and lines
// 2 and 3 keep scripts out. Every browser on iOS is WebKit, whatever its
// name (CriOS, FxiOS, EdgiOS).
export const isWebKit = (win = globalThis) => {
    const nav = win.navigator ?? {}
    const ua = nav.userAgent ?? ''
    const iOS = /\b(iPhone|iPad|iPod)\b/.test(ua)
        // iPadOS reports itself as a Mac, but has touch
        || (/\bMacintosh\b/.test(ua) && (nav.maxTouchPoints ?? 0) > 1)
    if (iOS) return true
    // Safari's own gesture events, in no other engine
    if (typeof win.GestureEvent === 'function') return true
    // Chromium and its Android WebViews say AppleWebKit too
    return /AppleWebKit\//.test(ua) && !/\b(Chrome|Chromium|CriOS|Edg|OPR|Android)\b/.test(ua)
}

export const bookSandbox = (webkit = isWebKit()) =>
    webkit ? 'allow-same-origin allow-scripts' : 'allow-same-origin'

// frame-src: the app lets its own origin frame it (WebKit counts the blob:
// book pages against frame-ancestors), so a book must not lay the app under
// its page
export const BOOK_CSP = "script-src 'none'; object-src 'none'; frame-src 'none'; base-uri 'none'"
export const BOOK_CSP_META = `<meta http-equiv="Content-Security-Policy" content="${BOOK_CSP}"/>`

const URL_ATTRS = ['href', 'src', 'action', 'formaction', 'data', 'xlink:href']
// browsers drop ASCII tab/newline and leading control characters and spaces
// before looking at the scheme
const isScriptURL = value => /^javascript:/i.test(
    (value ?? '').replace(/[\u0000- ]/g, ''))

export const stripScripts = doc => {
    for (const el of Array.from(doc.getElementsByTagNameNS('*', 'script'))) el.remove()
    for (const el of Array.from(doc.getElementsByTagNameNS('*', 'meta')))
        if (/^\s*refresh\s*$/i.test(el.getAttribute('http-equiv') ?? '')) el.remove()
    for (const el of Array.from(doc.getElementsByTagName('*')))
        for (const attr of Array.from(el.attributes)) {
            const name = attr.name.toLowerCase()
            if (name.startsWith('on')
            || (URL_ATTRS.includes(name) && isScriptURL(attr.value))
            || (attr.localName.toLowerCase() === 'href' && isScriptURL(attr.value)))
                el.removeAttributeNode(attr)
        }
    return doc
}

const XHTML = 'http://www.w3.org/1999/xhtml'

// The policy as the first element of the head (a head is made when the
// document has none). Only (X)HTML documents know meta; an SVG document
// keeps lines 1 and 2 and the inherited policy.
export const addBookCSP = doc => {
    const root = doc.documentElement
    if (!root || root.localName.toLowerCase() !== 'html') return doc
    const ns = root.namespaceURI ?? XHTML
    let head = Array.from(root.children).find(el => el.localName.toLowerCase() === 'head')
    if (!head) {
        head = doc.createElementNS(ns, 'head')
        root.insertBefore(head, root.firstChild)
    }
    const meta = doc.createElementNS(ns, 'meta')
    meta.setAttribute('http-equiv', 'Content-Security-Policy')
    meta.setAttribute('content', BOOK_CSP)
    head.insertBefore(meta, head.firstChild)
    return doc
}

// both, for a book document before it is serialized into a blob: URL
export const protectDocument = doc => addBookCSP(stripScripts(doc))
