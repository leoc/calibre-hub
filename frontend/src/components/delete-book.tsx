import { useState } from "react"
import { Trash2 } from "lucide-react"
import { ApiError, type Book } from "@/lib/api"
import { useDeleteBook } from "@/lib/mutations"
import { leaveOverlays } from "@/lib/back-to-close"
import { t } from "@/i18n"
import { Button } from "./ui/button"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "./ui/dialog"

// "Löschen" with a confirmation; the book goes to calibre's trash.
export function DeleteBookButton({ book, onDeleted }: { book: Book; onDeleted: () => void }) {
  const [open, setOpen] = useState(false)
  return (
    <>
      <Button type="button" variant="outline" className="text-destructive hover:text-destructive eink:text-black eink:hover:text-white" onClick={() => setOpen(true)}>
        <Trash2 /> {t("book.delete")}
      </Button>
      {open && <DeleteBookDialog book={book} onClose={() => setOpen(false)} onDeleted={onDeleted} />}
    </>
  )
}

// The confirmation alone (also from the keyboard: Delete, dd).
export function DeleteBookDialog({ book, onClose, onDeleted }: { book: Book; onClose: () => void; onDeleted: () => void }) {
  const del = useDeleteBook()
  return (
    <Dialog open onOpenChange={(o) => !o && !del.isPending && onClose()}>
      <DialogContent>
        <DialogTitle className="text-lg font-semibold">{t("delete.title")}</DialogTitle>
        <DialogDescription>{t("delete.text", { title: book.title })}</DialogDescription>
        {del.error && (
          <p role="alert" className="text-sm text-destructive">
            {t("delete.error")}: {del.error instanceof ApiError ? del.error.message : String(del.error)}
          </p>
        )}
        <div className="flex justify-end gap-2">
          <Button variant="outline" onClick={onClose} disabled={del.isPending}>
            {t("edit.cancel")}
          </Button>
          <Button
            variant="destructive"
            disabled={del.isPending}
            onClick={() =>
              del.mutate(book.id, {
                onSuccess: () => {
                  // drop the dialog's history entry before leaving the book
                  const left = leaveOverlays()
                  onClose()
                  left.then(onDeleted)
                },
              })
            }
          >
            <Trash2 /> {t("delete.confirm")}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  )
}
