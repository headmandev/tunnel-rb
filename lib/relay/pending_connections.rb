require "thread"

module Relay
  # Coordination between the public-request thread (which generates a
  # conn_id and asks the tunneled client for a fresh data socket) and the
  # control connection where the tunneled client eventually 'bind's that
  # socket. The public side registers a Queue, the control side delivers into
  # it.
  class PendingConnections
    def initialize
      @pending = {}
      @mutex = Mutex.new
    end

    def register(conn_id)
      queue = Queue.new
      @mutex.synchronize { @pending[conn_id] = queue }
      queue
    end

    # Public side cleans up its slot whether it consumed the data socket
    # or timed out.
    def close(conn_id)
      @mutex.synchronize { @pending.delete(conn_id) }
    end

    # Control side hands a freshly-bound data socket to whichever public
    # request is waiting. If nobody is waiting (e.g. browser closed first),
    # the socket is closed.
    def deliver(conn_id, socket)
      queue = @mutex.synchronize { @pending.delete(conn_id) }
      if queue
        queue.push(socket)
      else
        socket.close rescue nil
      end
    end
  end
end
