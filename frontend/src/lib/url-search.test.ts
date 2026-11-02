import { expect, it } from "vitest"
import { parseSearch, stringifySearch } from "./url-search"
import { librarySearchSchema } from "./search"

it("round-trips library state through a plain query string", () => {
  const state = { q: "a & b", tag: ["leseliste", "favorit"], page: 2, kategorie: "Roman.Fantasy" }
  const str = stringifySearch(state)
  expect(str).toBe("?q=a+%26+b&tag=leseliste&tag=favorit&page=2&kategorie=Roman.Fantasy")
  expect(librarySearchSchema.parse(parseSearch(str))).toEqual(state)
})

it("drops empty values", () => {
  expect(stringifySearch({ q: "", page: undefined, tag: [] })).toBe("")
})
