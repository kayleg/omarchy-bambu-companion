# frozen_string_literal: true

require "json"

module BambuCompanion
  class IpcError < ArgumentError; end
  class IpcOutputError < StandardError; end

  module IpcReader
    module_function

    def parse(line)
      object = JSON.parse(String(line))
      raise IpcError, "IPC command must be an object" unless object.is_a?(Hash)

      object
    rescue JSON::ParserError
      raise IpcError, "invalid IPC JSON", cause: nil
    end
  end

  class IpcLineFramer
    DEFAULT_MAX_LINE_BYTES = 64 * 1024
    READ_CHUNK_BYTES = 4096
    OVERSIZED = Object.new.freeze

    def initialize(io, max_line_bytes: DEFAULT_MAX_LINE_BYTES)
      @io = io
      @max_line_bytes = Integer(max_line_bytes)
      raise ArgumentError, "max_line_bytes must be positive" unless @max_line_bytes.positive?
    end

    def each
      return enum_for(__method__) unless block_given?

      buffer = String.new(encoding: Encoding::BINARY)
      discarding = false
      each_input_chunk do |chunk|
        data = String(chunk).b
        offset = 0
        while (newline = data.index("\n", offset))
          part = data.byteslice(offset, newline - offset + 1)
          if discarding || buffer.bytesize + part.bytesize > @max_line_bytes
            yield OVERSIZED
          else
            buffer << part
            yield buffer.dup
          end
          buffer.clear
          discarding = false
          offset = newline + 1
        end

        tail = data.byteslice(offset, data.bytesize - offset)
        next if tail.nil? || tail.empty? || discarding

        if buffer.bytesize + tail.bytesize > @max_line_bytes
          buffer.clear
          discarding = true
        else
          buffer << tail
        end
      end

      if discarding
        yield OVERSIZED
      elsif !buffer.empty?
        yield buffer
      end
    end

    private

    def each_input_chunk
      if @io.respond_to?(:readpartial)
        loop { yield @io.readpartial(READ_CHUNK_BYTES) }
      else
        @io.each_line { |line| yield line }
      end
    rescue EOFError
      nil
    end
  end

  class IpcEmitter
    SENSITIVE_KEYS = %w[accessCode access_code password secret].freeze
    MAX_TEXT_BYTES = 64 * 1024

    def initialize(io:, secret_provider: -> { nil })
      @io = io
      @secret_provider = secret_provider
      @mutex = Mutex.new
    end

    def emit(event, payload = {})
      line = line_for(event, payload)
      @mutex.synchronize do
        @io.write(line)
        @io.flush
      end
      true
    rescue IpcOutputError
      raise
    rescue StandardError
      raise IpcOutputError, "IPC output unavailable", cause: nil
    end

    def line_for(event, payload = {})
      secret = @secret_provider.call.to_s
      object = stringify_keys(payload).merge("event" => String(event))
      "#{JSON.generate(sanitize(object, secret: secret), ascii_only: true)}\n"
    rescue StandardError
      raise IpcOutputError, "IPC output unavailable", cause: nil
    end

    def error(scope:, code:, message:, retryable:)
      emit("error", scope: scope, code: code, message: message, retryable: retryable)
    end

    private

    def stringify_keys(hash)
      hash.to_h.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
    end

    def sanitize(value, key = nil, secret:)
      return "[REDACTED]" if key && SENSITIVE_KEYS.include?(key.to_s)

      case value
      when Hash
        value.each_with_object({}) do |(child_key, child), out|
          out[redact_secret(child_key, secret)] = sanitize(child, child_key, secret: secret)
        end
      when Array
        value.map { |child| sanitize(child, secret: secret) }
      when String
        redact_secret(value, secret)
      else
        value
      end
    end

    def redact_secret(value, secret)
      text = utf8(value)
      token = utf8(secret)
      text = text.gsub(token, "[REDACTED]") unless token.empty?
      return text if text.bytesize <= MAX_TEXT_BYTES

      text.byteslice(0, MAX_TEXT_BYTES).force_encoding(Encoding::UTF_8).scrub("")
    end

    def utf8(value)
      String(value).encode(
        Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "�"
      )
    end
  end

  class AsyncIpcEmitter
    DEFAULT_CAPACITY = 256
    DEFAULT_JOIN_SECONDS = 0.25
    STOP = Object.new.freeze

    def initialize(io:, secret_provider: -> { nil }, capacity: DEFAULT_CAPACITY,
                   join_seconds: DEFAULT_JOIN_SECONDS, on_failure: nil)
      @capacity = Integer(capacity)
      raise ArgumentError, "capacity must be positive" unless @capacity.positive?

      @join_seconds = Float(join_seconds)
      raise ArgumentError, "join_seconds must be positive" unless @join_seconds.positive?

      @io = io
      @encoder = IpcEmitter.new(io: io, secret_provider: secret_provider)
      @queue = SizedQueue.new(@capacity)
      @state_mutex = Mutex.new
      @on_failure = on_failure
      @closed = false
      @closing = false
      @failed = false
      @failure_notification_pending = false
      @writer = Thread.new { write_loop }
      @writer.report_on_exception = false
    end

    def emit(event, payload = {})
      enqueue(@encoder.line_for(event, payload))
    end

    def error(scope:, code:, message:, retryable:)
      emit("error", scope: scope, code: code, message: message, retryable: retryable)
    end

    def close
      writer = @state_mutex.synchronize do
        @closing = true
        unless @closed
          @closed = true
          begin
            @queue.push(STOP, true)
          rescue ThreadError, ClosedQueueError
            nil
          end
          @queue.close
        end
        @writer
      end
      stop_writer(writer)
      raise_unavailable if failed?

      true
    end

    private

    def enqueue(line)
      failed = false
      notify = @state_mutex.synchronize do
        raise_unavailable if @closed || @failed

        begin
          @queue.push(line, true)
          false
        rescue ThreadError, ClosedQueueError
          failed = true
          transition_failed_unlocked
        end
      end
      notify_failure if notify
      raise_unavailable if failed

      true
    end

    def write_loop
      loop do
        line = @queue.pop
        break if line.nil? || line.equal?(STOP)

        @io.write(line)
        @io.flush
      end
    rescue StandardError
      notify = @state_mutex.synchronize { transition_failed_unlocked }
      notify_failure if notify
    end

    def transition_failed_unlocked
      return false if @failed

      @failed = true
      @closed = true
      @queue.close
      return false if @closing || @failure_notification_pending || !@on_failure

      @failure_notification_pending = true
    end

    def notify_failure
      callback = @state_mutex.synchronize do
        next unless @failure_notification_pending
        next if @closing

        @failure_notification_pending = false
        @on_failure
      end
      callback&.call(IpcOutputError.new("IPC output unavailable"))
    rescue StandardError
      nil
    end

    def stop_writer(writer)
      return unless writer
      return if writer.equal?(Thread.current)

      unless writer.join(@join_seconds)
        writer.kill
        writer.join(@join_seconds)
      end
    rescue StandardError
      writer.kill if writer&.alive?
    end

    def failed?
      @state_mutex.synchronize { @failed }
    end

    def raise_unavailable
      raise IpcOutputError, "IPC output unavailable", cause: nil
    end
  end
end
