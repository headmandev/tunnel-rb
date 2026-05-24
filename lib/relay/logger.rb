module Relay
  # Small wrapper around stdout/stderr so call sites stay short and tests
  # can swap in a StringIO. Existing emoji-decorated strings pass through
  # unchanged.
  class Logger
    def initialize(out: $stdout, err: $stderr)
      @out = out
      @err = err
    end

    def info(message)
      @out.puts(message)
    end

    def warn(message)
      @err.puts(message)
    end
  end
end
