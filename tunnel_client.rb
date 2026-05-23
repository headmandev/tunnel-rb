require 'socket'
require 'json'

class TunnelClient
  TCP_KEEPALIVE_IDLE = 60
  TCP_KEEPALIVE_INTERVAL = 30
  TCP_KEEPALIVE_PROBES = 3

  def initialize(relay_host, relay_port, local_port)
    @relay_host = relay_host
    @relay_port = relay_port
    @local_port = local_port
    @token = nil
  end

  def start
    loop do
      connect_and_run
    rescue Interrupt
      puts "\n[Tunnel] Shutting down..."
      break
    rescue => e
      puts "[Tunnel] Disconnected: #{e.message}. Reconnecting in 2s..."
      sleep 2
    end
  ensure
    @control_socket&.close
  end

  private

  def connect_and_run
    @control_socket = TCPSocket.new(@relay_host, @relay_port)
    enable_tcp_keepalive(@control_socket)

    payload = { action: 'register' }
    payload[:token] = @token if @token
    @control_socket.puts(payload.to_json)

    response = JSON.parse(@control_socket.gets)
    raise "Registration failed: #{response['error']}" if response['status'] != 'ok'

    @token = response['token']
    puts "\n🚀 [Tunnel] Ready! #{response['url']} -> localhost:#{@local_port}\n\n"

    loop do
      line = @control_socket.gets
      break unless line

      command = JSON.parse(line)
      case command['action']
      when 'ping'
        @control_socket.puts({ action: 'pong' }.to_json)
      when 'new_connection'
        Thread.new { handle_data_connection(command['conn_id']) }
      end
    end
  end

  def handle_data_connection(conn_id)
    relay_sock = TCPSocket.new(@relay_host, @relay_port)
    relay_sock.puts({ action: 'bind', conn_id: conn_id }.to_json)

    local_sock = TCPSocket.new('localhost', @local_port)

    t1 = Thread.new { proxy_stream(relay_sock, local_sock) }
    t2 = Thread.new { proxy_stream(local_sock, relay_sock) }

    t1.join
    t2.join
  ensure
    relay_sock&.close
    local_sock&.close
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

# Start the client (connects to the local relay and proxies to port 3000)
client = TunnelClient.new('localhost', 7777, 3000)
client.start
