require "spec"
require "../src/calibre_hub/covers"

describe CalibreHub::Covers do
  it "recognizes image types by magic bytes" do
    CalibreHub::Covers.image_type(Bytes[0xFF, 0xD8, 0xFF, 0xE0]).should eq("jpeg")
    CalibreHub::Covers.image_type(Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).should eq("png")
    CalibreHub::Covers.image_type("RIFF\0\0\0\0WEBPVP8 ".to_slice).should eq("webp")
    CalibreHub::Covers.image_type("<html>".to_slice).should be_nil
  end

  it "blocks local and private addresses" do
    %w(127.0.0.1 10.1.2.3 172.20.0.1 192.168.1.1 100.101.102.103 169.254.169.254 0.0.0.0 224.0.0.1
      ::1 :: fd7a:115c:a1e0::1 fe80::1%eth0 ::ffff:127.0.0.1 ::ffff:192.168.0.1 64:ff9b::a00:1 bogus).each do |a|
      CalibreHub::Covers.blocked?(a).should be_true, a
    end
    %w(8.8.8.8 142.250.185.74 2a00:1450:4001:82a::200e ::ffff:8.8.8.8 100.128.0.1 172.32.0.1).each do |a|
      CalibreHub::Covers.blocked?(a).should be_false, a
    end
  end

  it "refuses non-http URLs and private targets without connecting" do
    expect_raises(CalibreHub::Covers::FetchError, "http") { CalibreHub::Covers.fetch("file:///etc/passwd") }
    expect_raises(CalibreHub::Covers::FetchError, "not allowed") { CalibreHub::Covers.fetch("http://127.0.0.1:8083/get/cover/1") }
    expect_raises(CalibreHub::Covers::FetchError, "not allowed") { CalibreHub::Covers.fetch("http://localhost/") }
    expect_raises(CalibreHub::Covers::FetchError, "not allowed") { CalibreHub::Covers.fetch("http://[::1]/") }
  end
end
