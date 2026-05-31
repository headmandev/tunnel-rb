require "minitest/autorun"
require "json"
require "socket"
require "openssl"
require "stringio"
require "tempfile"

require "relay/server"

# End-to-end test mirroring integration_test.rb, but with TLS enabled on the
# control port. A self-signed cert is generated on the fly; the fake client
# and its data sockets connect over TLS (VERIFY_NONE).
class TlsIntegrationTest < Minitest::Test
  def setup
    @control_port = pick_free_port
    @public_port  = pick_free_port

    @tokens_file = Tempfile.new("e2e-tls-tokens")
    @tokens_file.close
    File.delete(@tokens_file.path) if File.exist?(@tokens_file.path)

    @cert_file, @key_file = generate_self_signed_cert

    @log_io = StringIO.new
    logger  = Relay::Logger.new(out: @log_io, err: @log_io)

    @server = Relay::Server.new(
      control_port: @control_port,
      public_port: @public_port,
      domain_suffix: ".test:#{@public_port}",
      tokens_path: @tokens_file.path,
      tls_cert: @cert_file.path,
      tls_key: @key_file.path,
      logger: logger
    )
    @server_thread = Thread.new { @server.start(install_signals: false) }

    wait_for_listen(@control_port)
    wait_for_listen(@public_port)
  end

  def teardown
    @server&.stop
    @server_thread&.join(5)
    [@tokens_file, @cert_file, @key_file].each do |f|
      File.delete(f.path) if f && File.exist?(f.path)
    end
  end

  def test_browser_request_is_proxied_through_tls_tunnel
    control = tls_connect(@control_port)
    control.puts({ action: "register" }.to_json)

    welcome = JSON.parse(control.gets)
    assert_equal "ok", welcome["status"]
    refute_nil welcome["token"]

    subdomain = welcome["url"][%r{\Ahttps://([^.]+)}, 1]
    refute_nil subdomain, "expected subdomain in URL #{welcome["url"].inspect}"

    fake_client = Thread.new { run_fake_client(control) }

    response = http_get(@public_port, "#{subdomain}.test:#{@public_port}", "/hello")

    assert_match(%r{\AHTTP/1\.1 200 OK}, response)
    assert_includes response, "from-fake-backend"
    assert_includes response, "got-path:/hello"

    fake_client.kill
    control.close rescue nil
  end

  def test_plain_tcp_connection_is_rejected_on_tls_port
    plain = TCPSocket.new("127.0.0.1", @control_port)
    plain.puts({ action: "register" }.to_json)

    # The relay expects a TLS handshake; a plaintext registration never gets
    # an "ok" response. Either the read fails or returns no usable JSON.
    line = begin
      plain.gets
    rescue IOError, SystemCallError
      nil
    end

    assert_nil parse_status(line), "plaintext client must not register on a TLS control port"
  ensure
    plain&.close rescue nil
  end

  private

  def parse_status(line)
    return nil if line.nil?

    JSON.parse(line)["status"]
  rescue JSON::ParserError
    nil
  end

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
  rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
    nil
  end

  def handle_data_connection(conn_id)
    data = tls_connect(@control_port)
    data.puts({ action: "bind", conn_id: conn_id }.to_json)

    request_line = data.gets
    while (line = data.gets) && line.strip != ""
      # consume remaining headers; the relay forwards them verbatim
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

  def tls_connect(port)
    tcp = TCPSocket.new("127.0.0.1", port)
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
    ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
    ssl.sync_close = true
    ssl.connect
    ssl
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

  def generate_self_signed_cert
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = OpenSSL::X509::Name.parse("/CN=localhost")
    cert.issuer = cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600
    cert.sign(key, OpenSSL::Digest::SHA256.new)

    cert_file = Tempfile.new(["relay-cert", ".pem"])
    cert_file.write(cert.to_pem)
    cert_file.close

    key_file = Tempfile.new(["relay-key", ".pem"])
    key_file.write(key.to_pem)
    key_file.close

    [cert_file, key_file]
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
