require "json"
require "securerandom"
require "set"
require "thread"

module Relay
  # Persistent token <-> subdomain mapping with TTL. Tokens belonging to a
  # currently-connected client never expire (they're refreshed implicitly).
  # Tokens of disconnected clients age out after TOKEN_TTL.
  class TokenStore
    DEFAULT_PATH = "/tmp/rails-tunnel-relay-server-tokens.json".freeze
    TOKEN_TTL = 24 * 3600 # seconds
    CLEANUP_INTERVAL = 600
    SUBDOMAIN_PREFIX = "dev-".freeze

    # active_subdomains: callable returning a Set/Array of subdomains held
    # by currently-connected clients. Used to keep their tokens alive and to
    # avoid colliding when generating new subdomains.
    def initialize(path: DEFAULT_PATH, active_subdomains:, logger: nil)
      @path = path
      @active_subdomains = active_subdomains
      @logger = logger
      @mutex = Mutex.new
      @tokens = load_from_disk
    end

    def issue(subdomain)
      @mutex.synchronize do
        loop do
          token = SecureRandom.hex(16)
          next if @tokens.key?(token)

          @tokens[token] = entry(subdomain)
          persist
          return token
        end
      end
    end

    def revoke(token)
      return unless token

      @mutex.synchronize do
        next unless @tokens.delete(token)

        persist
      end
    end

    # Returns the subdomain bound to `token` if the token is valid, or nil.
    # A token is valid if either (a) its subdomain currently has an active
    # client, or (b) the token has not expired yet.
    def resolve(token)
      @mutex.synchronize do
        record = @tokens[token]
        return nil unless record

        sub = subdomain_of(record)
        return sub if active?(sub)
        return nil if expired?(record)

        sub
      end
    end

    def generate_subdomain
      @mutex.synchronize do
        loop do
          candidate = "#{SUBDOMAIN_PREFIX}#{SecureRandom.hex(4)}"
          return candidate unless taken_unlocked?(candidate)
        end
      end
    end

    # Drops tokens whose subdomain has no active client and whose TTL has
    # elapsed. Called both periodically and on every registration.
    def cleanup_expired
      @mutex.synchronize { cleanup_unlocked }
    end

    def cleanup_loop(interval: CLEANUP_INTERVAL, stop_flag: nil)
      loop do
        interval.times do
          return if stop_flag && stop_flag.call

          sleep 1
        end
        return if stop_flag && stop_flag.call

        cleanup_expired
      end
    end

    def persist_now
      @mutex.synchronize { persist }
    end

    # Snapshot for tests/diagnostics.
    def to_h
      @mutex.synchronize { @tokens.dup }
    end

    private

    def cleanup_unlocked
      now = Time.now.to_i
      expired_tokens = @tokens.reject do |_token, record|
        active?(subdomain_of(record)) || !expired?(record, now)
      end
      return if expired_tokens.empty?

      expired_tokens.each_key { |t| @tokens.delete(t) }
      persist
    end

    def taken_unlocked?(subdomain)
      return true if active?(subdomain)

      @tokens.any? { |_token, record| subdomain_of(record) == subdomain }
    end

    def active?(subdomain)
      active_set.include?(subdomain)
    end

    def active_set
      result = @active_subdomains.call
      result.is_a?(Set) ? result : result.to_set
    end

    def entry(subdomain, expires_at: Time.now.to_i + TOKEN_TTL)
      { "subdomain" => subdomain, "expires_at" => expires_at }
    end

    def subdomain_of(record)
      record.is_a?(Hash) ? record["subdomain"] : record
    end

    def expired?(record, now = Time.now.to_i)
      expires_at = record.is_a?(Hash) ? record["expires_at"] : nil
      expires_at.nil? || expires_at <= now
    end

    def normalize(record, now)
      if record.is_a?(Hash)
        entry(record["subdomain"], expires_at: record["expires_at"] || (now + TOKEN_TTL))
      else
        entry(record, expires_at: now + TOKEN_TTL)
      end
    end

    def load_from_disk
      return {} unless File.exist?(@path)

      now = Time.now.to_i
      result = {}
      JSON.parse(File.read(@path)).each do |token, record|
        normalized = normalize(record, now)
        next if expired?(normalized, now)

        result[token] = normalized
      end
      result
    rescue JSON::ParserError, SystemCallError => e
      log_warn("Failed to load tokens: #{e.message}")
      {}
    end

    def persist
      File.write(@path, JSON.pretty_generate(@tokens))
    rescue SystemCallError => e
      log_warn("Failed to save tokens: #{e.message}")
    end

    def log_warn(msg)
      @logger ? @logger.warn("⚠️  #{msg}") : warn(msg)
    end
  end
end
