require "minitest/autorun"
require "tempfile"
require "json"
require "set"

require "tunnel_rb/server/token_store"

class TokenStoreTest < Minitest::Test
  def setup
    @tmp = Tempfile.new("tokens")
    @tmp.close
    File.delete(@tmp.path) if File.exist?(@tmp.path)
    @active = Set.new
    @store = build_store
  end

  def teardown
    File.delete(@tmp.path) if File.exist?(@tmp.path)
  end

  def build_store
    TunnelRb::Server::TokenStore.new(
      path: @tmp.path,
      active_subdomains: -> { @active }
    )
  end

  def test_issue_returns_hex_token_and_persists
    token = @store.issue("dev-aaaa")
    assert_match(/\A[0-9a-f]{32}\z/, token)
    raw = JSON.parse(File.read(@tmp.path))
    assert_equal "dev-aaaa", raw[token]["subdomain"]
  end

  def test_resolve_returns_subdomain_for_active_token
    token = @store.issue("dev-bbbb")
    assert_equal "dev-bbbb", @store.resolve(token)
  end

  def test_resolve_returns_nil_for_expired_token_with_no_active_client
    token = @store.issue("dev-cccc")
    expire_token!(token)
    assert_nil @store.resolve(token)
  end

  def test_resolve_keeps_expired_token_alive_while_client_is_active
    token = @store.issue("dev-dddd")
    expire_token!(token)
    @active << "dev-dddd"
    assert_equal "dev-dddd", @store.resolve(token)
  end

  def test_cleanup_expired_removes_only_inactive_expired_tokens
    keep_active_token = @store.issue("dev-keep-active")
    keep_fresh_token = @store.issue("dev-keep-fresh")
    drop_token = @store.issue("dev-drop")

    @active << "dev-keep-active"
    expire_token!(keep_active_token)
    expire_token!(drop_token)

    @store.cleanup_expired

    snap = @store.to_h
    assert_includes snap, keep_active_token, "active client's expired token should remain"
    assert_includes snap, keep_fresh_token,  "non-expired token should remain"
    refute_includes snap, drop_token,        "expired token without active client should be dropped"
  end

  def test_generate_subdomain_avoids_active_clients
    @active << "dev-aaaaaaaa"
    seen = 100.times.map { @store.generate_subdomain }
    refute_includes seen, "dev-aaaaaaaa"
  end

  def test_generate_subdomain_avoids_existing_token_subdomains
    @store.issue("dev-eeeeeeee")
    seen = 100.times.map { @store.generate_subdomain }
    refute_includes seen, "dev-eeeeeeee"
  end

  def test_persist_round_trip
    token = @store.issue("dev-roundtrip")
    reloaded = build_store
    assert_equal "dev-roundtrip", reloaded.resolve(token)
  end

  def test_load_skips_expired_tokens_for_inactive_subdomains
    File.write(@tmp.path, JSON.pretty_generate(
      "fresh-token" => { "subdomain" => "dev-alive", "expires_at" => Time.now.to_i + 1000 },
      "stale-token" => { "subdomain" => "dev-dead",  "expires_at" => Time.now.to_i - 1000 }
    ))

    fresh_store = build_store
    snap = fresh_store.to_h
    assert_includes snap, "fresh-token"
    refute_includes snap, "stale-token"
  end

  def test_load_handles_legacy_string_entries
    File.write(@tmp.path, JSON.pretty_generate("legacy" => "dev-legacy"))
    fresh_store = build_store
    @active << "dev-legacy"
    assert_equal "dev-legacy", fresh_store.resolve("legacy")
  end

  def test_revoke_removes_token_and_persists
    token = @store.issue("dev-rev")
    @store.revoke(token)
    assert_nil @store.resolve(token)
    raw = JSON.parse(File.read(@tmp.path))
    refute_includes raw, token
  end

  private

  # Reaches into the store's internal map to age a token without waiting.
  def expire_token!(token)
    map = @store.instance_variable_get(:@tokens)
    map[token]["expires_at"] = Time.now.to_i - 60
  end
end
