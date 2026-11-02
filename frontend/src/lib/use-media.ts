import { useSyncExternalStore } from "react"

export function useMedia(query: string): boolean {
  return useSyncExternalStore(
    (cb) => {
      const mq = matchMedia(query)
      mq.addEventListener("change", cb)
      return () => mq.removeEventListener("change", cb)
    },
    () => matchMedia(query).matches,
    () => false,
  )
}

// Tailwind's lg breakpoint: sidebar and detail panel
export const useDesktop = () => useMedia("(min-width: 1024px)")
