import { expect, test } from "@playwright/test"

// Regressions from Arthur's test round (02.11.)

test("the drop overlay stays while dragging over the page", async ({ page }) => {
  await page.goto("/")
  await expect(page.getByText(/^\d+ Bücher$/)).toBeVisible()
  const drag = (type: string, selector: string) =>
    page.evaluate(
      ([type, selector]) => {
        const dt = new DataTransfer()
        dt.items.add(new File(["x"], "a.epub"))
        document.querySelector(selector)!.dispatchEvent(new DragEvent(type, { dataTransfer: dt, bubbles: true }))
      },
      [type, selector],
    )
  await drag("dragenter", "body")
  await expect(page.getByText("Dateien hier ablegen")).toBeVisible()
  // moving onto child elements: enter the child, then leave the parent
  for (const sel of ["main", "header", "main li"]) {
    await drag("dragenter", sel)
    await drag("dragleave", "body")
  }
  await expect(page.getByText("Dateien hier ablegen")).toBeVisible()
  await drag("drop", "main")
  await expect(page.getByText("Dateien hier ablegen")).toBeHidden()
})

test("controls in a toolbar row share one height", async ({ page }) => {
  await page.goto("/")
  await expect(page.getByText(/^\d+ Bücher$/)).toBeVisible()
  const heights = async () =>
    page.evaluate(() => {
      const bar = document.querySelector("main")!.querySelector("select")!.closest("div")!.parentElement!
      return [...bar.querySelectorAll("button, select, input")]
        .filter((e) => (e as HTMLElement).offsetParent)
        .map((e) => Math.round(e.getBoundingClientRect().height))
    })
  const h = await heights()
  expect(h.length).toBeGreaterThan(3)
  expect(new Set(h).size, `heights ${h}`).toBe(1)
})
