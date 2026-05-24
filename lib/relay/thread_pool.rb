require "thread"

module Relay
  # Bounded worker pool. `submit` blocks the caller when the queue is full,
  # which propagates backpressure all the way to TCP accept loops.
  class ThreadPool
    SHUTDOWN = :shutdown

    def initialize(size, max_queue: size)
      @size = size
      @queue = SizedQueue.new(max_queue)
      @workers = Array.new(size) do
        Thread.new do
          loop do
            job = @queue.pop
            break if job == SHUTDOWN

            job.call
          rescue => e
            warn "ThreadPool job error: #{e.message}"
          end
        end
      end
    end

    def submit(&block)
      @queue << block
    end

    def shutdown
      @size.times { @queue << SHUTDOWN }
      @workers.each { |t| t.join(2) }
    end
  end
end
