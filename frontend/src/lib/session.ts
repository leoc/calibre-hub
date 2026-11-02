import { useQuery } from "@tanstack/react-query"
import type { Session } from "./api"
import { sessionQuery } from "./queries"

// Admins edit, upload and change many books at once; readers read and keep
// their own lists. A server from before the roles sends none: an admin.
export const isAdmin = (session: Session | undefined) => session != null && session.role !== "reader"

export function useIsAdmin(): boolean {
  const { data } = useQuery(sessionQuery)
  return isAdmin(data)
}
