import { clsx, type ClassValue } from "clsx"
import { twMerge } from "tailwind-merge"

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs))
}

// macOS and iOS show ⌘ for the shortcut modifier, everything else Ctrl
export function isApple(nav: { platform?: string; userAgentData?: { platform?: string } } = navigator as never) {
  const platform = nav.userAgentData?.platform || nav.platform || ""
  return /mac|iphone|ipad|ipod/i.test(platform)
}
