# frozen_string_literal: true

require "set"
require "thread"

require_relative "client"

module TunnelRb
  class Server
    # Thread-safe in-memory registry of connected clients keyed by subdomain,
    # with a reverse index for O(1) lookup by socket.
    class ClientRegistry
      def initialize
        @clients = {}             # subdomain -> Client
        @socket_to_subdomain = {} # control_socket -> subdomain
        @mutex = Mutex.new
      end

      # Registers a new client. If a client with the same subdomain is already
      # connected, returns the old socket so the caller can close it outside
      # the registry's mutex.
      def register(subdomain, socket, token)
        old_socket = nil
        client = nil
        @mutex.synchronize do
          old = @clients[subdomain]
          if old && old.socket != socket
            @socket_to_subdomain.delete(old.socket)
            old_socket = old.socket
          end
          client = Client.new(subdomain: subdomain, socket: socket, token: token)
          @clients[subdomain] = client
          @socket_to_subdomain[socket] = subdomain
        end
        [client, old_socket]
      end

      # Removes a client identified by socket. Returns the subdomain it was
      # registered under, or nil if the socket was already gone (e.g. replaced
      # by a reconnect).
      def forget(socket)
        @mutex.synchronize { forget_unlocked(socket) }
      end

      def lookup(subdomain)
        @mutex.synchronize { @clients[subdomain] }
      end

      def lookup_by_socket(socket)
        @mutex.synchronize do
          sub = @socket_to_subdomain[socket]
          sub && @clients[sub]
        end
      end

      # Snapshot of currently registered control sockets, for IO.select.
      def sockets
        @mutex.synchronize { @socket_to_subdomain.keys }
      end

      # Yields each Client under the registry mutex. Block must not block on
      # I/O; collect work and execute it after the iteration.
      def each_client(&block)
        @mutex.synchronize { @clients.each_value(&block) }
      end

      def active_subdomains
        @mutex.synchronize { @clients.keys.to_set }
      end

      def size
        @mutex.synchronize { @clients.size }
      end

      # Atomically tags many clients for removal and returns their sockets.
      # Used by the ping loop to evict unresponsive peers without holding the
      # mutex while closing sockets.
      def forget_many(sockets)
        @mutex.synchronize do
          sockets.each { |s| forget_unlocked(s) }
        end
      end

      private

      def forget_unlocked(socket)
        sub = @socket_to_subdomain.delete(socket)
        return nil unless sub

        client = @clients[sub]
        @clients.delete(sub) if client && client.socket == socket
        sub
      end
    end
  end
end
