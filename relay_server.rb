require 'socket'
require 'json'
require 'securerandom'
require 'thread'
require 'timeout'

class ThreadPool
  def initialize(size, max_queue: size)
    @queue = SizedQueue.new(max_queue)
    @workers = Array.new(size) do
      Thread.new do
        loop do
          job = @queue.pop
          break if job == :shutdown

          job.call
        rescue => e
          warn "ThreadPool job error: #{e.message}"
        end
      end
    end
  end

  def submit(&block)
    @queue << block
  end
end

class RelayServer
  TOKENS_FILE = '/tmp/rails-tunnel-relay-server-tokens.json'
  TOKEN_TTL = 24 * 3600 # seconds; applies when no active client holds the subdomain
  TOKEN_CLEANUP_INTERVAL = 600
  CONTROL_PING_INTERVAL = 30 # keep NAT mappings alive (most NATs drop idle flows after 60-120s)
  CONTROL_PONG_MISSES = 3
  TCP_KEEPALIVE_IDLE = 60
  TCP_KEEPALIVE_INTERVAL = 30
  TCP_KEEPALIVE_PROBES = 3
  PUBLIC_THREAD_POOL_SIZE = 200
  PUBLIC_QUEUE_SIZE = 200 # blocks accept when pool + queue are full

  # domain_suffix is appended when building the public tunnel URL
  # For local testing, use ".localhost:8080"
  def initialize(control_port = 7777, public_port = 8080, domain_suffix = ".tunnel.test")
    @control_port = control_port
    @public_port = public_port
    @domain_suffix = domain_suffix

    @clients = {}              # subdomain -> { socket:, token:, missed_pongs:, pong_received: }
    @tokens = load_tokens      # token -> { subdomain:, expires_at: }
    @pending_connections = {}  # conn_id -> Queue
    @mutex = Mutex.new         # Thread-safety lock
    @public_pool = ThreadPool.new(PUBLIC_THREAD_POOL_SIZE, max_queue: PUBLIC_QUEUE_SIZE)
  end

  def start
    puts "🚀 Starting relay server..."
    Thread.new { listen_for_tunnels }
    Thread.new { listen_for_public }
    Thread.new { token_cleanup_loop }
    Thread.new { control_ping_loop }

    # Keep the main thread alive so the process does not exit
    sleep
  end

  private

  # ==============================================================
  # PART 1: Tunnel client control connections on port 7777
  # ==============================================================
  def listen_for_tunnels
    server = TCPServer.new('0.0.0.0', @control_port)
    puts "🎧 Control server listening for clients on #{@control_port}"

    loop do
      socket = server.accept
      Thread.new { handle_tunnel_connection(socket) }
    end
  end

  def handle_tunnel_connection(socket)
    # Read the first message to distinguish control vs data connections
    line = socket.gets
    return unless line

    request = JSON.parse(line)

    case request['action']
    when 'register'
      subdomain = handle_registration(socket, request)
      run_control_loop(socket, subdomain) if subdomain
    when 'bind'
      handle_data_bind(socket, request['conn_id'])
    end
  rescue => e
    puts "❌ Tunnel connection error: #{e.message}"
    socket.close rescue nil
  end

  def handle_registration(control_socket, request)
    subdomain = nil
    token = nil
    reused = false

    @mutex.synchronize do
      cleanup_expired_tokens

      if request['token'] && (existing = resolve_token(request['token']))
        subdomain = existing
        reused = true
        revoke_token(request['token'])

        old_client = @clients[subdomain]
        old_socket = old_client&.fetch(:socket)
        old_socket.close rescue nil if old_socket && old_socket != control_socket
      else
        subdomain = generate_subdomain
      end

      token = issue_token(subdomain)
      @clients[subdomain] = {
        socket: control_socket,
        token: token,
        missed_pongs: 0,
        pong_received: true
      }
    end

    url = "https://#{subdomain}#{@domain_suffix}"
    enable_tcp_keepalive(control_socket)
    control_socket.puts({ status: 'ok', url: url, token: token }.to_json)

    puts reused ? "✅ Tunnel reconnected: #{url}" : "✅ Tunnel registered: #{url}"
    subdomain
  end

  def run_control_loop(control_socket, subdomain)
    while (line = control_socket.gets)
      message = JSON.parse(line) rescue next
      next unless message['action'] == 'pong'

      @mutex.synchronize do
        client = @clients[subdomain]
        if client && client[:socket] == control_socket
          client[:pong_received] = true
          client[:missed_pongs] = 0
        end
      end
    end
  ensure
    @mutex.synchronize do
      client = @clients[subdomain]
      @clients.delete(subdomain) if client && client[:socket] == control_socket
    end
    puts "🔴 Tunnel #{subdomain} disconnected"
    control_socket.close rescue nil
  end

  def handle_data_bind(data_socket, conn_id)
    # Fetch the queue created by the browser request thread
    queue = @mutex.synchronize { @pending_connections.delete(conn_id) }

    if queue
      queue.push(data_socket) # Hand the socket off to the browser thread
    else
      # Browser closed the connection before the client bound a data socket
      data_socket.close rescue nil
    end
  end

  # ==============================================================
  # PART 2: Public HTTP traffic (e.g. from nginx) on port 8080
  # ==============================================================
  def listen_for_public
    server = TCPServer.new('0.0.0.0', @public_port)
    puts "🌍 Public server listening on #{@public_port}"

    loop do
      browser_socket = server.accept
      @public_pool.submit { handle_public_request(browser_socket) }
    end
  end

  def handle_public_request(browser_socket)
    buffer = ""
    host = nil
    conn_id = nil
    client_ip = browser_socket.remote_address.ip_address rescue "127.0.0.1"

    begin
      Timeout.timeout(5) do
        while (line = browser_socket.gets)
          if line.strip.empty?
            buffer << "X-Forwarded-For: #{client_ip}\r\n"
            buffer << "X-Forwarded-Proto: https\r\n"
            buffer << "\r\n"
            break
          end

          next if line.match?(/^X-Forwarded-/i)

          # 1. Read headers and extract Host
          buffer << line
          if match = line.match(/^Host:\s+([^\r\n]+)/i)
            host = match[1]
          end
        end
      end
    rescue Timeout::Error
      send_error(browser_socket, 408, "Request Timeout")
      return
    end

    # 2. Resolve tunnel owner (dev-a1b2.tunnel.test -> dev-a1b2)
    subdomain = extract_subdomain(host)
    client = @mutex.synchronize { @clients[subdomain] }
    control_socket = client&.fetch(:socket)

    unless control_socket
      send_error(browser_socket, 404, "Tunnel '#{subdomain}' not found or disconnected.")
      return
    end

    # 3. Set up rendezvous point (queue)
    conn_id = SecureRandom.uuid
    queue = Queue.new
    @mutex.synchronize { @pending_connections[conn_id] = queue }

    # 4. Ask the client to open a new data connection
    begin
      control_socket.puts({ action: 'new_connection', conn_id: conn_id }.to_json)
    rescue => e
      send_error(browser_socket, 502, "Failed to reach tunnel.")
      return
    end

    # 5. Wait for the data connection (10 second timeout)
    data_socket = nil
    begin
      Timeout.timeout(10) { data_socket = queue.pop }
    rescue Timeout::Error
      send_error(browser_socket, 504, "Timeout: local server did not respond.")
      return
    end

    # 6. Bidirectional stream proxy
    data_socket.write(buffer) # Forward headers already read from the browser
    proxy_stream(browser_socket, data_socket)
  rescue => e
    puts "❌ HTTP routing error: #{e.message}"
  ensure
    @mutex.synchronize { @pending_connections.delete(conn_id) } if conn_id
    browser_socket.close rescue nil
  end

  # ==============================================================
  # HELPERS
  # ==============================================================
  def issue_token(subdomain)
    loop do
      token = SecureRandom.hex(16)
      next if @tokens.key?(token)

      @tokens[token] = token_entry(subdomain)
      persist_tokens
      return token
    end
  end

  def subdomain_taken?(subdomain)
    return true if @clients.key?(subdomain)

    @tokens.any? { |_token, entry| token_subdomain(entry) == subdomain }
  end

  def generate_subdomain
    loop do
      candidate = "dev-#{SecureRandom.hex(4)}"
      return candidate unless subdomain_taken?(candidate)
    end
  end

  def revoke_token(token)
    return unless token

    @tokens.delete(token)
    persist_tokens
  end

  def resolve_token(token)
    entry = @tokens[token]
    return nil unless entry

    subdomain = token_subdomain(entry)
    return subdomain if @clients.key?(subdomain)
    return nil if token_expired?(entry)

    subdomain
  end

  def token_entry(subdomain, expires_at: Time.now.to_i + TOKEN_TTL)
    { 'subdomain' => subdomain, 'expires_at' => expires_at }
  end

  def token_subdomain(entry)
    entry.is_a?(Hash) ? entry['subdomain'] : entry
  end

  def token_expired?(entry, now = Time.now.to_i)
    expires_at = entry.is_a?(Hash) ? entry['expires_at'] : nil
    expires_at.nil? || expires_at <= now
  end

  def normalize_token_entry(entry, now)
    if entry.is_a?(Hash)
      token_entry(entry['subdomain'], expires_at: entry['expires_at'] || (now + TOKEN_TTL))
    else
      token_entry(entry, expires_at: now + TOKEN_TTL)
    end
  end

  def cleanup_expired_tokens
    expired = @tokens.reject do |_token, entry|
      subdomain = token_subdomain(entry)
      @clients.key?(subdomain) || !token_expired?(entry)
    end

    return if expired.empty?

    expired.each_key { |token| @tokens.delete(token) }
    persist_tokens
  end

  def token_cleanup_loop
    loop do
      sleep TOKEN_CLEANUP_INTERVAL
      @mutex.synchronize { cleanup_expired_tokens }
    end
  end

  def control_ping_loop
    loop do
      sleep CONTROL_PING_INTERVAL

      to_close = []
      to_ping = []

      @mutex.synchronize do
        @clients.each do |subdomain, client|
          unless client[:pong_received]
            client[:missed_pongs] += 1
            if client[:missed_pongs] >= CONTROL_PONG_MISSES
              to_close << [subdomain, client[:socket]]
              next
            end
          end

          client[:pong_received] = false
          to_ping << client[:socket]
        end
      end

      to_close.each do |subdomain, socket|
        puts "⚠️  Tunnel #{subdomain} unresponsive (#{CONTROL_PONG_MISSES} missed pongs), closing control channel"
        socket.close rescue nil
      end

      to_ping.each do |socket|
        socket.puts({ action: 'ping' }.to_json)
      rescue IOError, SystemCallError
      end
    end
  end

  def load_tokens
    return {} unless File.exist?(TOKENS_FILE)

    now = Time.now.to_i
    tokens = {}
    JSON.parse(File.read(TOKENS_FILE)).each do |token, entry|
      normalized = normalize_token_entry(entry, now)
      next if token_expired?(normalized, now)

      tokens[token] = normalized
    end
    tokens
  rescue JSON::ParserError, SystemCallError => e
    puts "⚠️  Failed to load tokens: #{e.message}"
    {}
  end

  def persist_tokens
    File.write(TOKENS_FILE, JSON.pretty_generate(@tokens))
  rescue SystemCallError => e
    puts "⚠️  Failed to save tokens: #{e.message}"
  end

  def extract_subdomain(host_header)
    return nil if host_header.nil? || host_header.empty?

    host_header.split(':', 2).first.split('.').first
  end

  def enable_tcp_keepalive(socket)
    socket.setsockopt(:SOCKET, :SO_KEEPALIVE, true)
    if defined?(Socket::TCP_KEEPIDLE)
      socket.setsockopt(:TCP, :TCP_KEEPIDLE, TCP_KEEPALIVE_IDLE)
      socket.setsockopt(:TCP, :TCP_KEEPINTVL, TCP_KEEPALIVE_INTERVAL)
      socket.setsockopt(:TCP, :TCP_KEEPCNT, TCP_KEEPALIVE_PROBES)
    elsif defined?(Socket::TCP_KEEPALIVE)
      socket.setsockopt(:TCP, :TCP_KEEPALIVE, TCP_KEEPALIVE_IDLE)
    end
  rescue StandardError => e
    warn "TCP keepalive not configured: #{e.message}"
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
    t1.join; t2.join
  end

  def send_error(socket, code, message)
    status = case code
             when 404 then "Not Found"
             when 504 then "Gateway Timeout"
             else "Bad Gateway"
             end
    socket.print "HTTP/1.1 #{code} #{status}\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n#{message}"
    socket.close rescue nil
  end
end

# Start the server. For local tests, suffix ".localhost:8080"
# allows testing without editing /etc/hosts
RelayServer.new(7777, 8080, ".localhost:8080").start