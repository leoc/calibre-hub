require "spec"
require "compress/zip"
require "kemal"
require "../src/calibre_hub/api"
require "../src/calibre_hub/epub_fix"
require "../src/calibre_hub/meta_sources"

# EPUBs that unpack to far more than they are (review #8411 M4)

BOMB_CONTAINER = %(<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>)
BOMB_OPF       = %(<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Bombe</dc:title><dc:language>de</dc:language></metadata><manifest><item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c1"/></spine></package>)

# An EPUB whose chapter is `size` bytes of spaces after a short start; with
# `declared`, the ZIP's directory lies about the chapter's size
private def bomb(size : Int64, declared : UInt32? = nil) : String
  path = File.tempname("bomb", ".epub")
  File.open(path, "w") do |io|
    Compress::Zip::Writer.open(io) do |zip|
      zip.add("mimetype", "application/epub+zip")
      zip.add("META-INF/container.xml", BOMB_CONTAINER)
      zip.add("content.opf", BOMB_OPF)
      zip.add("c1.xhtml") do |w|
        w << %(<html xmlns="http://www.w3.org/1999/xhtml"><body><p>ISBN 978-3-16-148410-0</p>)
        chunk = " " * 65536
        (size // chunk.bytesize).times { w << chunk }
      end
    end
  end
  declared.try { |d| lie(path, "c1.xhtml", d) }
  path
end

# overwrites the uncompressed size of an entry in the central directory
private def lie(path : String, name : String, size : UInt32)
  data = File.read(path).to_slice.dup
  sig = Bytes[0x50, 0x4b, 0x01, 0x02]
  i = 0
  while i < data.size - 46
    if data[i, 4] == sig
      name_len = IO::ByteFormat::LittleEndian.decode(UInt16, data[i + 28, 2])
      if String.new(data[i + 46, name_len]) == name
        IO::ByteFormat::LittleEndian.encode(size, data[i + 24, 4])
      end
    end
    i += 1
  end
  File.write(path, data)
end

describe CalibreHub::ZipLimits do
  it "fails an EPUB to fix whose directory declares too much, before unpacking" do
    path = bomb(1_i64 * 1024 * 1024)
    begin
      expect_raises(CalibreHub::EpubFix::Error, /too large/) { CalibreHub::EpubFix.read(path, max_total: 512_i64 * 1024) }
      expect_raises(CalibreHub::EpubFix::Error, /too large/) { CalibreHub::EpubFix.read(path, max_entries: 3) }
      CalibreHub::EpubFix.read(path).map(&.name).should contain("c1.xhtml")
    ensure
      File.delete?(path)
    end
  end

  it "stops unpacking at the limit when the directory lies" do
    path = bomb(2_i64 * 1024 * 1024, declared: 100_u32)
    begin
      expect_raises(CalibreHub::EpubFix::Error, /too large/) { CalibreHub::EpubFix.read(path, max_total: 1_i64 * 1024 * 1024) }
    ensure
      File.delete?(path)
    end
  end

  it "reads metadata of a bomb from the start of its pages only" do
    path = bomb(CalibreHub::Meta::FileMeta::MAX_ENTRY * 3, declared: 100_u32)
    begin
      info = CalibreHub::Meta::FileMeta.epub(path).not_nil!
      info.record.title.should eq("Bombe")
      info.isbns.should eq(["9783161484100"])
    ensure
      File.delete?(path)
    end
  end

  it "the defaults fail a ZIP that declares more than 512 MiB" do
    path = bomb(1024_i64)
    begin
      lie(path, "c1.xhtml", 600_u32 * 1024 * 1024)
      expect_raises(CalibreHub::EpubFix::Error, /too large/) { CalibreHub::EpubFix.read(path) }
    ensure
      File.delete?(path)
    end
  end
end
