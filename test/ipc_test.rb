# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "stringio"
require "timeout"
require "bambu_companion/ipc"

class IpcTest < Minitest::Test
  SECRET = "ipc-output-secret-sentinel"

  class BlockingOutput
    attr_reader :entered, :release

    def initialize
      @entered = Queue.new
      @release = Queue.new
    end

    def write(value)
      @entered << [value, Thread.current]
      @release.pop
      value.bytesize
    end

    def flush = true
  end

  class FailingOutput
    attr_reader :attempted

    def write(value)
      @attempted = value
      raise IOError, "broken pipe #{SECRET}"
    end

    def flush = true
  end

  class BlockingFailingOutput < BlockingOutput
    def write(value)
      @entered << [value, Thread.current]
      @release.pop
      raise IOError, "close failed #{SECRET}"
    end
  end

  class EachLineOnlyInput
    def initialize(*lines)
      @lines = lines
    end

    def each_line(&block)
      @lines.each(&block)
    end
  end

  def test_emits_one_json_object_per_line_and_redacts_secret
    output = StringIO.new
    secret = "test-secret-sentinel"
    emitter = BambuCompanion::IpcEmitter.new(
      io: output, secret_provider: -> { secret }
    )

    emitter.error(
      scope: "mqtt", code: "auth", message: "rejected #{secret}",
      retryable: true
    )
    emitter.emit("debug", "accessCode" => secret, "nested" => [secret])

    lines = output.string.lines.map { |line| JSON.parse(line) }
    assert_equal(%w[error debug], lines.map { |line| line.fetch("event") })
    refute_includes output.string, secret
    assert_includes output.string, "[REDACTED]"
  end

  def test_reader_accepts_objects_and_rejects_other_json
    assert_equal({ "op" => "shutdown" }, BambuCompanion::IpcReader.parse('{"op":"shutdown"}'))
    assert_raises(BambuCompanion::IpcError) { BambuCompanion::IpcReader.parse("[]") }
    assert_raises(BambuCompanion::IpcError) { BambuCompanion::IpcReader.parse("not-json") }
  end

  def test_reader_discards_parser_cause_and_secret_bearing_input
    error = assert_raises(BambuCompanion::IpcError) do
      BambuCompanion::IpcReader.parse(
        "{\"op\":\"set_secret\",\"accessCode\":\"#{SECRET}\""
      )
    end

    assert_nil error.cause
    refute_includes error.full_message, SECRET
  end

  def test_line_framer_bounds_each_line_only_inputs_and_resynchronizes
    input = EachLineOnlyInput.new(("x" * 70_000) + "\n", "{\"op\":\"shutdown\"}\n")
    records = BambuCompanion::IpcLineFramer.new(input).each.to_a

    assert_same BambuCompanion::IpcLineFramer::OVERSIZED, records.first
    assert_equal({ "op" => "shutdown" }, BambuCompanion::IpcReader.parse(records.last))
    assert_equal 2, records.length
  end

  def test_line_framer_emits_one_oversized_marker_for_an_unterminated_eof_record
    input = StringIO.new("x" * 70_000)

    records = BambuCompanion::IpcLineFramer.new(input).each.to_a

    assert_equal [BambuCompanion::IpcLineFramer::OVERSIZED], records
  end

  def test_redacts_secret_when_it_appears_in_a_json_key
    output = StringIO.new
    secret = "key-secret-sentinel"
    emitter = BambuCompanion::IpcEmitter.new(
      io: output, secret_provider: -> { secret }
    )

    emitter.emit("debug", "prefix-#{secret}" => "safe")

    refute_includes output.string, secret
    assert_includes output.string, "prefix-[REDACTED]"
  end

  def test_uses_one_secret_snapshot_for_an_entire_emission
    output = StringIO.new
    calls = 0
    secret = "snapshot-secret"
    provider = lambda do
      calls += 1
      calls == 1 ? secret : "replacement-secret-#{calls}"
    end
    emitter = BambuCompanion::IpcEmitter.new(io: output, secret_provider: provider)

    emitter.emit("debug", "message" => "rejected #{secret}", "nested" => [secret])

    assert_equal 1, calls
    refute_includes output.string, secret
    assert_includes output.string, "[REDACTED]"
  end

  def test_emit_argument_wins_over_an_event_key_in_the_payload
    output = StringIO.new
    emitter = BambuCompanion::IpcEmitter.new(io: output)

    emitter.emit("requested-event", "event" => "payload-event")

    assert_equal "requested-event", JSON.parse(output.string).fetch("event")
  end

  def test_line_for_captures_and_redacts_one_secret_snapshot_before_writing
    secret = SECRET
    emitter = BambuCompanion::IpcEmitter.new(
      io: StringIO.new, secret_provider: -> { secret }
    )

    line = emitter.line_for("debug", message: "rejected #{SECRET}")
    secret = "replacement-secret"

    assert_equal "debug", JSON.parse(line).fetch("event")
    refute_includes line, SECRET
    assert_includes line, "[REDACTED]"
    assert line.end_with?("\n")
  end

  def test_line_for_escapes_unicode_so_quickshell_chunks_cannot_split_utf8
    emitter = BambuCompanion::IpcEmitter.new(io: StringIO.new)

    line = emitter.line_for("state", message: "géométrie prête")

    assert line.ascii_only?
    assert_match(/\\u[0-9a-f]{4}/i, line)
    assert_equal "géométrie prête", JSON.parse(line).fetch("message")
  end

  def test_line_for_normalizes_invalid_text_and_bounds_scalar_strings
    emitter = BambuCompanion::IpcEmitter.new(io: StringIO.new)

    line = emitter.line_for(
      "error",
      message: "\xFF".b + ("x" * (BambuCompanion::IpcEmitter::MAX_TEXT_BYTES + 1))
    )
    message = JSON.parse(line).fetch("message")

    assert message.valid_encoding?
    assert_operator message.bytesize, :<=, BambuCompanion::IpcEmitter::MAX_TEXT_BYTES
  end

  def test_async_emitter_writes_only_on_its_writer_thread
    output = BlockingOutput.new
    emitter = BambuCompanion::AsyncIpcEmitter.new(
      io: output, secret_provider: -> { SECRET }, join_seconds: 0.02
    )

    emitter.emit("debug", message: SECRET)
    line, writer = Timeout.timeout(1) { output.entered.pop }

    refute_equal Thread.current, writer
    refute_includes line, SECRET
    assert_includes line, "[REDACTED]"
  ensure
    output&.release&.push(true)
    emitter&.close
  end

  def test_async_emitter_queue_is_bounded_and_never_blocks_the_producer
    output = BlockingOutput.new
    emitter = BambuCompanion::AsyncIpcEmitter.new(
      io: output, secret_provider: -> { SECRET }, capacity: 1,
      join_seconds: 0.02
    )
    emitter.emit("first", message: SECRET)
    line, = Timeout.timeout(1) { output.entered.pop }
    emitter.emit("second")

    error = begin
      raise RuntimeError, "sensitive failure #{SECRET}"
    rescue RuntimeError
      assert_raises(BambuCompanion::IpcOutputError) do
        Timeout.timeout(0.1) { emitter.emit("overflow") }
      end
    end

    assert_nil error.cause
    assert_equal "IPC output unavailable", error.message
    refute_includes error.full_message, SECRET
    refute_includes line, SECRET
  ensure
    output&.release&.push(true)
    begin
      emitter&.close
    rescue BambuCompanion::IpcOutputError
      nil
    end
  end

  def test_async_emitter_closed_queue_raises_generic_error_without_cause
    emitter = BambuCompanion::AsyncIpcEmitter.new(io: StringIO.new)
    emitter.close

    error = assert_raises(BambuCompanion::IpcOutputError) do
      emitter.emit("too_late")
    end

    assert_nil error.cause
    assert_equal "IPC output unavailable", error.message
  end

  def test_async_writer_discards_secret_bearing_epipe_cause
    output = FailingOutput.new
    emitter = BambuCompanion::AsyncIpcEmitter.new(
      io: output, secret_provider: -> { SECRET }
    )
    emitter.emit("debug", message: SECRET)

    error = assert_raises(BambuCompanion::IpcOutputError) { emitter.close }

    assert_nil error.cause
    assert_equal "IPC output unavailable", error.message
    refute_includes error.full_message, SECRET
    refute_includes output.attempted, SECRET
  end

  def test_async_writer_notifies_failure_once
    notifications = Queue.new
    emitter = BambuCompanion::AsyncIpcEmitter.new(
      io: FailingOutput.new,
      on_failure: ->(error) { notifications << [error, Thread.current] }
    )
    emitter.emit("first")

    error, notifier = Timeout.timeout(1) { notifications.pop }

    assert_instance_of BambuCompanion::IpcOutputError, error
    assert_nil error.cause
    assert_equal "IPC output unavailable", error.message
    refute_equal Thread.current, notifier
    assert_raises(BambuCompanion::IpcOutputError) { emitter.close }
    assert_raises(ThreadError) { notifications.pop(true) }
  end

  def test_failure_during_close_does_not_notify_failure_callback
    output = BlockingFailingOutput.new
    notifications = Queue.new
    emitter = BambuCompanion::AsyncIpcEmitter.new(
      io: output, join_seconds: 0.2,
      on_failure: ->(error) { notifications << error }
    )
    emitter.emit("queued")
    Timeout.timeout(1) { output.entered.pop }
    closer_result = Queue.new
    closer = Thread.new do
      begin
        emitter.close
      rescue StandardError => error
        closer_result << error
      end
    end
    Timeout.timeout(1) do
      Thread.pass until emitter.instance_variable_get(:@queue).closed?
    end
    output.release << true
    closer.join

    assert_raises(ThreadError) { notifications.pop(true) }
    error = closer_result.pop
    assert_instance_of BambuCompanion::IpcOutputError, error
    assert_nil error.cause
    refute_includes error.full_message, SECRET
  ensure
    output&.release&.push(true)
    closer&.kill
    closer&.join
    begin
      emitter&.close
    rescue BambuCompanion::IpcOutputError
      nil
    end
  end
end
