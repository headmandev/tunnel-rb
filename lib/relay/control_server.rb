require "json"
require "socket"

require_relative "thread_pool"
require_relative "socket_helpers"
require_relative "tls"

module Relay
  # Owns the control plane: port 7777 listener, handshake handler, the
  # IO.select-based read loop that consumes pong/disconnect events, and
  # the ping loop that evicts unresponsive clients.
  class ControlServer
    PING_INTERVAL = 30 # seconds; keeps NAT mappings alive
    PONG_MISSES = 3
    HANDSHAKE_POOL_SIZE = 64
    HANDSHAKE_QUEUE_SIZE = 64
    READ_CHUNK = 4096
    LINE_MAX = 16 * 1024 # drop clients that send oversized lines without \n
    SELECT_TIMEOUT = 1.0
    IDLE_SLEEP = 0.5 # when no clients are connected

    def initialize(port:, domain:, registry:, token_store:, pending_connections:, logger:, url_port: nil, tls_context: nil)
      @port = port
      @domain = domain
      @url_port = url_port
      @registry = registry
      @token_store = token_store
      @pending_connections = pending_connections
      @tls_context = tls_context
      @logger = logger

      @pool = ThreadPool.new(HANDSHAKE_POOL_SIZE, max_queue: HANDSHAKE_QUEUE_SIZE)
      @stopping = false
      @server = nil
    end

    def tls?
      !@tls_context.nil?
    end

    # Blocking accept loop. Returns when stop is called.
    def start
      tcp_server = TCPServer.new("0.0.0.0", @port)
      @server = tls? ? TLS.wrap_listener(tcp_server, @tls_context) : tcp_server
      @logger.info "🎧 Control server listening for clients on #{@port}"

      loop do
        socket = @server.accept
        @pool.submit { handle_connection(socket) }
      rescue IOError, Errno::EBADF
        break if @stopping

        raise
      end
    end

    # IO.select over all registered control sockets. One thread serves all
    # clients, so the count of long-lived ping/pong loops doesn't grow with
    # the number of registered tunnels.
    def read_loop
      until @stopping
        sockets = @registry.sockets
        if sockets.empty?
          sleep IDLE_SLEEP
          next
        end

        begin
          readable, = IO.select(sockets, nil, nil, SELECT_TIMEOUT)
        rescue IOError, Errno::EBADF
          # A socket was closed (e.g. shutdown) while we were waiting on it.
          # Drop it from our snapshot and re-loop to rebuild the set.
          next
        end
        next unless readable

        readable.each { |socket| handle_readable(socket) }
      end
    end

    def ping_loop
      while interruptible_sleep(PING_INTERVAL)
        tick_pings
      end
    end

    def stop
      @stopping = true
      @server&.close rescue nil
      @pool.shutdown
      @registry.sockets.each { |s| s.close rescue nil }
    end

    private

    # Sleeps in 1-second slices so stop() is observed quickly. Returns
    # false when @stopping flips during the sleep.
    def interruptible_sleep(total)
      total.times do
        return false if @stopping

        sleep 1
      end
      !@stopping
    end

    def handle_connection(socket)
      # SSLServer defers the handshake (start_immediately = false), so we run
      # it here in the worker thread rather than blocking the accept loop.
      socket.accept if tls?

      SocketHelpers.enable_tcp_nodelay(socket)

      line = socket.gets
      return socket.close rescue nil unless line

      request = JSON.parse(line)

      case request["action"]
      when "register"
        handle_registration(socket, request)
      when "bind"
        @pending_connections.deliver(request["conn_id"], socket)
      else
        socket.close rescue nil
      end
    rescue => e
      @logger.warn "❌ Tunnel connection error: #{e.message}"
      socket.close rescue nil
    end

    def handle_registration(control_socket, request)
      @token_store.cleanup_expired

      reused = false
      subdomain =
        if request["token"] && (existing = @token_store.resolve(request["token"]))
          @token_store.revoke(request["token"])
          reused = true
          existing
        else
          @token_store.generate_subdomain
        end

      token = @token_store.issue(subdomain)
      client, old_socket = @registry.register(subdomain, control_socket, token)
      old_socket.close rescue nil if old_socket

      authority = @url_port ? "#{subdomain}.#{@domain}:#{@url_port}" : "#{subdomain}.#{@domain}"
      url = "https://#{authority}"
      SocketHelpers.enable_tcp_keepalive(control_socket)
      client.send_message(status: "ok", url: url, token: token)

      @logger.info(reused ? "✅ Tunnel reconnected: #{url}" : "✅ Tunnel registered: #{url}")
    end

    def handle_readable(socket)
      client = @registry.lookup_by_socket(socket)
      # Socket already removed (e.g. ping_loop closed it); drop it.
      return disconnect(socket, log: false) unless client

      buffer = client.read_buffer

      # Drain in a loop: a TLS socket can hold decrypted bytes that IO.select
      # never surfaces (readiness is at the TCP layer, but a full TLS record
      # may already be buffered). read_nonblock works for plain and TLS
      # sockets alike, unlike recv_nonblock which SSLSocket does not support.
      loop do
        chunk = socket.read_nonblock(READ_CHUNK, exception: false)
        case chunk
        when :wait_readable, :wait_writable
          break # nothing more to read right now
        when nil
          return disconnect(socket)
        when ""
          break
        end

        buffer << chunk
      end

      while (idx = buffer.index("\n"))
        line = buffer.slice!(0, idx + 1)
        process_line(client, line)
      end

      # No newline yet but buffer keeps growing => slowloris. Drop the client.
      if buffer.bytesize > LINE_MAX
        @logger.warn "control buffer overflow on #{client.subdomain}, disconnecting"
        disconnect(socket)
      end
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
      disconnect(socket)
    end

    def process_line(client, line)
      message = JSON.parse(line) rescue return
      return unless message["action"] == "pong"

      client.pong_received = true
      client.missed_pongs = 0
    end

    def disconnect(socket, log: true)
      subdomain = @registry.forget(socket)
      socket.close rescue nil
      @logger.info "🔴 Tunnel #{subdomain} disconnected" if log && subdomain
    end

    def tick_pings
      to_close = []
      to_ping = []

      @registry.each_client do |client|
        unless client.pong_received
          client.missed_pongs += 1
          if client.missed_pongs >= PONG_MISSES
            to_close << client.socket
            next
          end
        end

        client.pong_received = false
        to_ping << client
      end

      to_close.each do |socket|
        sub = @registry.forget(socket)
        @logger.warn "⚠️  Tunnel #{sub} unresponsive (#{PONG_MISSES} missed pongs), closing control channel" if sub
        socket.close rescue nil
      end

      to_ping.each do |client|
        client.send_message(action: "ping")
      rescue IOError, SystemCallError
        nil
      end
    end
  end
end
