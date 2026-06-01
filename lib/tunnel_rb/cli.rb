# frozen_string_literal: true

require "optparse"

require_relative "client"

module TunnelRb
  module CLI
    module_function

    def run(argv = ARGV)
      Client.new(**parse_options(argv)).start
    end

    def env_bool(name, default)
      value = ENV[name]
      return default if value.nil? || value.empty?

      ["1", "true", "yes"].include?(value.downcase)
    end

    def parse_options(argv)
      options = {
        server_host: ENV.fetch("SERVER_HOST", "server.tunnel-rb.dev"),
        server_port: Integer(ENV.fetch("SERVER_PORT", "7777")),
        local_host: ENV.fetch("LOCAL_HOST", "localhost"),
        local_port: ENV["LOCAL_PORT"] ? Integer(ENV["LOCAL_PORT"]) : nil,
        tls: env_bool("RELAY_TLS", true),
        tls_ca: ENV["RELAY_TLS_CA"],
        tls_verify: env_bool("RELAY_TLS_VERIFY", true)
      }

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: tunnel [LOCAL_PORT] [options]"
        opts.on("--server-host HOST", "Server host (default: #{options[:server_host]})") { |v| options[:server_host] = v }
        opts.on("--server-port PORT", Integer, "Server port (default: #{options[:server_port]})") { |v| options[:server_port] = v }
        opts.on("--local-host HOST", "Local host (default: #{options[:local_host]})") { |v| options[:local_host] = v }
        opts.on("--[no-]tls", "Connect to the server over TLS (default: on; use --no-tls for local/testing)") { |v| options[:tls] = v }
        opts.on("--[no-]tls-verify", "Verify the server cert against the system CA store (default: on)") { |v| options[:tls_verify] = v }
        opts.on("--tls-ca PATH", "CA cert/bundle to verify the server instead of the system CA store") { |v| options[:tls_ca] = v }
        opts.on("-h", "--help", "Show this help") do
          puts opts
          exit
        end
      end
      parser.parse!(argv)

      options[:local_port] = Integer(argv[0]) if argv[0]

      if options[:local_port].nil?
        warn "Error: local port is required (positional argument or LOCAL_PORT env var)"
        warn parser.help
        exit 1
      end

      options
    end
  end
end
