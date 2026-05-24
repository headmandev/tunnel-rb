require 'socket'
require 'json'
require 'optparse'

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

  def initialize(relay_host:, relay_port:, local_host: 'localhost', local_port:)
    @relay_host = relay_host
    @relay_port = relay_port
    @local_host = local_host
    @local_port = local_port
    @token = nil
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
    puts "\n🚀 [Tunnel] Ready! #{response['url']} -> #{@local_host}:#{@local_port}\n\n"

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
      local_sock = open_tcp(@local_host, @local_port)
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

  def open_tcp(host, port)
    Socket.tcp(host, port, connect_timeout: CONNECT_TIMEOUT)
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

  def proxy_stream(source, destination)
    IO.copy_stream(source, destination)
  rescue IOError, SystemCallError
  ensure
    destination.close_write rescue nil
  end
end

def parse_options(argv)
  options = {
    relay_host: ENV.fetch('RELAY_HOST', 'localhost'),
    relay_port: Integer(ENV.fetch('RELAY_PORT', '7777')),
    local_host: ENV.fetch('LOCAL_HOST', 'localhost'),
    local_port: ENV['LOCAL_PORT'] ? Integer(ENV['LOCAL_PORT']) : nil
  }

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: tunnel.rb [LOCAL_PORT] [options]"
    opts.on('--relay-host HOST', "Relay host (default: #{options[:relay_host]})") { |v| options[:relay_host] = v }
    opts.on('--relay-port PORT', Integer, "Relay port (default: #{options[:relay_port]})") { |v| options[:relay_port] = v }
    opts.on('--local-host HOST', "Local host (default: #{options[:local_host]})") { |v| options[:local_host] = v }
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
