import { useEffect } from "react"
import { useRouter, type ErrorComponentProps } from "@tanstack/react-router"
import { CloudOff, RotateCcw, ServerOff, TriangleAlert } from "lucide-react"
import { ApiError } from "@/lib/api"
import { isNetworkError } from "@/lib/online"
import { t } from "@/i18n"
import { Button } from "./ui/button"
import { OfflineBooks } from "./offline"

export function ErrorMessage({ error, onRetry }: { error: unknown; onRetry?: () => void }) {
  const unavailable = error instanceof ApiError && error.status === 502
  const offline = isNetworkError(error)
  const Icon = offline ? CloudOff : unavailable ? ServerOff : TriangleAlert
  return (
    <div role="alert" className="mx-auto flex max-w-md flex-col items-center gap-3 px-4 py-12 text-center">
      <Icon className="size-8 text-muted-foreground eink:text-black" aria-hidden />
      <p className="text-lg font-medium">{offline ? t("offline.title") : unavailable ? t("error.unavailable") : t("error.generic")}</p>
      {offline ? (
        <p className="text-sm text-muted-foreground eink:text-base eink:text-black">{t("offline.hint")}</p>
      ) : unavailable ? (
        <p className="text-sm text-muted-foreground eink:text-base eink:text-black">{t("error.unavailableHint")}</p>
      ) : (
        error instanceof Error && <p className="text-sm break-words text-muted-foreground eink:text-base eink:text-black">{error.message}</p>
      )}
      {onRetry && (
        <Button variant="outline" className="mt-2" onClick={onRetry}>
          <RotateCcw /> {t("error.retry")}
        </Button>
      )}
    </div>
  )
}

// Without the hub (offline, or calibre-server down) the books stored
// offline are listed to read; back online, the page tries again by itself
export function ErrorView({ error, reset }: ErrorComponentProps) {
  const router = useRouter()
  const offline = isNetworkError(error)
  useEffect(() => {
    if (!offline) return
    const onOnline = () => {
      reset()
      void router.invalidate()
    }
    window.addEventListener("online", onOnline)
    return () => window.removeEventListener("online", onOnline)
  }, [offline, reset, router])
  return (
    <>
      <ErrorMessage
        error={error}
        onRetry={() => {
          reset()
          router.invalidate()
        }}
      />
      {(offline || (error instanceof ApiError && error.status === 502)) && <OfflineBooks />}
    </>
  )
}
