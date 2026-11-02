import { useRouter, type ErrorComponentProps } from "@tanstack/react-router"
import { RotateCcw, ServerOff, TriangleAlert } from "lucide-react"
import { ApiError } from "@/lib/api"
import { t } from "@/i18n"
import { Button } from "./ui/button"

export function ErrorMessage({ error, onRetry }: { error: unknown; onRetry?: () => void }) {
  const unavailable = error instanceof ApiError && error.status === 502
  const Icon = unavailable ? ServerOff : TriangleAlert
  return (
    <div role="alert" className="mx-auto flex max-w-md flex-col items-center gap-3 px-4 py-12 text-center">
      <Icon className="size-8 text-muted-foreground eink:text-black" aria-hidden />
      <p className="text-lg font-medium">{unavailable ? t("error.unavailable") : t("error.generic")}</p>
      {unavailable ? (
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

export function ErrorView({ error, reset }: ErrorComponentProps) {
  const router = useRouter()
  return (
    <ErrorMessage
      error={error}
      onRetry={() => {
        reset()
        router.invalidate()
      }}
    />
  )
}
