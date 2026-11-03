import { z } from "zod"

// zod would probe `new Function` for faster parsing, which the hub's CSP
// forbids (no 'unsafe-eval'): a CSP violation report on every page load.
// Imported first in main.tsx, before any schema is built.
z.config({ jitless: true })
