require 'socket'
require 'json'
require 'optparse'
require 'openssl'

class Tunnel
  TCP_KEEPALIVE_IDLE = 60
  TCP_KEEPALIVE_INTERVAL = 30
  TCP_KEEPALIVE_PROBES = 3

  CONNECT_TIMEOUT = 5            # seconds; applies to both relay and local connect
  RECONNECT_INITIAL_DELAY = 1    # seconds
  RECONNECT_MAX_DELAY = 30       # seconds; cap for exponential backoff

  LOCAL_UNREACHABLE_ERRORS = [
    Errno::ECONNREFUSED,
    Errno::EHOSTUNREACH,
    Errno::ENETUNREACH,
    Errno::ETIMEDOUT,
    SocketError
  ].freeze

  def initialize(relay_host:, relay_port:, local_host: 'localhost', local_port:, tls: false, tls_ca: nil, tls_verify: false)
    @relay_host = relay_host
    @relay_port = relay_port
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
    @control_socket = open_tcp(@relay_host, @relay_port)
    enable_tcp_keepalive(@control_socket)

    payload = { action: 'register' }
    payload[:token] = @token if @token
    @control_socket.puts(payload.to_json)

    response = read_json(@control_socket, "registration response")
    raise "Registration failed: #{response['error']}" if response['status'] != 'ok'

    @token = response['token']
    transport = @tls ? 'TLS' : 'TCP'
    puts "\n🚀 [Tunnel] Ready! #{response['url']} -> #{@local_host}:#{@local_port} (relay: #{transport})\n\n"

    yield if block_given?

    loop do
      command = read_json(@control_socket, "command")

      case command['action']
      when 'ping'
        @control_socket.puts({ action: 'pong' }.to_json)
      when 'new_connection'
        Thread.new { handle_data_connection(command['conn_id']) }
      end
    end
  end

  def handle_data_connection(conn_id)
    relay_sock =
      begin
        open_tcp(@relay_host, @relay_port)
      rescue => e
        warn "[Tunnel] Failed to open data connection to relay: #{e.message}"
        return
      end

    relay_sock.puts({ action: 'bind', conn_id: conn_id }.to_json)

    begin
      local_sock = open_tcp(@local_host, @local_port, tls: false)
    rescue *LOCAL_UNREACHABLE_ERRORS => e
      respond_bad_gateway(relay_sock, e)
      return
    end

    t1 = Thread.new { proxy_stream(relay_sock, local_sock) }
    t2 = Thread.new { proxy_stream(local_sock, relay_sock) }
    t1.join
    t2.join
  ensure
    relay_sock&.close
    local_sock&.close
  end

  def open_tcp(host, port, tls: @tls)
    tcp = Socket.tcp(host, port, connect_timeout: CONNECT_TIMEOUT)
    tcp.setsockopt(:TCP, :TCP_NODELAY, true) rescue nil
    return tcp unless tls

    ssl = OpenSSL::SSL::SSLSocket.new(tcp, @ssl_context)
    ssl.hostname = host # SNI
    # Resume a previous TLS session if we have one, so repeat data-socket
    # handshakes skip the certificate/signature step.
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

    # Cache the TLS 1.3 session ticket the relay sends after each handshake so
    # subsequent data sockets can resume instead of doing a full handshake.
    ctx.session_cache_mode = OpenSSL::SSL::SSLContext::SESSION_CACHE_CLIENT
    ctx.session_new_cb = proc do |_ssl, session|
      @session_mutex.synchronize { @tls_session = session }
    end

    if @tls_ca
      # Verify the relay against a specific CA cert/bundle.
      ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
      ctx.ca_file = @tls_ca
    elsif @tls_verify
      # Verify the relay against the host's system CA store.
      ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
      store = OpenSSL::X509::Store.new
      store.set_default_paths
      ctx.cert_store = store
    else
      # Insecure default: accept self-signed relay certs without verification.
      ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
    end
    ctx
  end

  def read_json(socket, what)
    line = socket.gets
    raise "Relay closed connection while waiting for #{what}" if line.nil?

    JSON.parse(line)
  rescue JSON::ParserError => e
    raise "Invalid #{what} from relay: #{e.message}"
  end

  def respond_bad_gateway(relay_sock, error)
    body = "Local service #{@local_host}:#{@local_port} is not reachable: #{error.message}\n"
    relay_sock.write(
      "HTTP/1.1 502 Bad Gateway\r\n" \
      "Connection: close\r\n" \
      "Content-Type: text/plain; charset=utf-8\r\n" \
      "Content-Length: #{body.bytesize}\r\n" \
      "\r\n" \
      "#{body}"
    )
  rescue IOError, SystemCallError
    # Browser/relay already gone, nothing to do.
  end

  def enable_tcp_keepalive(socket)
    # Operate on the raw fd so this works for both plain TCP and TLS sockets
    # (SSLSocket does not define setsockopt itself).
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

def env_bool(name, default)
  value = ENV[name]
  return default if value.nil? || value.empty?

  ['1', 'true', 'yes'].include?(value.downcase)
end

def parse_options(argv)
  options = {
    relay_host: ENV.fetch('RELAY_HOST', 'relay.tunnel-rb.dev'),
    relay_port: Integer(ENV.fetch('RELAY_PORT', '7777')),
    local_host: ENV.fetch('LOCAL_HOST', 'localhost'),
    local_port: ENV['LOCAL_PORT'] ? Integer(ENV['LOCAL_PORT']) : nil,
    tls: env_bool('RELAY_TLS', true),
    tls_ca: ENV['RELAY_TLS_CA'],
    tls_verify: env_bool('RELAY_TLS_VERIFY', true)
  }

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: tunnel.rb [LOCAL_PORT] [options]"
    opts.on('--relay-host HOST', "Relay host (default: #{options[:relay_host]})") { |v| options[:relay_host] = v }
    opts.on('--relay-port PORT', Integer, "Relay port (default: #{options[:relay_port]})") { |v| options[:relay_port] = v }
    opts.on('--local-host HOST', "Local host (default: #{options[:local_host]})") { |v| options[:local_host] = v }
    opts.on('--[no-]tls', 'Connect to the relay over TLS (default: on; use --no-tls for local/testing)') { |v| options[:tls] = v }
    opts.on('--[no-]tls-verify', 'Verify the relay cert against the system CA store (default: on)') { |v| options[:tls_verify] = v }
    opts.on('--tls-ca PATH', 'CA cert/bundle to verify the relay instead of the system CA store') { |v| options[:tls_ca] = v }
    opts.on('-h', '--help', 'Show this help') do
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

if $PROGRAM_NAME == __FILE__
  Tunnel.new(**parse_options(ARGV)).start
end
