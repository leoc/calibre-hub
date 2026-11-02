// calibre only takes JPEG and PNG; everything else (WebP, HEIC the browser
// can decode, huge PNGs) goes through a canvas to JPEG.
export async function toCoverImage(file: Blob, maxSide = 2000): Promise<Blob> {
  if ((file.type === "image/jpeg" || file.type === "image/png") && file.size < 5 * 1024 * 1024) return file
  const bitmap = await createImageBitmap(file)
  const scale = Math.min(1, maxSide / Math.max(bitmap.width, bitmap.height))
  const canvas = document.createElement("canvas")
  canvas.width = Math.round(bitmap.width * scale)
  canvas.height = Math.round(bitmap.height * scale)
  canvas.getContext("2d")!.drawImage(bitmap, 0, 0, canvas.width, canvas.height)
  bitmap.close()
  return new Promise((resolve, reject) => canvas.toBlob((b) => (b ? resolve(b) : reject(new Error("encode failed"))), "image/jpeg", 0.9))
}
