// calibre-hub addition (not upstream, see README.md): books are rendered in
// same-origin iframes, so anything a book could run would act with the
// app's session. The iframes are sandboxed without `allow-scripts`; this
// also removes what would run if that ever changed: script elements (HTML
// and SVG), event handler attributes, `javascript:` URLs and meta refresh.

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
