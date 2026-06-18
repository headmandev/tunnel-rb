# frozen_string_literal: true

require "timeout"

module TunnelRb
  class Server
    # Reads the request line and headers from a browser socket, injects
    # X-Forwarded-* headers, and returns the parsed Host plus the raw bytes
    # ready to forward to the tunneled backend.
    module HttpRequest
      Timeout = Class.new(StandardError)
      InvalidRequest = Class.new(StandardError)

      DEFAULT_TIMEOUT = 5
      REQUEST_LINE = /\A[A-Z]{1,20} \S+ HTTP\/1\.[01]\z/

      module_function

      def read(socket, client_ip:, timeout: DEFAULT_TIMEOUT)
        buffer = +""
        host = nil
        request_line_seen = false

        ::Timeout.timeout(timeout) do
          while (line = socket.gets)
            if line.strip.empty?
              raise InvalidRequest unless request_line_seen

              buffer << "X-Forwarded-For: #{client_ip}\r\n"
              buffer << "X-Forwarded-Proto: https\r\n"
              buffer << "\r\n"
              break
            end

            unless request_line_seen
              raise InvalidRequest unless line.rstrip.match?(REQUEST_LINE)

              request_line_seen = true
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
end
