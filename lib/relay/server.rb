require_relative "logger"
require_relative "client_registry"
require_relative "token_store"
require_relative "pending_connections"
require_relative "control_server"
require_relative "public_server"

module Relay
  # Top-level coordinator. Wires the components together, owns the
  # background threads, and handles graceful shutdown on SIGINT/SIGTERM.
  class Server
    def initialize(
      control_port: 7777,
      public_port: 8080,
      domain_suffix: ".tunnel.test",
      tokens_path: TokenStore::DEFAULT_PATH,
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

      @control = ControlServer.new(
        port: control_port,
        domain_suffix: domain_suffix,
        registry: @registry,
        token_store: @token_store,
        pending_connections: @pending_connections,
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
      @logger.info "🚀 Starting relay server..."
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
