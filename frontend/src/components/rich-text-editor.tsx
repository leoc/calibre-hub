import { EditorContent, useEditor, useEditorState } from "@tiptap/react"
import StarterKit from "@tiptap/starter-kit"
import { Bold, Italic, Link2, List, ListOrdered, Redo, Undo } from "lucide-react"
import { cn } from "@/lib/utils"

// Loaded lazily, only in edit mode. Headings, code and strike are off:
// calibre comments are short blurbs.
export default function RichTextEditor({ value, onChange, label }: { value: string; onChange: (html: string) => void; label: string }) {
  const editor = useEditor({
    extensions: [StarterKit.configure({ heading: false, code: false, codeBlock: false, strike: false, horizontalRule: false, link: { openOnClick: false, autolink: true } })],
    content: value,
    onUpdate: ({ editor }) => onChange(editor.isEmpty ? "" : editor.getHTML()),
    editorProps: {
      attributes: {
        "aria-label": label,
        class: "min-h-32 max-h-[50vh] overflow-y-auto px-3 py-2 outline-none [&_ol]:ml-5 [&_ol]:list-decimal [&_ul]:ml-5 [&_ul]:list-disc [&_p]:my-1.5 [&_a]:underline",
      },
    },
  })
  const state = useEditorState({
    editor,
    selector: ({ editor }) => ({
      bold: editor?.isActive("bold"),
      italic: editor?.isActive("italic"),
      bullet: editor?.isActive("bulletList"),
      ordered: editor?.isActive("orderedList"),
      link: editor?.isActive("link"),
    }),
  })
  if (!editor) return null
  const btn = (on: boolean | undefined, title: string, run: () => void, Icon: typeof Bold) => (
    <button
      type="button"
      title={title}
      aria-label={title}
      aria-pressed={!!on}
      onClick={run}
      className="flex size-8 items-center justify-center rounded-sm hover:bg-accent aria-pressed:bg-accent eink:size-11 touch:size-11 eink:aria-pressed:bg-black eink:aria-pressed:text-white"
    >
      <Icon className="size-4" />
    </button>
  )
  return (
    <div className={cn("rounded-md border border-input shadow-xs focus-within:border-ring focus-within:ring-[3px] focus-within:ring-ring/50 eink:border-2")}>
      <div className="flex flex-wrap gap-0.5 border-b p-1 eink:border-b-2">
        {btn(state?.bold, "Fett", () => editor.chain().focus().toggleBold().run(), Bold)}
        {btn(state?.italic, "Kursiv", () => editor.chain().focus().toggleItalic().run(), Italic)}
        {btn(state?.bullet, "Liste", () => editor.chain().focus().toggleBulletList().run(), List)}
        {btn(state?.ordered, "Nummerierte Liste", () => editor.chain().focus().toggleOrderedList().run(), ListOrdered)}
        {btn(state?.link, "Link", () => {
          if (editor.isActive("link")) return editor.chain().focus().unsetLink().run()
          const href = window.prompt("URL")
          if (href) editor.chain().focus().setLink({ href }).run()
        }, Link2)}
        <span className="flex-1" />
        {btn(false, "Rückgängig", () => editor.chain().focus().undo().run(), Undo)}
        {btn(false, "Wiederholen", () => editor.chain().focus().redo().run(), Redo)}
      </div>
      <EditorContent editor={editor} />
    </div>
  )
}
