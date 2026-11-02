import { useState } from "react"
import { Trash2 } from "lucide-react"
import { ApiError, type Book } from "@/lib/api"
import { useDeleteBook } from "@/lib/mutations"
import { t } from "@/i18n"
import { Button } from "./ui/button"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "./ui/dialog"

// "Löschen" with a confirmation; the book goes to calibre's trash.
export function DeleteBookButton({ book, onDeleted }: { book: Book; onDeleted: () => void }) {
  const [open, setOpen] = useState(false)
  const del = useDeleteBook()
  return (
    <>
      <Button type="button" variant="outline" onClick={() => setOpen(true)}>
        <Trash2 /> {t("book.delete")}
      </Button>
      <Dialog open={open} onOpenChange={(o) => !del.isPending && setOpen(o)}>
        <DialogContent>
          <DialogTitle className="text-lg font-semibold">{t("delete.title")}</DialogTitle>
          <DialogDescription>{t("delete.text", { title: book.title })}</DialogDescription>
          {del.error && (
            <p role="alert" className="text-sm text-destructive">
              {t("delete.error")}: {del.error instanceof ApiError ? del.error.message : String(del.error)}
            </p>
          )}
          <div className="flex justify-end gap-2">
            <Button variant="outline" onClick={() => setOpen(false)} disabled={del.isPending}>
              {t("edit.cancel")}
            </Button>
            <Button
              variant="destructive"
              disabled={del.isPending}
              onClick={() =>
                del.mutate(book.id, {
                  onSuccess: () => {
                    setOpen(false)
                    onDeleted()
                  },
                })
              }
            >
              <Trash2 /> {t("delete.confirm")}
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </>
  )
}
