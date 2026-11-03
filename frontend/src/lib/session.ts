import { useQuery } from "@tanstack/react-query"
import type { Session } from "./api"
import { sessionQuery } from "./queries"

// Admins edit, upload and change many books at once; readers read and keep
// their own lists. A server from before the roles sends none: an admin.
export const isAdmin = (session: Session | undefined) => session != null && session.role !== "reader"

// A list's settings (name, description, visibility, sync, favorite, default)
// are its owner's, or an admin's; others only add and remove books of an
// editable list
export const mayConfigureList = (session: Session | undefined, list: { owner: string }) => session != null && (session.user === list.owner || isAdmin(session))

// Syncing lists to a reader folder: admins, and readers with a folder of
// their own (the hub says so in the session; older hubs: admins only)
export const maySync = (session: Session | undefined) => session != null && (isAdmin(session) || !!session.sync)

export function useIsAdmin(): boolean {
  const { data } = useQuery(sessionQuery)
  return isAdmin(data)
}
