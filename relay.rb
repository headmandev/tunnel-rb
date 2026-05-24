require 'socket'
require 'json'
require 'securerandom'
require 'thread'
require 'timeout'

class RelayServer
  # domain_suffix is appended when building the public tunnel URL
  # For local testing, use ".localhost:8080"
  def initialize(control_port = 7777, public_port = 8080, domain_suffix = ".tunnel.test")
    @control_port = control_port
    @public_port = public_port
    @domain_suffix = domain_suffix

    @clients = {}              # subdomain -> control_socket
    @pending_connections = {}  # conn_id -> Queue
    @mutex = Mutex.new         # Thread-safety lock
  end

  def start
    puts "🚀 Starting relay server..."
    Thread.new { listen_for_tunnels }
    Thread.new { listen_for_public }

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

    if request['action'] == 'register'
      handle_registration(socket)
    elsif request['action'] == 'bind'
      handle_data_bind(socket, request['conn_id'])
    end
  rescue => e
    puts "❌ Tunnel connection error: #{e.message}"
    socket.close rescue nil
  end

  def handle_registration(control_socket)
    subdomain = "dev-#{SecureRandom.hex(2)}"
    url = "https://#{subdomain}#{@domain_suffix}"

    @mutex.synchronize { @clients[subdomain] = control_socket }

    control_socket.puts({ status: 'ok', url: url }.to_json)
    puts "✅ Tunnel registered: #{url}"

    # Keep the control channel open; gets returning nil means the client disconnected
    loop do
      break unless control_socket.gets
    end
  ensure
    # Cleanup: remove the tunnel from memory when the client disconnects
    @mutex.synchronize { @clients.delete(subdomain) }
    control_socket.close rescue nil
    puts "🔴 Tunnel #{subdomain} disconnected"
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
      Thread.new { handle_public_request(browser_socket) }
    end
  end

  def handle_public_request(browser_socket)
    buffer = ""
    host = nil

    # 1. Read headers and extract Host
    while (line = browser_socket.gets)
      buffer << line
      if match = line.match(/^Host:\s+([^:\r\n]+)/i)
        host = match[1]
      end
      break if line.strip.empty? # End of headers
    end

    # 2. Resolve tunnel owner (dev-a1b2.tunnel.test -> dev-a1b2)
    subdomain = host&.sub(@domain_suffix, '')
    control_socket = @mutex.synchronize { @clients[subdomain] }

    unless control_socket
      send_error(browser_socket, 404, "Tunnel '#{subdomain}' not found or disconnected.")
      return
    end

    # 3. Set up pending connection (queue)
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
      @mutex.synchronize { @pending_connections.delete(conn_id) }
      send_error(browser_socket, 504, "Timeout: local server did not respond.")
      return
    end

    # 6. Bidirectional stream proxy
    data_socket.write(buffer) # Forward headers already read from the browser
    proxy_stream(browser_socket, data_socket)

  rescue => e
    puts "❌ HTTP routing error: #{e.message}"
  ensure
    browser_socket.close rescue nil
  end

  # ==============================================================
  # HELPERS
  # ==============================================================
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