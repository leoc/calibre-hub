import { useRouter, type ErrorComponentProps } from "@tanstack/react-router"
import { ApiError } from "@/lib/api"
import { t } from "@/i18n"
import { Button } from "./ui/button"

export function ErrorMessage({ error, onRetry }: { error: unknown; onRetry?: () => void }) {
  const unavailable = error instanceof ApiError && error.status === 502
  return (
    <div role="alert" className="mx-auto max-w-md space-y-4 p-8 text-center">
      <p className="text-lg font-medium">{unavailable ? t("error.unavailable") : t("error.generic")}</p>
      {!unavailable && error instanceof Error && <p className="text-sm text-muted-foreground">{error.message}</p>}
      {onRetry && (
        <Button variant="outline" onClick={onRetry}>
          {t("error.retry")}
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
