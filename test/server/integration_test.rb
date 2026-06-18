require "minitest/autorun"
require "json"
require "socket"
require "stringio"
require "tempfile"

require "tunnel_rb/server"

# End-to-end test: a real TunnelRb::Server on ephemeral ports, a hand-rolled
# tunnel client that speaks the wire protocol, and a browser-side TCP
# socket making an HTTP request that should be proxied through the tunnel.
class IntegrationTest < Minitest::Test
  def setup
    @control_port = pick_free_port
    @public_port  = pick_free_port

    @tokens_file = Tempfile.new("e2e-tokens")
    @tokens_file.close
    File.delete(@tokens_file.path) if File.exist?(@tokens_file.path)

    @log_io = StringIO.new
    logger  = TunnelRb::Server::Logger.new(out: @log_io, err: @log_io)

    @server = TunnelRb::Server.new(
      control_port: @control_port,
      public_port: @public_port,
      domain: "test",
      url_port: @public_port,
      tokens_path: @tokens_file.path,
      logger: logger
    )
    @server_thread = Thread.new { @server.start(install_signals: false) }

    wait_for_listen(@control_port)
    wait_for_listen(@public_port)
  end

  def teardown
    @server&.stop
    @server_thread&.join(5)
    File.delete(@tokens_file.path) if File.exist?(@tokens_file.path)
  end

  def test_browser_request_is_proxied_through_tunnel
    control = TCPSocket.new("127.0.0.1", @control_port)
    control.puts({ action: "register" }.to_json)

    welcome = JSON.parse(control.gets)
    assert_equal "ok", welcome["status"]
    refute_nil welcome["token"]

    subdomain = welcome["url"][%r{\Ahttps://([^.]+)}, 1]
    refute_nil subdomain, "expected subdomain in URL #{welcome["url"].inspect}"
    assert_equal "https://#{subdomain}.test:#{@public_port}", welcome["url"]

    fake_client = Thread.new { run_fake_client(control) }

    response = http_get(@public_port, "#{subdomain}.test:#{@public_port}", "/hello")

    assert_match(%r{\AHTTP/1\.1 200 OK}, response)
    assert_includes response, "from-fake-backend"
    assert_includes response, "got-path:/hello"

    fake_client.kill
    control.close rescue nil
  end

  def test_unknown_subdomain_returns_404
    response = http_get(@public_port, "no-such.test:#{@public_port}", "/")
    assert_match(%r{\AHTTP/1\.1 404 Not Found}, response)
    assert_includes response, "Tunnel 'no-such' not found"
  end

  def test_invalid_request_line_returns_400
    sock = TCPSocket.new("127.0.0.1", @public_port)
    sock.print("NOT HTTP\r\nHost: foo.test\r\n\r\n")
    response = sock.read
    assert_match(%r{\AHTTP/1\.1 400 Bad Request}, response)
    assert_includes response, "Bad Request"
  ensure
    sock&.close rescue nil
  end

  def test_token_persists_across_reconnect
    sock1 = TCPSocket.new("127.0.0.1", @control_port)
    sock1.puts({ action: "register" }.to_json)
    welcome1 = JSON.parse(sock1.gets)
    sock1.close

    sock2 = TCPSocket.new("127.0.0.1", @control_port)
    sock2.puts({ action: "register", token: welcome1["token"] }.to_json)
    welcome2 = JSON.parse(sock2.gets)
    sock2.close

    assert_equal welcome1["url"], welcome2["url"], "reconnect with token should keep the same subdomain"
  end

  private

  def run_fake_client(control)
    while (line = control.gets)
      msg = JSON.parse(line) rescue next
      case msg["action"]
      when "ping"
        control.puts({ action: "pong" }.to_json)
      when "new_connection"
        Thread.new(msg["conn_id"]) { |cid| handle_data_connection(cid) }
      end
    end
  rescue IOError, SystemCallError
    nil
  end

  def handle_data_connection(conn_id)
    data = TCPSocket.new("127.0.0.1", @control_port)
    data.puts({ action: "bind", conn_id: conn_id }.to_json)

    request_line = data.gets
    while (line = data.gets) && line.strip != ""
      # consume remaining headers; the server forwards them verbatim
    end
    path = request_line.split(" ", 3)[1] rescue "?"

    body = "from-fake-backend got-path:#{path}"
    data.print(
      "HTTP/1.1 200 OK\r\n" \
      "Content-Length: #{body.bytesize}\r\n" \
      "Connection: close\r\n" \
      "\r\n#{body}"
    )
  ensure
    data&.close rescue nil
  end

  def http_get(port, host_header, path)
    sock = TCPSocket.new("127.0.0.1", port)
    sock.print(
      "GET #{path} HTTP/1.1\r\n" \
      "Host: #{host_header}\r\n" \
      "Connection: close\r\n" \
      "\r\n"
    )
    sock.read
  ensure
    sock&.close rescue nil
  end

  def pick_free_port
    s = TCPServer.new("127.0.0.1", 0)
    port = s.addr[1]
    s.close
    port
  end

  def wait_for_listen(port, timeout: 5)
    deadline = Time.now + timeout
    loop do
      begin
        TCPSocket.new("127.0.0.1", port).close
        return
      rescue Errno::ECONNREFUSED
        raise "port #{port} did not start listening within #{timeout}s" if Time.now > deadline

        sleep 0.05
      end
    end
  end
end
