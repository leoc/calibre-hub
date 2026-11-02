import { useState, type FormEvent } from "react"
import { useQueryClient } from "@tanstack/react-query"
import { getRouteApi, useNavigate } from "@tanstack/react-router"
import { BookOpen } from "lucide-react"
import { api, ApiError } from "@/lib/api"
import { sessionQuery } from "@/lib/queries"
import { t } from "@/i18n"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"

const route = getRouteApi("/login")

export function LoginPage() {
  const { redirect } = route.useSearch()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  async function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    const form = new FormData(e.currentTarget)
    setBusy(true)
    setError(null)
    try {
      const session = await api.login(String(form.get("user")), String(form.get("password")))
      queryClient.setQueryData(sessionQuery.queryKey, session)
      // only same-origin paths
      const target = redirect?.startsWith("/") && !redirect.startsWith("//") ? redirect : "/"
      navigate({ href: target, replace: true })
    } catch (err) {
      setError(err instanceof ApiError && err.status === 429 ? t("login.limited") : err instanceof ApiError && err.status === 401 ? t("login.wrong") : t("error.generic"))
    } finally {
      setBusy(false)
    }
  }

  return (
    <main className="flex min-h-full items-center justify-center p-4">
      <form onSubmit={submit} className="w-full max-w-sm space-y-5 rounded-lg border p-6 eink:border-2">
        <div className="flex items-center gap-2">
          <BookOpen className="size-6" aria-hidden />
          <h1 className="text-xl font-semibold">{t("login.title")}</h1>
        </div>
        <label className="block space-y-1.5">
          <span className="text-sm font-medium">{t("login.user")}</span>
          <Input name="user" autoComplete="username" autoCapitalize="none" required autoFocus />
        </label>
        <label className="block space-y-1.5">
          <span className="text-sm font-medium">{t("login.password")}</span>
          <Input name="password" type="password" autoComplete="current-password" required />
        </label>
        {error && (
          <p role="alert" className="text-sm text-destructive eink:font-bold">
            {error}
          </p>
        )}
        <Button type="submit" className="w-full" disabled={busy}>
          {t("login.submit")}
        </Button>
      </form>
    </main>
  )
}
