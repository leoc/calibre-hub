// Theme before first paint, see src/lib/theme.tsx. A file, not inline in
// index.html: the hub's Content-Security-Policy allows no inline scripts.
try {
  var t = localStorage.getItem("hub.theme") || "system"
  var dark = t === "dark" || (t === "system" && matchMedia("(prefers-color-scheme: dark)").matches)
  document.documentElement.classList.toggle("dark", dark)
  document.documentElement.classList.toggle("eink", t === "eink")
} catch (e) {}
