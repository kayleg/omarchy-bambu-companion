# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"

class QmlBackendSessionTest < Minitest::Test
  def setup
    @source = File.read(File.expand_path("../BambuBackendSession.qml", __dir__))
  end

  def test_chunks_are_reassembled_and_crlf_is_normalized
    result = run_javascript(%w[consumeChunk], <<~'JAVASCRIPT')
      consumeChunk('{"event":', true)
      consumeChunk('"hello"}\r\nwarning\n', true)
      consumeChunk('problem\r\n', false)
      console.log(JSON.stringify({ lines: lines, errors: errors }))
    JAVASCRIPT

    assert_equal ['{"event":"hello"}', "warning"], result.fetch("lines")
    assert_equal ["problem"], result.fetch("errors")
  end

  def test_oversized_line_is_discarded_and_the_next_line_is_delivered
    result = run_javascript(%w[consumeChunk], <<~'JAVASCRIPT')
      maxLineChars = 8
      consumeChunk('123456789', true)
      consumeChunk('ignored\nvalid\n', true)
      console.log(JSON.stringify({ lines: lines, discarding: stdoutDiscarding,
        buffer: stdoutBuffer }))
    JAVASCRIPT

    assert_equal ["valid"], result.fetch("lines")
    refute result.fetch("discarding")
    assert_empty result.fetch("buffer")
  end

  def test_commands_require_a_ready_running_process_and_report_write_failures
    result = run_javascript(%w[writeCommand], <<~'JAVASCRIPT')
      var beforeReady = writeCommand({ op: 'configure' })
      daemonReady = true
      sessionProcess.running = true
      var written = writeCommand({ op: 'refresh_model' })
      sessionProcess.write = function(_) { throw new Error('closed') }
      var failed = writeCommand({ op: 'refresh_model' })
      console.log(JSON.stringify({ beforeReady: beforeReady, written: written,
        failed: failed, writes: writes, failures: failures }))
    JAVASCRIPT

    refute result.fetch("beforeReady")
    assert result.fetch("written")
    refute result.fetch("failed")
    assert_equal ["{\"op\":\"refresh_model\"}\n"], result.fetch("writes")
    assert_equal 1, result.fetch("failures")
  end

  def test_process_stop_resets_session_and_schedules_one_bounded_restart
    result = run_javascript(%w[resetBuffers handleRunningChanged], <<~'JAVASCRIPT')
      started = true
      daemonReady = true
      stdoutBuffer = 'partial'
      handleRunningChanged()
      var firstDelay = restartTimer.interval
      handleRunningChanged()
      var scheduledOnce = restartTimer.restarts === 1
      sessionProcess.running = true
      handleRunningChanged()
      console.log(JSON.stringify({ ready: daemonReady, stopped: stops,
        firstDelay: firstDelay, nextDelay: restartDelay,
        scheduledOnce: scheduledOnce, restartScheduled: restartScheduled,
        buffer: stdoutBuffer }))
    JAVASCRIPT

    refute result.fetch("ready")
    assert_equal 1, result.fetch("stopped")
    assert_equal 1_000, result.fetch("firstDelay")
    assert_equal 2_000, result.fetch("nextDelay")
    assert result.fetch("scheduledOnce")
    refute result.fetch("restartScheduled")
    assert_empty result.fetch("buffer")
  end

  private

  def run_javascript(functions, body)
    definitions = functions.map { |name| extract_function(name) }.join("\n")
    script = <<~JAVASCRIPT
      var maxLineChars = 1048576
      var daemonReady = false
      var restartDelay = 1000
      var restartScheduled = false
      var started = false
      var stdoutBuffer = ''
      var stdoutDiscarding = false
      var stderrBuffer = ''
      var stderrDiscarding = false
      var lines = []
      var errors = []
      var writes = []
      var failures = 0
      var stops = 0
      var sessionProcess = {
        running: false,
        write: function(value) { writes.push(value) }
      }
      var restartTimer = {
        interval: 0,
        restarts: 0,
        restart: function() { this.restarts += 1 }
      }
      function lineReceived(line) { lines.push(line) }
      function errorLineReceived(line) { errors.push(line) }
      function writeFailed() { failures += 1 }
      function stopped() { stops += 1 }
      #{definitions}
      #{body}
    JAVASCRIPT
    output, error, status = Open3.capture3("node", "-e", script)
    assert status.success?, "JavaScript harness failed: #{error}"
    JSON.parse(output)
  end

  def extract_function(name)
    start = @source.index("function #{name}(")
    refute_nil start, "missing function #{name}"
    opening = @source.index("{", start)
    depth = 0
    @source.each_char.with_index.drop(opening).each do |character, index|
      depth += 1 if character == "{"
      depth -= 1 if character == "}"
      return @source[start..index] if depth.zero?
    end
    flunk "unterminated function #{name}"
  end
end
