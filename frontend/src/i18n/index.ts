import { de, type MessageKey } from "./de"

const messages: Record<MessageKey, string> = de

export function t(key: MessageKey, params?: Record<string, string | number>): string {
  const text = messages[key]
  return params ? text.replace(/\{(\w+)\}/g, (_, k) => String(params[k] ?? `{${k}}`)) : text
}

export const locale = "de-DE"

export const formatDate = (iso: string | null) =>
  iso ? new Date(iso).toLocaleDateString(locale, { year: "numeric", month: "long", day: "numeric" }) : null

export const formatNumber = (n: number) => n.toLocaleString(locale)

const languageNames = (() => {
  try {
    return new Intl.DisplayNames([locale], { type: "language" })
  } catch {
    return null
  }
})()

// calibre stores ISO 639-2/3 codes ("deu", "eng")
const ISO3_TO_1: Record<string, string> = { deu: "de", ger: "de", eng: "en", fra: "fr", fre: "fr", spa: "es", ita: "it", nld: "nl", rus: "ru", jpn: "ja", por: "pt", pol: "pl", swe: "sv" }
export const languageName = (code: string) => languageNames?.of(ISO3_TO_1[code] ?? code) ?? code
