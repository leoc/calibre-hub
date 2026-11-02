import { describe, expect, it } from "vitest"
import { defaultBindings, diffOverrides, eventToken, formatKeys, KeyEngine, parseKeys, parseOverrides, withOverrides } from "./keymap"

const key = (k: string, mods: Partial<{ ctrlKey: boolean; altKey: boolean; metaKey: boolean; shiftKey: boolean }> = {}) => ({
  key: k,
  ctrlKey: false,
  altKey: false,
  metaKey: false,
  shiftKey: false,
  ...mods,
})

describe("eventToken", () => {
  it("keeps printable characters, Shift included", () => {
    expect(eventToken(key("j"))).toBe("j")
    expect(eventToken(key("G", { shiftKey: true }))).toBe("G")
    expect(eventToken(key(">", { shiftKey: true }))).toBe(">")
  })
  it("names the other keys with their modifiers", () => {
    expect(eventToken(key("ArrowDown"))).toBe("<Down>")
    expect(eventToken(key("ArrowDown", { shiftKey: true }))).toBe("<S-Down>")
    expect(eventToken(key("d", { ctrlKey: true }))).toBe("<C-d>")
    expect(eventToken(key("a", { metaKey: true }))).toBe("<C-a>")
    expect(eventToken(key("ArrowLeft", { altKey: true }))).toBe("<A-Left>")
    expect(eventToken(key(" "))).toBe("<Space>")
    expect(eventToken(key("Escape"))).toBe("<Esc>")
    expect(eventToken(key("F2"))).toBe("<F2>")
  })
  it("ignores modifier keys alone", () => {
    expect(eventToken(key("Shift", { shiftKey: true }))).toBeNull()
  })
})

describe("parseKeys", () => {
  it("splits sequences and normalises names", () => {
    expect(parseKeys("gg")).toEqual(["g", "g"])
    expect(parseKeys("<c-D>x")).toEqual(["<C-d>", "x"])
    expect(parseKeys("<s-down>")).toEqual(["<S-Down>"])
    expect(parseKeys("<esc>")).toEqual(["<Esc>"])
    expect(parseKeys("<f2>")).toEqual(["<F2>"])
    expect(parseKeys(">")).toEqual([">"])
    expect(parseKeys("<")).toEqual(["<"])
  })
  it("formats keys for people", () => {
    expect(formatKeys("<C-d>")).toBe("Strg+D")
    expect(formatKeys("<S-Down>")).toBe("Shift+↓")
    expect(formatKeys("gg")).toBe("g g")
  })
})

describe("KeyEngine", () => {
  const feed = (e: KeyEngine, keys: string) => parseKeys(keys).map((k) => e.feed(k))

  it("runs app keys in both modes, Vim keys only in Vim mode", () => {
    const app = new KeyEngine(defaultBindings("app"), false)
    expect(app.feed("<Down>")).toEqual({ type: "action", action: "down", count: null })
    expect(app.feed("j")).toEqual({ type: "none" })
    const vim = new KeyEngine(defaultBindings("vim"), true)
    expect(vim.feed("<Down>")).toEqual({ type: "action", action: "down", count: null })
    expect(vim.feed("j")).toEqual({ type: "action", action: "down", count: null })
  })

  it("collects counts and sequences in Vim mode", () => {
    const vim = new KeyEngine(defaultBindings("vim"), true)
    expect(feed(vim, "3j").at(-1)).toEqual({ type: "action", action: "down", count: 3 })
    expect(feed(vim, "12l").at(-1)).toEqual({ type: "action", action: "right", count: 12 })
    expect(vim.feed("g")).toEqual({ type: "pending" })
    expect(vim.pending).toBe("g")
    expect(vim.feed("g")).toEqual({ type: "action", action: "first", count: null })
    expect(vim.pending).toBe("")
  })

  it("starts over when a key fits nothing", () => {
    const vim = new KeyEngine(defaultBindings("vim"), true)
    vim.feed("g")
    expect(vim.feed("j")).toEqual({ type: "action", action: "down", count: null })
    vim.feed("5")
    expect(vim.feed("x")).toEqual({ type: "none" })
    expect(vim.pending).toBe("")
  })

  it("takes no counts in App mode", () => {
    const app = new KeyEngine(defaultBindings("app"), false)
    expect(app.feed("3")).toEqual({ type: "none" })
  })
})

describe("own bindings", () => {
  it("parses the stored JSON and drops what it does not know", () => {
    expect(parseOverrides('{"down": ["n", "j"], "nope": ["x"], "up": "k", "left": []}')).toEqual({ down: ["n", "j"], left: [] })
    expect(parseOverrides("not json")).toEqual({})
    expect(parseOverrides(null)).toEqual({})
  })
  it("keeps only what differs from the defaults and replaces those actions", () => {
    const base = defaultBindings("vim")
    const diff = diffOverrides(base, { ...base, down: ["n", ...(base.down ?? [])] })
    expect(diff).toEqual({ down: ["n", "j", "<Down>"] })
    const engine = new KeyEngine(withOverrides(base, diff), true)
    expect(engine.feed("n")).toEqual({ type: "action", action: "down", count: null })
  })
  it("can take a key away", () => {
    const engine = new KeyEngine(withOverrides(defaultBindings("vim"), { down: ["<Down>"] }), true)
    expect(engine.feed("j")).toEqual({ type: "none" })
  })
})
