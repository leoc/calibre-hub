import { describe, expect, it } from "vitest"
import { languageName } from "./index"

describe("languageName", () => {
  it("names ISO 639-2 codes", () => {
    expect(languageName("deu")).toBe("Deutsch")
  })

  it("keeps values that aren't language tags instead of throwing", () => {
    expect(languageName("Icelandic")).toBe("Icelandic")
    expect(languageName("")).toBe("")
  })
})
