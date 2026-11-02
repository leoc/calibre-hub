require "http"
require "mime"

module CalibreHub
  # Serves the built web app (Vite dist/) without login, since the login page
  # is part of it. Unknown paths get index.html so client-side routes like
  # /books/123 load the app. API, OPDS and file routes are passed on.
  class FrontendHandler
    include HTTP::Handler

    PASS = {"/api/", "/opds", "/get/", "/healthz"}
    # not in Crystal's MIME table
    # (.mjs: pdf.js' worker is a module, refused under nosniff otherwise)
    TYPES = {".webmanifest" => "application/manifest+json", ".woff2" => "font/woff2",
             ".mjs" => "text/javascript", ".wasm" => "application/wasm"}

    def initialize(@root : String)
      @root = File.realpath(@root)
    end

    def call(context)
      req = context.request
      path = req.path
      return call_next(context) unless {"GET", "HEAD"}.includes?(req.method)
      return call_next(context) if PASS.any? { |p| path == p.rstrip('/') || path.starts_with?(p) }

      file = resolve(path) || File.join(@root, "index.html")
      return call_next(context) unless File.file?(file)
      serve(context, file)
    end

    # A file under the root, or nil (also for anything escaping it)
    def resolve(path : String) : String?
      rel = URI.decode(path).lchop('/')
      return nil if rel.empty?
      candidate = File.expand_path(rel, @root)
      return nil unless candidate.starts_with?(@root + "/")
      File.file?(candidate) ? candidate : nil
    end

    private def serve(context, file : String)
      res = context.response
      res.content_type = TYPES[File.extname(file)]? || MIME.from_filename(file, "application/octet-stream")
      # Vite puts content hashes into /assets/* names
      res.headers["Cache-Control"] = file.starts_with?(File.join(@root, "assets") + "/") ? "public, max-age=31536000, immutable" : "no-cache"
      res.headers["X-Content-Type-Options"] = "nosniff"
      res.content_length = File.size(file)
      File.open(file) { |io| IO.copy(io, res) } unless context.request.method == "HEAD"
    end
  end
end
