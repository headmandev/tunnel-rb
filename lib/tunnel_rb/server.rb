# frozen_string_literal: true

require_relative "server/logger"
require_relative "server/client_registry"
require_relative "server/token_store"
require_relative "server/pending_connections"
require_relative "server/control_server"
require_relative "server/public_server"
require_relative "server/tls"

module TunnelRb
  # Top-level coordinator. Wires the components together, owns the
  # background threads, and handles graceful shutdown on SIGINT/SIGTERM.
  class Server
    def initialize(
      control_port:,
      public_port:,
      domain:,
      url_port: nil,
      tokens_path: TokenStore::DEFAULT_PATH,
      tls_cert: nil,
      tls_key: nil,
      logger: Logger.new
    )
      @logger = logger
      @registry = ClientRegistry.new
      @token_store = TokenStore.new(
        path: tokens_path,
        active_subdomains: -> { @registry.active_subdomains },
        logger: @logger
      )
      @pending_connections = PendingConnections.new

      tls_context = TLS.server_context(cert_path: tls_cert, key_path: tls_key)

      @control = ControlServer.new(
        port: control_port,
        domain: domain,
        url_port: url_port,
        registry: @registry,
        token_store: @token_store,
        pending_connections: @pending_connections,
        tls_context: tls_context,
        logger: @logger
      )
      @public = PublicServer.new(
        port: public_port,
        registry: @registry,
        pending_connections: @pending_connections,
        logger: @logger
      )

      @stop_flag = false
      @threads = []
      @stop_mutex = Mutex.new
    end

    def start(install_signals: true)
      @logger.info "🚀 Starting tunnel server..."
      @logger.info(@control.tls? ? "🔒 Control plane TLS: enabled" : "🔓 Control plane TLS: disabled")
      install_signal_handlers if install_signals

      @threads << Thread.new { @control.start }
      @threads << Thread.new { @public.start }
      @threads << Thread.new { @control.read_loop }
      @threads << Thread.new { @control.ping_loop }
      @threads << Thread.new {
        @token_store.cleanup_loop(stop_flag: -> { @stop_flag })
      }

      @threads.each(&:join)
    end

    def stop
      @stop_mutex.synchronize do
        return if @stop_flag

        @stop_flag = true
      end

      @logger.info "👋 Shutting down..."
      @control.stop
      @public.stop
      @token_store.persist_now
      @threads.each { |t| t.join(2) }
    end

    private

    def install_signal_handlers
      [:INT, :TERM].each do |sig|
        Signal.trap(sig) { Thread.new { stop } }
      end
    end
  end
end
