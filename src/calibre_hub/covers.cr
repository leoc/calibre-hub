require "http/client"
require "openssl"
require "socket"
require "uri"
require "json"
require "./book"

module CalibreHub
  module Covers
    MAX_BYTES = 10 * 1024 * 1024
    TIMEOUT   = 15.seconds
    REDIRECTS = 3

    class FetchError < Exception
    end

    # jpeg, png, webp or nil, by magic bytes
    def self.image_type(data : Bytes) : String?
      if data.size >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF
        "jpeg"
      elsif data.size >= 8 && data[0, 8] == Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        "png"
      elsif data.size >= 12 && String.new(data[0, 4]) == "RIFF" && String.new(data[8, 4]) == "WEBP"
        "webp"
      end
    end

    # Addresses a URL from a user must not reach: loopback, private,
    # link-local, CGNAT (Tailscale), multicast, reserved and unspecified
    def self.blocked?(address : String) : Bool
      if v4 = Socket::IPAddress.parse_v4_fields?(address)
        blocked_v4?(v4)
      elsif v6 = Socket::IPAddress.parse_v6_fields?(address.split('%').first)
        blocked_v6?(v6)
      else
        true
      end
    end

    private def self.blocked_v4?(f) : Bool
      a, b = f[0], f[1]
      a == 0 || a == 10 || a == 127 || a >= 224 ||
        (a == 100 && 64 <= b <= 127) ||
        (a == 169 && b == 254) ||
        (a == 172 && 16 <= b <= 31) ||
        (a == 192 && b == 168) ||
        (a == 192 && b == 0 && f[2] == 0) ||
        (a == 198 && 18 <= b <= 19)
    end

    private def self.blocked_v6?(fields) : Bool
      f = fields.to_a
      return true if f.all?(&.zero?) || (f[0, 7].all?(&.zero?) && f[7] == 1)
      # IPv4-mapped ::ffff:a.b.c.d
      if f[0, 5].all?(&.zero?) && f[5] == 0xFFFF
        return blocked_v4?(StaticArray[(f[6] >> 8).to_u8, (f[6] & 0xFF).to_u8, (f[7] >> 8).to_u8, (f[7] & 0xFF).to_u8])
      end
      (f[0] & 0xFE00) == 0xFC00 ||    # unique local
        (f[0] & 0xFFC0) == 0xFE80 ||  # link-local
        (f[0] & 0xFF00) == 0xFF00 ||  # multicast
        f[0] == 0x64 && f[1] == 0xFF9B || # NAT64
        f[0] == 0x2001 && f[1] == 0x0DB8  # documentation
    end

    # GET with SSRF protection: http(s) only, every resolved address checked,
    # the connection goes to the checked address (no second DNS lookup),
    # redirects checked again, size and time limited. Returns {data, type}.
    def self.fetch(url : String, redirects = REDIRECTS, deadline = Time.instant + TIMEOUT) : {Bytes, String}
      uri = URI.parse(url)
      raise FetchError.new("http or https URL expected") unless {"http", "https"}.includes?(uri.scheme)
      host = uri.host.presence || raise FetchError.new("URL without host")
      host = host.lchop('[').rchop(']')
      port = uri.port || (uri.scheme == "https" ? 443 : 80)
      addrs = Socket::Addrinfo.tcp(host, port, timeout: 5.seconds) rescue raise FetchError.new("cannot resolve #{host}")
      raise FetchError.new("cannot resolve #{host}") if addrs.empty?
      raise FetchError.new("address not allowed") if addrs.any? { |a| blocked?(a.ip_address.address) }

      tcp = TCPSocket.new(addrs.first.ip_address.address, port, connect_timeout: 5.seconds)
      tcp.read_timeout = 10.seconds
      io = uri.scheme == "https" ? OpenSSL::SSL::Socket::Client.new(tcp, OpenSSL::SSL::Context::Client.new, sync_close: true, hostname: host) : tcp
      client = HTTP::Client.new(io, host, port)
      begin
        headers = HTTP::Headers{"User-Agent" => "calibre-hub", "Accept" => "image/jpeg, image/png, image/*;q=0.5"}
        location = nil
        result = client.get(uri.request_target, headers) do |r|
          if r.status.redirection? && (loc = r.headers["Location"]?)
            location = uri.resolve(loc).to_s
            next nil
          end
          raise FetchError.new("HTTP #{r.status_code}") unless r.success?
          unless r.content_type.try(&.starts_with?("image/"))
            raise FetchError.new("not an image (#{r.content_type || "no content type"})")
          end
          read_limited(r.body_io, deadline)
        end
        if l = location
          raise FetchError.new("too many redirects") if redirects == 0
          return fetch(l, redirects - 1, deadline)
        end
        data = result.not_nil!
        {data, image_type(data) || raise FetchError.new("not an image")}
      ensure
        client.close
      end
    rescue ex : IO::Error | Socket::Error | OpenSSL::Error
      raise FetchError.new("download failed: #{ex.message}")
    end

    private def self.read_limited(io : IO, deadline) : Bytes
      buf = IO::Memory.new
      chunk = Bytes.new(65536)
      while (n = io.read(chunk)) > 0
        buf.write(chunk[0, n])
        raise FetchError.new("larger than #{MAX_BYTES} bytes") if buf.size > MAX_BYTES
        raise FetchError.new("download took too long") if Time.instant > deadline
      end
      buf.to_slice
    end

    @[JSON::Serializable::Options(emit_nulls: true)]
    struct Hit
      include JSON::Serializable

      getter url : String
      getter source : String
      getter width : Int32?
      getter height : Int32?

      def initialize(@url, @source, @width = nil, @height = nil)
      end
    end

    # Online cover search: Open Library, plus DNB by ISBN (German books).
    # Both need no API key. Sources that fail or time out are skipped.
    def self.search(book : Book, q : String? = nil) : Array(Hit)
      srcs = sources(book, q)
      channel = Channel(Array(Hit)).new
      srcs.each do |_, source|
        spawn do
          hits = begin
            source.call
          rescue ex
            STDERR.puts "cover search: #{ex.message}"
            [] of Hit
          end
          channel.send(hits)
        end
      end
      hits = srcs.map { channel.receive }.flatten
      seen = Set(String).new
      hits.select { |h| seen.add?(h.url) }
    end

    # {name, lookup}; the user's own query searches by text only
    def self.sources(book : Book, q : String? = nil) : Array({String, Proc(Array(Hit))})
      isbn = book.identifiers["isbn"]?.try(&.gsub(/[^0-9Xx]/, "")).presence
      text = q.presence || [book.title, book.authors.first?].compact.join(' ')
      list = [{"Open Library", ->{ open_library(text, q.presence ? nil : isbn) }}]
      list << {"DNB", ->{ dnb(isbn.not_nil!) }} if isbn && !q.presence
      list
    end

    def self.open_library(text : String, isbn : String?) : Array(Hit)
      params = isbn ? {"isbn" => isbn} : {"q" => text}
      body = get_json("https://openlibrary.org/search.json?" + URI::Params.encode(params.merge({"fields" => "cover_i", "limit" => "10"})))
      (body["docs"]?.try(&.as_a) || [] of JSON::Any).compact_map do |doc|
        id = doc["cover_i"]?.try(&.as_i64?) || next
        Hit.new("https://covers.openlibrary.org/b/id/#{id}-L.jpg", "Open Library")
      end
    end

    # DNB only has covers by ISBN; it answers with an HTML page when it has none
    def self.dnb(isbn : String) : Array(Hit)
      url = "https://portal.dnb.de/opac/mvb/cover?isbn=#{isbn}"
      ok = client_for(url).get(URI.parse(url).request_target) do |r|
        r.success? && r.content_type.try(&.starts_with?("image/"))
      end
      ok ? [Hit.new(url, "DNB")] : [] of Hit
    end

    private def self.get_json(url : String) : JSON::Any
      r = client_for(url).get(URI.parse(url).request_target, headers: HTTP::Headers{"Accept" => "application/json"})
      raise FetchError.new("#{URI.parse(url).host}: HTTP #{r.status_code}") unless r.success?
      JSON.parse(r.body)
    end

    private def self.client_for(url : String) : HTTP::Client
      HTTP::Client.new(URI.parse(url)).tap do |c|
        c.connect_timeout = 5.seconds
        c.read_timeout = 8.seconds
      end
    end
  end
end
