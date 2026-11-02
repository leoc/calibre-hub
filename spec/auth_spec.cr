require "spec"
require "../src/calibre_hub/auth"

private def auth(**opts)
  CalibreHub::Auth.new("arthur", "geheim", ("k" * 32).to_slice, **opts)
end

describe CalibreHub::Auth do
  it "accepts its own cookie and rejects tampered ones" do
    a = auth
    value = a.cookie.value
    a.session_user(value).should eq("arthur")
    a.session_user(value.sub(/.$/, value[-1] == 'A' ? "B" : "A")).should be_nil
    a.session_user("x.y").should be_nil
    a.session_user(nil).should be_nil
  end

  it "rejects cookies signed with another key" do
    other = CalibreHub::Auth.new("arthur", "geheim", ("z" * 32).to_slice)
    auth.session_user(other.cookie.value).should be_nil
  end

  it "expires sessions" do
    a = auth(lifetime: 1.day)
    value = a.cookie(Time.utc - 2.days).value
    a.session_user(value).should be_nil
  end

  it "blocks an IP after repeated failures" do
    a = auth(limiter: CalibreHub::RateLimiter.new(max_failures: 2))
    a.login("1.2.3.4", "arthur", "x").should be_nil
    a.login("1.2.3.4", "arthur", "x").should be_nil
    expect_raises(CalibreHub::RateLimiter::Limited) { a.login("1.2.3.4", "arthur", "geheim") }
    a.login("5.6.7.8", "arthur", "geheim").should_not be_nil
  end

  it "checks Basic credentials" do
    a = auth
    a.basic_user("ip", "Basic #{Base64.strict_encode("arthur:geheim")}").should eq("arthur")
    a.basic_user("ip", "Basic #{Base64.strict_encode("arthur:nope")}").should be_nil
    a.basic_user("ip", nil).should be_nil
  end
end

private TOKEN = "t0ken-0123456789abcdef"

describe "API tokens" do
  it "accepts configured tokens only" do
    a = auth(tokens: [TOKEN, "other-token-0123456789"])
    a.bearer_user("ip", "Bearer #{TOKEN}").should eq("arthur")
    a.bearer_user("ip", "Bearer other-token-0123456789").should eq("arthur")
    a.bearer_user("ip", "Bearer #{TOKEN}x").should be_nil
    a.bearer_user("ip", "Bearer ").should be_nil
    a.bearer_user("ip", nil).should be_nil
    a.bearer_user("ip", "Basic #{TOKEN}").should be_nil
    auth.bearer_user("ip", "Bearer #{TOKEN}").should be_nil
  end

  it "rejects short tokens" do
    expect_raises(ArgumentError, "shorter") { auth(tokens: ["short"]) }
  end

  it "rate limits wrong tokens" do
    a = auth(tokens: [TOKEN], limiter: CalibreHub::RateLimiter.new(max_failures: 2))
    a.bearer_user("ip", "Bearer wrong-wrong-wrong-1").should be_nil
    a.bearer_user("ip", "Bearer wrong-wrong-wrong-2").should be_nil
    expect_raises(CalibreHub::RateLimiter::Limited) { a.bearer_user("ip", "Bearer #{TOKEN}") }
  end
end

private def users(**opts)
  CalibreHub::Auth.new([
    CalibreHub::Auth.account("arthur", "geheim", tokens: [TOKEN]),
    CalibreHub::Auth.account("lea", "lesen", CalibreHub::Auth::Role::Reader, ["lea-token-0123456789abc"]),
  ], ("k" * 32).to_slice, **opts)
end

describe "several users" do
  it "logs each user in with their own password" do
    a = users
    a.check_password("arthur", "geheim").should be_true
    a.check_password("lea", "lesen").should be_true
    a.check_password("lea", "geheim").should be_false
    a.check_password("nobody", "geheim").should be_false
    a.session_user(a.login("ip", "lea", "lesen").not_nil!.value).should eq("lea")
    a.basic_user("ip", "Basic #{Base64.strict_encode("lea:lesen")}").should eq("lea")
  end

  it "maps tokens to their user" do
    a = users
    a.bearer_user("ip", "Bearer #{TOKEN}").should eq("arthur")
    a.bearer_user("ip", "Bearer lea-token-0123456789abc").should eq("lea")
  end

  it "knows the roles" do
    a = users
    a.role("arthur").should eq(CalibreHub::Auth::Role::Admin)
    a.admin?("lea").should be_false
    a.role("nobody").should be_nil
    a.role("lea").to_s.should eq("reader")
  end

  it "drops the session of a user no longer configured" do
    old = users
    now = CalibreHub::Auth.new("arthur", "geheim", ("k" * 32).to_slice)
    now.session_user(old.cookie(user: "lea").value).should be_nil
    now.session_user(old.cookie(user: "arthur").value).should eq("arthur")
  end

  it "runs a block as a user and asks for one otherwise" do
    a = users
    expect_raises(CalibreHub::Auth::NoUser) { a.user }
    a.as_user("lea") { a.user.should eq("lea") }
    expect_raises(CalibreHub::Auth::NoUser) { a.user }
    auth.user.should eq("arthur")
  end

  it "rejects users or tokens configured twice" do
    expect_raises(ArgumentError, "twice") do
      CalibreHub::Auth.new([CalibreHub::Auth.account("a", "x"), CalibreHub::Auth.account("a", "y")], ("k" * 32).to_slice)
    end
    expect_raises(ArgumentError, "twice") do
      CalibreHub::Auth.new([CalibreHub::Auth.account("a", "x", tokens: [TOKEN]), CalibreHub::Auth.account("b", "y", tokens: [TOKEN])], ("k" * 32).to_slice)
    end
  end
end
