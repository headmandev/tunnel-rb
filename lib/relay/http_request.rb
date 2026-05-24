require "timeout"

module Relay
  # Reads the request line and headers from a browser socket, injects
  # X-Forwarded-* headers, and returns the parsed Host plus the raw bytes
  # ready to forward to the tunneled backend.
  module HttpRequest
    Timeout = Class.new(StandardError)

    DEFAULT_TIMEOUT = 5

    module_function

    def read(socket, client_ip:, timeout: DEFAULT_TIMEOUT)
      buffer = +""
      host = nil

      ::Timeout.timeout(timeout) do
        while (line = socket.gets)
          if line.strip.empty?
            buffer << "X-Forwarded-For: #{client_ip}\r\n"
            buffer << "X-Forwarded-Proto: https\r\n"
            buffer << "\r\n"
            break
          end

          next if line.match?(/^X-Forwarded-/i)

          buffer << line
          if (match = line.match(/^Host:\s+([^\r\n]+)/i))
            host = match[1]
          end
        end
      end

      [host, buffer]
    rescue ::Timeout::Error
      raise Timeout
    end
  end
end
