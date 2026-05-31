require "socket"

module Relay
  module SocketHelpers
    TCP_KEEPALIVE_IDLE = 60
    TCP_KEEPALIVE_INTERVAL = 30
    TCP_KEEPALIVE_PROBES = 3

    module_function

    def enable_tcp_keepalive(socket)
      # Operate on the raw fd so this works for both plain TCP and TLS
      # sockets (SSLSocket does not define setsockopt itself).
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
  end
end
