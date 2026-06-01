# frozen_string_literal: true

require "socket"
require "json"
require "openssl"

module TunnelRb
  class Client
    TCP_KEEPALIVE_IDLE = 60
    TCP_KEEPALIVE_INTERVAL = 30
    TCP_KEEPALIVE_PROBES = 3

    CONNECT_TIMEOUT = 5
    RECONNECT_INITIAL_DELAY = 1
    RECONNECT_MAX_DELAY = 30

    LOCAL_UNREACHABLE_ERRORS = [
      Errno::ECONNREFUSED,
      Errno::EHOSTUNREACH,
      Errno::ENETUNREACH,
      Errno::ETIMEDOUT,
      SocketError
    ].freeze

    def initialize(server_host:, server_port:, local_host: "localhost", local_port:, tls: false, tls_ca: nil, tls_verify: false)
      @server_host = server_host
      @server_port = server_port
      @local_host = local_host
      @local_port = local_port
      @tls = tls
      @tls_ca = tls_ca
      @tls_verify = tls_verify
      @token = nil
      @session_mutex = Mutex.new
      @tls_session = nil
      @ssl_context = build_ssl_context if @tls
    end

    def start
      attempt = 0
      loop do
        connect_and_run { attempt = 0 }
      rescue Interrupt
        puts "\n[Tunnel] Shutting down..."
        break
      rescue => e
        delay = [RECONNECT_INITIAL_DELAY * (2**attempt), RECONNECT_MAX_DELAY].min
        attempt += 1
        puts "[Tunnel] Disconnected: #{e.message}. Reconnecting in #{delay}s..."
        sleep delay
      end
    ensure
      @control_socket&.close
    end

    private

    def connect_and_run
      @control_socket = open_tcp(@server_host, @server_port)
      enable_tcp_keepalive(@control_socket)

      payload = { action: "register" }
      payload[:token] = @token if @token
      @control_socket.puts(payload.to_json)

      response = read_json(@control_socket, "registration response")
      raise "Registration failed: #{response['error']}" if response["status"] != "ok"

      @token = response["token"]
      transport = @tls ? "TLS" : "TCP"
      puts "\n🚀 [Tunnel] Ready! #{response['url']} -> #{@local_host}:#{@local_port} (server: #{transport})\n\n"

      yield if block_given?

      loop do
        command = read_json(@control_socket, "command")

        case command["action"]
        when "ping"
          @control_socket.puts({ action: "pong" }.to_json)
        when "new_connection"
          Thread.new { handle_data_connection(command["conn_id"]) }
        end
      end
    end

    def handle_data_connection(conn_id)
      server_sock =
        begin
          open_tcp(@server_host, @server_port)
        rescue => e
          warn "[Tunnel] Failed to open data connection to server: #{e.message}"
          return
        end

      server_sock.puts({ action: "bind", conn_id: conn_id }.to_json)

      begin
        local_sock = open_tcp(@local_host, @local_port, tls: false)
      rescue *LOCAL_UNREACHABLE_ERRORS => e
        respond_bad_gateway(server_sock, e)
        return
      end

      t1 = Thread.new { proxy_stream(server_sock, local_sock) }
      t2 = Thread.new { proxy_stream(local_sock, server_sock) }
      t1.join
      t2.join
    ensure
      server_sock&.close
      local_sock&.close
    end

    def open_tcp(host, port, tls: @tls)
      tcp = Socket.tcp(host, port, connect_timeout: CONNECT_TIMEOUT)
      tcp.setsockopt(:TCP, :TCP_NODELAY, true) rescue nil
      return tcp unless tls

      ssl = OpenSSL::SSL::SSLSocket.new(tcp, @ssl_context)
      ssl.hostname = host
      cached_session = @session_mutex.synchronize { @tls_session }
      ssl.session = cached_session if cached_session
      ssl.sync_close = true
      ssl.connect
      ssl.post_connection_check(host) if @ssl_context.verify_mode == OpenSSL::SSL::VERIFY_PEER
      ssl
    end

    def build_ssl_context
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.min_version = OpenSSL::SSL::TLS1_3_VERSION

      ctx.session_cache_mode = OpenSSL::SSL::SSLContext::SESSION_CACHE_CLIENT
      ctx.session_new_cb = proc do |_ssl, session|
        @session_mutex.synchronize { @tls_session = session }
      end

      if @tls_ca
        ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
        ctx.ca_file = @tls_ca
      elsif @tls_verify
        ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
        store = OpenSSL::X509::Store.new
        store.set_default_paths
        ctx.cert_store = store
      else
        ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end
      ctx
    end

    def read_json(socket, what)
      line = socket.gets
      raise "Server closed connection while waiting for #{what}" if line.nil?

      JSON.parse(line)
    rescue JSON::ParserError => e
      raise "Invalid #{what} from server: #{e.message}"
    end

    def respond_bad_gateway(server_sock, error)
      body = "Local service #{@local_host}:#{@local_port} is not reachable: #{error.message}\n"
      server_sock.write(
        "HTTP/1.1 502 Bad Gateway\r\n" \
        "Connection: close\r\n" \
        "Content-Type: text/plain; charset=utf-8\r\n" \
        "Content-Length: #{body.bytesize}\r\n" \
        "\r\n" \
        "#{body}"
      )
    rescue IOError, SystemCallError
    end

    def enable_tcp_keepalive(socket)
      io = socket.respond_to?(:to_io) ? socket.to_io : socket
      io.setsockopt(:SOCKET, :SO_KEEPALIVE, true)
      if defined?(Socket::TCP_KEEPIDLE)
        io.setsockopt(:TCP, :TCP_KEEPIDLE, TCP_KEEPALIVE_IDLE)
        io.setsockopt(:TCP, :TCP_KEEPINTVL, TCP_KEEPALIVE_INTERVAL)
        io.setsockopt(:TCP, :TCP_KEEPCNT, TCP_KEEPALIVE_PROBES)
      elsif defined?(Socket::TCP_KEEPALIVE)
        io.setsockopt(:TCP, :TCP_KEEPALIVE, TCP_KEEPALIVE_IDLE)
      end
    rescue StandardError => e
      warn "TCP keepalive not configured: #{e.message}"
    end

    def proxy_stream(source, destination)
      IO.copy_stream(source, destination)
    rescue IOError, SystemCallError
    ensure
      destination.close_write rescue nil
    end
  end
end
