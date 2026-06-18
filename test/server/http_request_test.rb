require "minitest/autorun"
require "stringio"

require "tunnel_rb/server/http_request"

class HttpRequestTest < Minitest::Test
  def read_request(raw)
    TunnelRb::Server::HttpRequest.read(StringIO.new(raw), client_ip: "203.0.113.5")
  end

  def test_accepts_valid_get_request_line
    host, buffer = read_request(
      "GET /hello HTTP/1.1\r\n" \
      "Host: abc.example.com\r\n" \
      "\r\n"
    )

    assert_equal "abc.example.com", host
    assert_includes buffer, "GET /hello HTTP/1.1\r\n"
    assert_includes buffer, "X-Forwarded-For: 203.0.113.5\r\n"
    assert_includes buffer, "X-Forwarded-Proto: https\r\n"
  end

  def test_accepts_valid_post_request_line
    host, buffer = read_request(
      "POST /items HTTP/1.0\r\n" \
      "Host: abc.example.com\r\n" \
      "\r\n"
    )

    assert_equal "abc.example.com", host
    assert_includes buffer, "POST /items HTTP/1.0\r\n"
  end

  def test_rejects_non_http_first_line
    assert_raises(TunnelRb::Server::HttpRequest::InvalidRequest) do
      read_request("SSH-2.0-OpenSSH_9.0\r\n")
    end
  end

  def test_rejects_http2_request_line
    assert_raises(TunnelRb::Server::HttpRequest::InvalidRequest) do
      read_request("GET / HTTP/2.0\r\nHost: abc.example.com\r\n\r\n")
    end
  end

  def test_rejects_headers_without_request_line
    assert_raises(TunnelRb::Server::HttpRequest::InvalidRequest) do
      read_request("Host: abc.example.com\r\n\r\n")
    end
  end
end
