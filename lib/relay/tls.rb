require "openssl"

module Relay
  # Builds TLS contexts and wraps the control listener. TLS is optional:
  # callers pass nil cert/key to run the control plane in plaintext.
  module TLS
    module_function

    # Returns an SSLContext configured to present the given cert/key, or
    # nil when either path is missing (TLS disabled).
    def server_context(cert_path:, key_path:)
      return nil if cert_path.nil? || key_path.nil?

      ctx = OpenSSL::SSL::SSLContext.new
      certs = load_certificates(cert_path)
      ctx.cert = certs.shift
      ctx.extra_chain_cert = certs unless certs.empty?
      ctx.key = OpenSSL::PKey.read(File.read(key_path))
      ctx.min_version = OpenSSL::SSL::TLS1_2_VERSION
      ctx
    end

    # Wraps a TCPServer in an SSLServer. The handshake is deferred
    # (start_immediately = false) so accept() does not block on a slow
    # client; the worker thread performs the handshake instead.
    def load_certificates(path)
      File.read(path).scan(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m).map do |pem|
        OpenSSL::X509::Certificate.new(pem)
      end.tap do |certs|
        raise "No certificates in #{path}" if certs.empty?
      end
    end

    def wrap_listener(tcp_server, ctx)
      ssl_server = OpenSSL::SSL::SSLServer.new(tcp_server, ctx)
      ssl_server.start_immediately = false
      ssl_server
    end
  end
end
