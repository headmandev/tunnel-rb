# frozen_string_literal: true

require "securerandom"
require "socket"
require "timeout"

require_relative "thread_pool"
require_relative "http_request"
require_relative "socket_helpers"

module TunnelRb
  class Server
    # Public-facing HTTP edge: accepts browser connections, parses headers,
    # asks the tunneled client to open a fresh data connection via
    # PendingConnections, and proxies bytes both ways.
    class PublicServer
      POOL_SIZE = 200
      QUEUE_SIZE = 200
      READ_TIMEOUT_SEC = 5
      BIND_WAIT_SEC = 10

      def initialize(port:, registry:, pending_connections:, logger:)
        @port = port
        @registry = registry
        @pending_connections = pending_connections
        @logger = logger

        @pool = ThreadPool.new(POOL_SIZE, max_queue: QUEUE_SIZE)
        @stopping = false
        @server = nil
      end

      def start
        @server = TCPServer.new("0.0.0.0", @port)
        @logger.info "🌍 Public server listening on #{@port}"

        loop do
          browser_socket = @server.accept
          @pool.submit { handle_request(browser_socket) }
        rescue IOError, Errno::EBADF
          break if @stopping

          raise
        end
      end

      def stop
        @stopping = true
        @server&.close rescue nil
        @pool.shutdown
      end

      private

      def handle_request(browser_socket)
        conn_id = nil
        data_socket = nil
        client_ip = browser_socket.remote_address.ip_address rescue "127.0.0.1"
        SocketHelpers.enable_tcp_nodelay(browser_socket)

        host, header_buffer = read_headers(browser_socket, client_ip)
        return unless header_buffer

        subdomain = extract_subdomain(host)
        client = @registry.lookup(subdomain)
        unless client
          send_error(browser_socket, 404, "Tunnel '#{subdomain}' not found or disconnected.")
          return
        end

        conn_id = SecureRandom.uuid
        queue = @pending_connections.register(conn_id)

        begin
          client.send_message(action: "new_connection", conn_id: conn_id)
        rescue => _e
          send_error(browser_socket, 502, "Failed to reach tunnel.")
          return
        end

        begin
          Timeout.timeout(BIND_WAIT_SEC) { data_socket = queue.pop }
        rescue Timeout::Error
          send_error(browser_socket, 504, "Timeout: local server did not respond.")
          return
        end

        data_socket.write(header_buffer)
        proxy_stream(browser_socket, data_socket)
      rescue => e
        @logger.warn "❌ HTTP routing error: #{e.message}"
      ensure
        @pending_connections.close(conn_id) if conn_id
        data_socket.close rescue nil if data_socket
        browser_socket.close rescue nil
      end

      def read_headers(browser_socket, client_ip)
        HttpRequest.read(browser_socket, client_ip: client_ip, timeout: READ_TIMEOUT_SEC)
      rescue HttpRequest::Timeout
        send_error(browser_socket, 408, "Request Timeout")
        [nil, nil]
      end

      def extract_subdomain(host_header)
        return nil if host_header.nil? || host_header.empty?

        host_header.split(":", 2).first.split(".").first
      end

      def proxy_stream(client, backend)
        t1 = Thread.new do
          IO.copy_stream(client, backend) rescue nil
          backend.close_write rescue nil
        end
        t2 = Thread.new do
          IO.copy_stream(backend, client) rescue nil
          client.close_write rescue nil
        end
        t1.join
        t2.join
      end

      STATUS_TEXTS = {
        404 => "Not Found",
        408 => "Request Timeout",
        502 => "Bad Gateway",
        504 => "Gateway Timeout"
      }.freeze

      def send_error(socket, code, message)
        status = STATUS_TEXTS.fetch(code, "Bad Gateway")
        socket.print(
          "HTTP/1.1 #{code} #{status}\r\n" \
          "Connection: close\r\n" \
          "Content-Length: #{message.bytesize}\r\n" \
          "Content-Type: text/plain; charset=utf-8\r\n" \
          "\r\n#{message}"
        )
        socket.close rescue nil
      end
    end
  end
end
