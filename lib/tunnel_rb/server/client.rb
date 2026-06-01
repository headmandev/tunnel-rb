# frozen_string_literal: true

require "json"
require "thread"

module TunnelRb
  class Server
    # Server-side view of a connected tunnel client. Owns the control socket
    # and per-connection state (read buffer, ping bookkeeping, write mutex).
    class Client
      attr_reader :subdomain, :socket, :token, :read_buffer
      attr_accessor :missed_pongs, :pong_received

      def initialize(subdomain:, socket:, token:)
        @subdomain = subdomain
        @socket = socket
        @token = token
        @write_mutex = Mutex.new
        @read_buffer = String.new(encoding: Encoding::ASCII_8BIT)
        @missed_pongs = 0
        @pong_received = true
      end

      def send_message(payload)
        @write_mutex.synchronize { @socket.puts(payload.to_json) }
      end
    end
  end
end
