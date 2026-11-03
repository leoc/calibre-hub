require "http"

module CalibreHub
  # Security headers on every response (review #8411 M2). HSTS is Traefik's
  # job (TLS ends there).
  #
  # The web app gets a Content-Security-Policy that allows only its own
  # scripts: no inline scripts (index.html loads theme-init.js), nothing from
  # blob: (the reader's book documents are blob: iframes and inherit this
  # policy, so a script in a book can't run even without the sandbox).
  # - style-src 'unsafe-inline': React style attributes, foliate-js and
  #   pdf.js inject styles; blob:: a book's stylesheets in the reader
  # - img-src https:: cover and metadata suggestions show remote covers
  # - frame-src/child-src blob:: the reader's book pages
  # - worker-src: pdf.js' worker (/assets) and the service worker (/sw.js)
  # API, OPDS and file responses are data, never documents: nothing at all.
  class SecurityHeadersHandler
    include HTTP::Handler

    APP_CSP = {
      "default-src 'self'",
      "script-src 'self'",
      "style-src 'self' 'unsafe-inline' blob:",
      "img-src 'self' data: blob: https:",
      "font-src 'self' data: blob:",
      "media-src 'self' data: blob:",
      "connect-src 'self' data: blob:",
      "frame-src 'self' blob:",
      "child-src 'self' blob:",
      "worker-src 'self' blob:",
      "manifest-src 'self'",
      "object-src 'none'",
      "base-uri 'none'",
      "form-action 'self'",
      "frame-ancestors 'none'",
    }.join("; ")
    DATA_CSP = "default-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
    DATA_PATHS = {"/api/", "/opds", "/get/", "/healthz"}

    HEADERS = {
      "X-Content-Type-Options" => "nosniff",
      "Referrer-Policy"        => "same-origin",
      "X-Frame-Options"        => "DENY",
      "Permissions-Policy"     => "camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()",
      "Cross-Origin-Opener-Policy" => "same-origin",
    }

    def self.csp(path : String) : String
      DATA_PATHS.any? { |p| path == p.rstrip('/') || path.starts_with?(p) } ? DATA_CSP : APP_CSP
    end

    def call(context)
      headers = context.response.headers
      HEADERS.each { |k, v| headers[k] = v }
      headers["Content-Security-Policy"] = SecurityHeadersHandler.csp(context.request.path)
      call_next(context)
    end
  end
end
