require "socket"

module Relay
  module SocketHelpers
    TCP_KEEPALIVE_IDLE = 60
    TCP_KEEPALIVE_INTERVAL = 30
    TCP_KEEPALIVE_PROBES = 3

    module_function

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
  end
end
