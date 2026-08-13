# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"
require "timeout"
require "bambu_companion/application"

class ApplicationTest < Minitest::Test
  SECRET = "application-secret-sentinel"
  OLD_SECRET = "previous-secret-sentinel"

  class Secrets
    attr_reader :lookups, :stored, :cleared, :available_calls

    def initialize(values = {}, available: true)
      @values = values
      @available = available
      @lookups = []
      @stored = []
      @cleared = []
      @available_calls = 0
    end

    def available?
      @available_calls += 1
      @available
    end

    def lookup(serial)
      @lookups << serial
      @values[serial]
    end

    def store(serial, value)
      @stored << [serial, value]
      @available
    end

    def clear(serial)
      @cleared << serial
      true
    end
  end

  class ForbiddenSecrets
    def available? = raise("must not query keyring")
    def lookup(*) = raise("must not query keyring")
    def store(*) = raise("must not query keyring")
    def clear(*) = raise("must not query keyring")
  end

  class Session
    attr_reader :stopped, :arguments

    def initialize(arguments = {}, timeline: nil)
      @arguments = arguments
      @timeline = timeline
      @stopped = false
      @release = Queue.new
    end

    def run
      @release.pop
    end

    def stop
      @timeline&.push(:session_stopped)
      @stopped = true
      @release << true
      true
    end

    def connect(connected, error = nil)
      @arguments.fetch(:on_connection).call(connected, error)
    end

    def report(value)
      @arguments.fetch(:on_report).call(value)
    end

    def fail_with(error)
      @arguments.fetch(:on_error).call(error)
    end
  end

  class ProtocolFailingSession < Session
    def run
      raise MQTT::ProtocolException, "Connection refused: not authorised"
    end
  end

  class Worker
    attr_reader :submissions, :stopped, :arguments

    def initialize(arguments = {}, timeline: nil)
      @arguments = arguments
      @timeline = timeline
      @submissions = []
      @stopped = false
    end

    def start = self

    def submit(**values)
      @submissions << values
    end

    def snapshot(_printer)
      {
        status: "idle", generation: 0, segment_count: 0,
        z_current: nil, z_mode: "unknown", error: nil
      }
    end

    def stop
      @timeline&.push(:worker_stopped)
      @stopped = true
      true
    end
  end

  class RetryWorker < Worker
    attr_writer :model_status

    def initialize(...)
      super
      @model_status = "idle"
    end

    def submit(**values)
      super
      @model_status = "loading"
    end

    def fail_model!
      @model_status = "error"
    end

    def ready_model!
      @model_status = "ready"
    end

    def snapshot(_printer)
      {
        status: @model_status, generation: submissions.length,
        segment_count: 0, z_current: nil, z_mode: "unknown",
        error: @model_status == "error" ? { code: "file_not_found", message: "not ready" } : nil
      }
    end
  end

  class ScriptedInput
    def initialize(objects, after: {})
      @objects = objects
      @after = after
    end

    def each_line
      @objects.each_with_index do |object, index|
        yield "#{JSON.generate(object)}\n"
        @after[index]&.call
      end
    end
  end

  class BlockingFirstMutex
    attr_reader :entered, :release

    def initialize
      @mutex = Mutex.new
      @count_mutex = Mutex.new
      @count = 0
      @entered = Queue.new
      @release = Queue.new
    end

    def synchronize
      first = @count_mutex.synchronize do
        @count += 1
        @count == 1
      end
      if first
        @entered << true
        @release.pop
      end
      @mutex.synchronize { yield }
    end
  end

  class BlockingInsideFirstMutex
    attr_reader :entered, :release

    def initialize
      @mutex = Mutex.new
      @count_mutex = Mutex.new
      @first = true
      @entered = Queue.new
      @release = Queue.new
    end

    def synchronize
      @mutex.synchronize do
        block_now = @count_mutex.synchronize do
          current = @first
          @first = false
          current
        end
        if block_now
          @entered << true
          @release.pop
        end
        yield
      end
    end
  end

  class BlockingOutput
    attr_reader :entered, :release

    def initialize
      @entered = Queue.new
      @release = Queue.new
    end

    def write(value)
      @entered << value
      @release.pop
      value.bytesize
    end

    def flush = true
  end

  class BlockingInput
    attr_reader :entered, :release

    def initialize
      @entered = Queue.new
      @release = Queue.new
    end

    def each_line
      @entered << true
      @release.pop
    end
  end

  class BlockingAfterInput
    attr_reader :entered, :release, :start

    def initialize(*objects, start_blocked: false)
      @objects = objects
      @start = start_blocked ? Queue.new : nil
      @entered = Queue.new
      @release = Queue.new
    end

    def each_line
      @start&.pop
      @objects.each { |object| yield "#{JSON.generate(object)}\n" }
      @entered << true
      @release.pop
    end
  end

  class FailingAfterOutput
    attr_reader :entered, :release, :written

    def initialize(fail_at: 2)
      @fail_at = fail_at
      @count = 0
      @mutex = Mutex.new
      @entered = Queue.new
      @release = Queue.new
      @written = []
    end

    def write(value)
      failure = @mutex.synchronize do
        @count += 1
        @written << value
        @count == @fail_at
      end
      if failure
        @entered << true
        @release.pop
        raise IOError, "writer failed #{SECRET}"
      end
      value.bytesize
    end

    def flush = true
  end

  def commands(*objects)
    StringIO.new(objects.map { |object| JSON.generate(object) }.join("\n") + "\n")
  end

  def parsed_events(output)
    output.string.lines.map { |line| JSON.parse(line) }
  end

  def build_app(input:, output: StringIO.new, secrets: Secrets.new,
                session_factory: nil, worker_factory: nil, **options)
    sessions = []
    workers = []
    session_factory ||= lambda do |**arguments|
      sessions << Session.new(arguments)
      sessions.last
    end
    worker_factory ||= lambda do |**arguments|
      workers << Worker.new(arguments)
      workers.last
    end
    app = BambuCompanion::Application.new(
      input: input, output: output, secret_store: secrets,
      mqtt_factory: session_factory, worker_factory: worker_factory,
      installation_id: "test-installation-id",
      **options
    )
    [app, output, sessions, workers]
  end

  def test_requests_missing_secret_then_stores_and_starts_session_without_leaking_it
    secrets = Secrets.new
    app, output, sessions, workers = build_app(
      input: commands(
        { op: "configure", protocol: 1, config: printer_config },
        { op: "set_secret", accessCode: SECRET, persist: true },
        { op: "shutdown" }
      ),
      secrets: secrets
    )

    app.run

    events = parsed_events(output)
    assert_equal({ "event" => "hello", "protocol" => 1,
                   "secretStorage" => "gnome-keyring",
                   "installationId" => "test-installation-id" }, events.first)
    assert_includes events.map { |event| event.fetch("event") }, "secret_required"
    assert_includes events.map { |event| event.fetch("event") }, "secret_status"
    assert_equal [["0309C123456789", SECRET]], secrets.stored
    assert_equal 1, sessions.length
    assert_equal 1, workers.length
    assert sessions.first.stopped
    assert workers.first.stopped
    refute_includes output.string, SECRET
  end

  def test_installation_identity_is_stable_per_checkout_and_differs_for_a_reinstall
    Dir.mktmpdir("bambu-install-a") do |first|
      Dir.mktmpdir("bambu-install-b") do |second|
        first_id = BambuCompanion::Application.installation_id(first)

        assert_match(/\A[0-9a-f]{64}\z/, first_id)
        assert_equal first_id, BambuCompanion::Application.installation_id(first)
        refute_equal first_id, BambuCompanion::Application.installation_id(second)
      end
    end
  end

  def test_oversized_ipc_record_is_rejected_once_then_reader_resynchronizes
    oversized = JSON.generate(
      op: "unknown", padding: "#{SECRET}-#{'x' * (64 * 1024)}"
    )
    input = StringIO.new(
      "#{oversized}\n#{JSON.generate(op: 'unknown')}\n#{JSON.generate(op: 'shutdown')}\n"
    )
    app, output, = build_app(input: input)

    app.run

    errors = parsed_events(output).select { |event| event["event"] == "error" }
    assert_equal(%w[invalid_ipc unknown_op], errors.map { |event| event.fetch("code") })
    assert_equal "Invalid IPC command", errors.first.fetch("message")
    refute_includes output.string, SECRET
  end

  def test_access_code_longer_than_256_bytes_is_rejected_before_storage_or_runtime_start
    secrets = Secrets.new
    app, output, sessions, workers = build_app(
      input: commands(
        { op: "configure", protocol: 1, config: printer_config },
        { op: "set_secret", accessCode: "x" * 257, persist: true },
        { op: "shutdown" }
      ),
      secrets: secrets
    )

    app.run

    assert_empty secrets.stored
    assert_empty sessions
    assert_empty workers
    error = parsed_events(output).find { |event| event["code"] == "invalid_config" }
    refute_nil error
    assert_equal "LAN access code is too long", error.fetch("message")
  end

  def test_access_code_at_256_bytes_is_accepted
    secret = "x" * 256
    secrets = Secrets.new
    app, _output, sessions, workers = build_app(
      input: commands(
        { op: "configure", protocol: 1, config: printer_config },
        { op: "set_secret", accessCode: secret, persist: true },
        { op: "shutdown" }
      ),
      secrets: secrets
    )

    app.run

    assert_equal [["0309C123456789", secret]], secrets.stored
    assert_equal 1, sessions.length
    assert_equal 1, workers.length
  end

  def test_oversized_keyring_secret_does_not_start_a_runtime
    app, output, sessions, workers = build_app(
      input: commands(
        { op: "configure", protocol: 1, config: printer_config },
        { op: "shutdown" }
      ),
      secrets: Secrets.new({ "0309C123456789" => "x" * 257 })
    )

    app.run

    assert_empty sessions
    assert_empty workers
    assert_includes parsed_events(output).map { |event| event["event"] }, "secret_required"
  end

  def test_legacy_demo_flag_cannot_bypass_the_real_printer_runtime
    app, output, sessions, workers = build_app(
      input: commands(
        { op: "configure", protocol: 1, config: printer_config("demoMode" => true) },
        { op: "shutdown" }
      ),
      secrets: Secrets.new({ "0309C123456789" => SECRET })
    )

    app.run

    assert_equal 1, sessions.length
    assert_equal 1, workers.length
    assert_empty workers.first.submissions
    refute(parsed_events(output).any? { |event| event["code"].to_s.start_with?("demo_") })
  end

  def test_merges_partial_reports_into_state_ipc_and_submits_model_hints_once
    sessions = []
    input = ScriptedInput.new(
      [
        { op: "configure", protocol: 1, config: printer_config },
        { op: "shutdown" }
      ],
      after: {
        0 => lambda do
          sessions.first.connect(true)
          sessions.first.report(
            "print" => {
              "gcode_state" => "RUNNING", "subtask_name" => "cube.gcode",
              "mc_percent" => 12, "nozzle_temper" => 215.5,
              "nozzle_target_temper" => 220, "bed_temper" => 60.0,
              "bed_target_temper" => 65, "layer_num" => 1,
              "total_layer_num" => 150, "mc_remaining_time" => 6,
              "spd_lvl" => 2, "spd_mag" => 100, "wifi_signal" => "-49dBm",
              "cooling_fan_speed" => "11", "heatbreak_fan_speed" => "10"
            }
          )
          sessions.first.report("print" => { "mc_percent" => 47, "layer_num" => 2 })
        end
      }
    )
    worker = Worker.new
    app, output, = build_app(
      input: input,
      secrets: Secrets.new({ "0309C123456789" => SECRET }),
      session_factory: lambda { |**arguments| sessions << Session.new(arguments); sessions.last },
      worker_factory: ->(**) { worker }
    )

    app.run

    states = parsed_events(output).select { |event| event["event"] == "state" }
    final = states.last.fetch("printer")
    assert_equal true, final.fetch("connected")
    assert_equal false, final.fetch("stale")
    assert_equal "RUNNING", final.fetch("gcodeState")
    assert_equal "cube.gcode", final.fetch("subtaskName")
    assert_equal 47, final.fetch("percent")
    assert_equal 215.5, final.fetch("nozzleTemp")
    assert_equal 220.0, final.fetch("nozzleTargetTemp")
    assert_equal 60.0, final.fetch("bedTemp")
    assert_equal 65.0, final.fetch("bedTargetTemp")
    assert_equal 2, final.fetch("layer")
    assert_equal 150, final.fetch("totalLayers")
    assert_equal 6, final.fetch("remainingMinutes")
    assert_equal 2, final.fetch("speedLevel")
    assert_equal 100, final.fetch("speedMagnitude")
    assert_equal "-49dBm", final.fetch("wifiSignal")
    assert_equal 11.0, final.fetch("coolingFanSpeed")
    assert_equal 10.0, final.fetch("heatbreakFanSpeed")
    assert_equal [{ hints: { subtask_name: "cube.gcode" } }], worker.submissions
    assert_equal(states.length.times.map { |index| index + 1 }, states.map { |state| state.fetch("sequence") })
    refute_includes output.string, SECRET
  end

  def test_refresh_resubmits_the_last_real_printer_hints
    sessions = []
    input = ScriptedInput.new(
      [
        { op: "configure", protocol: 1, config: printer_config },
        { op: "refresh_model" },
        { op: "shutdown" }
      ],
      after: {
        0 => lambda do
          sessions.first.report(
            "print" => { "gcode_state" => "RUNNING", "gcode_file" => "job.gcode.3mf" }
          )
        end
      }
    )
    worker = Worker.new
    app, = build_app(
      input: input,
      secrets: Secrets.new({ "0309C123456789" => SECRET }),
      session_factory: lambda { |**arguments| sessions << Session.new(arguments); sessions.last },
      worker_factory: ->(**) { worker }
    )

    app.run

    assert_equal 2, worker.submissions.length
    assert_equal "job.gcode.3mf", worker.submissions.last.fetch(:hints).fetch(:gcode_file)
  end

  def test_running_print_retries_a_model_that_was_unavailable_during_preparation
    now = 100.0
    sessions = []
    worker = RetryWorker.new
    app, = build_app(
      input: StringIO.new,
      secrets: Secrets.new({ "0309C123456789" => SECRET }),
      session_factory: lambda { |**arguments| sessions << Session.new(arguments); sessions.last },
      worker_factory: ->(**) { worker },
      monotonic_clock: -> { now }
    )
    app.handle("op" => "configure", "protocol" => 1, "config" => printer_config)

    sessions.first.report(
      "print" => {
        "gcode_state" => "RUNNING",
        "gcode_file" => "delayed-model.3mf",
        "task_id" => "print-42"
      }
    )
    assert_equal 1, worker.submissions.length

    worker.fail_model!
    now = 104.9
    sessions.first.report("print" => { "mc_percent" => 1 })
    assert_equal 1, worker.submissions.length

    now = 105.0
    sessions.first.report("print" => { "mc_percent" => 2 })
    assert_equal 2, worker.submissions.length
    assert_equal "delayed-model.3mf",
                 worker.submissions.last.fetch(:hints).fetch(:gcode_file)

    worker.fail_model!
    now = 114.9
    sessions.first.report("print" => { "mc_percent" => 3 })
    assert_equal 2, worker.submissions.length

    now = 115.0
    sessions.first.report("print" => { "mc_percent" => 4 })
    assert_equal 3, worker.submissions.length

    worker.fail_model!
    now = 200.0
    sessions.first.report("print" => { "gcode_state" => "FINISH" })
    assert_equal 3, worker.submissions.length
  ensure
    app&.send(:shutdown)
  end

  def test_model_retry_window_is_bounded_even_when_the_error_is_permanent
    assert_equal 6, BambuCompanion::Application::MODEL_MAX_RETRIES

    now = 0.0
    sessions = []
    worker = RetryWorker.new
    app, = build_app(
      input: StringIO.new,
      secrets: Secrets.new({ "0309C123456789" => SECRET }),
      session_factory: lambda { |**arguments| sessions << Session.new(arguments); sessions.last },
      worker_factory: ->(**) { worker },
      monotonic_clock: -> { now }
    )
    app.handle("op" => "configure", "protocol" => 1, "config" => printer_config)
    sessions.first.report(
      "print" => {
        "gcode_state" => "RUNNING", "gcode_file" => "never-ready.3mf",
        "task_id" => "permanent-error"
      }
    )

    25.times do |attempt|
      worker.fail_model!
      now += [5.0, 10.0, 20.0, 30.0][[attempt, 3].min]
      sessions.first.report("print" => { "mc_percent" => attempt })
    end

    assert_equal 7, worker.submissions.length
  ensure
    app&.send(:shutdown)
  end

  def test_reconfiguration_validates_first_then_stops_old_runtime_before_starting_new
    timeline = []
    sessions = []
    workers = []
    secrets = Secrets.new({
      "0309C123456789" => SECRET,
      "SECOND_SERIAL" => SECRET
    })
    session_factory = lambda do |**arguments|
      timeline << [:session_created, arguments.fetch(:config).serial]
      sessions << Session.new(arguments, timeline: timeline)
      sessions.last
    end
    worker_factory = lambda do |**arguments|
      timeline << [:worker_created, arguments.fetch(:config).serial]
      workers << Worker.new(arguments, timeline: timeline)
      workers.last
    end
    app, output, = build_app(
      input: commands(
        { op: "configure", protocol: 1, config: printer_config },
        { op: "configure", protocol: 1, config: printer_config("mqttPort" => 0) },
        { op: "configure", protocol: 1, config: printer_config("serial" => "SECOND_SERIAL") },
        { op: "shutdown" }
      ),
      secrets: secrets,
      session_factory: session_factory,
      worker_factory: worker_factory
    )

    app.run

    assert_equal 2, sessions.length
    assert_equal 2, workers.length
    second_worker = timeline.index([:worker_created, "SECOND_SERIAL"])
    assert_operator timeline.index(:session_stopped), :<, second_worker
    assert_operator timeline.index(:worker_stopped), :<, second_worker
    errors = parsed_events(output).select { |event| event["event"] == "error" }
    assert(errors.any? { |event| event["code"] == "invalid_config" })
  end

  def test_replaced_session_callbacks_cannot_mutate_the_new_state
    sessions = []
    input = ScriptedInput.new(
      [
        { op: "configure", protocol: 1, config: printer_config },
        { op: "configure", protocol: 1, config: printer_config("serial" => "SECOND_SERIAL") },
        { op: "shutdown" }
      ],
      after: {
        1 => lambda do
          sessions.first.connect(true)
          sessions.first.report("print" => { "mc_percent" => 99 })
          sessions.last.connect(true)
          sessions.last.report("print" => { "mc_percent" => 7 })
        end
      }
    )
    app, output, = build_app(
      input: input,
      secrets: Secrets.new({ "0309C123456789" => SECRET, "SECOND_SERIAL" => SECRET }),
      session_factory: lambda { |**arguments| sessions << Session.new(arguments); sessions.last }
    )

    app.run

    states = parsed_events(output).select { |event| event["event"] == "state" }
    assert_equal 7, states.last.dig("printer", "percent")
    refute(states.any? { |event| event.dig("printer", "percent") == 99 })
  end

  def test_in_flight_old_report_cannot_pollute_reconfigured_printer_state
    sessions = []
    app, output, = build_app(
      input: StringIO.new,
      secrets: Secrets.new({ "0309C123456789" => SECRET, "SECOND_SERIAL" => SECRET }),
      session_factory: lambda { |**arguments| sessions << Session.new(arguments); sessions.last }
    )
    app.handle("op" => "configure", "protocol" => 1, "config" => printer_config)
    state_mutex = BlockingFirstMutex.new
    app.instance_variable_set(:@state_mutex, state_mutex)
    stale_report = Thread.new do
      sessions.first.report(
        "print" => { "subtask_name" => "stale-job.gcode", "mc_percent" => 99 }
      )
    end
    state_mutex.entered.pop

    app.handle(
      "op" => "configure", "protocol" => 1,
      "config" => printer_config("serial" => "SECOND_SERIAL")
    )
    state_mutex.release << true
    stale_report.join
    sessions.last.report("print" => { "mc_percent" => 7 })
    app.send(:shutdown)

    final = parsed_events(output).select { |event| event["event"] == "state" }.last
    assert_nil final.dig("printer", "subtaskName")
    assert_equal 7, final.dig("printer", "percent")
  ensure
    state_mutex&.release&.push(true)
    stale_report&.kill
    stale_report&.join
    app&.send(:shutdown)
  end

  def test_concurrent_state_callbacks_emit_sequences_in_allocation_order
    sessions = []
    app, output, = build_app(
      input: StringIO.new,
      secrets: Secrets.new({ "0309C123456789" => SECRET }),
      session_factory: lambda { |**arguments| sessions << Session.new(arguments); sessions.last }
    )
    app.handle("op" => "configure", "protocol" => 1, "config" => printer_config)
    first_allocated = Queue.new
    second_allocated = Queue.new
    release_first = Queue.new
    original_next_sequence = app.method(:next_sequence)
    app.define_singleton_method(:next_sequence) do
      value = original_next_sequence.call
      if value == 1
        first_allocated << true
        release_first.pop
      elsif value == 2
        second_allocated << true
      end
      value
    end
    first = Thread.new { sessions.first.connect(true) }
    first_allocated.pop
    second = Thread.new { sessions.first.connect(false) }
    coordinator = Thread.new do
      Timeout.timeout(0.1) { second_allocated.pop }
    rescue Timeout::Error
      nil
    ensure
      release_first << true
    end

    [first, second, coordinator].each(&:join)
    app.send(:shutdown)

    sequences = parsed_events(output).filter_map do |event|
      event["sequence"] if event["event"] == "state"
    end
    assert_equal [1, 2], sequences
  ensure
    release_first&.push(true)
    [first, second, coordinator].compact.each do |thread|
      thread.kill
      thread.join
    end
    app&.send(:shutdown)
  end

  def test_in_flight_old_runtime_error_is_linearized_before_reconfiguration
    sessions = []
    app, output, = build_app(
      input: StringIO.new,
      secrets: Secrets.new({ "0309C123456789" => SECRET, "SECOND_SERIAL" => SECRET }),
      session_factory: lambda { |**arguments| sessions << Session.new(arguments); sessions.last }
    )
    app.handle("op" => "configure", "protocol" => 1, "config" => printer_config)
    checked_active = Queue.new
    release_check = Queue.new
    replacement_done = Queue.new
    block_mutex = Mutex.new
    blocked = false
    original_active_runtime = app.method(:active_runtime?)
    app.define_singleton_method(:active_runtime?) do |runtime_id|
      result = original_active_runtime.call(runtime_id)
      should_block = block_mutex.synchronize do
        next false if blocked

        blocked = true
      end
      if should_block
        checked_active << true
        release_check.pop
      end
      result
    end
    failure = Thread.new do
      sessions.first.fail_with(RuntimeError.new("stale transport failure"))
    end
    checked_active.pop
    replacement = Thread.new do
      app.handle(
        "op" => "configure", "protocol" => 1,
        "config" => printer_config("serial" => "SECOND_SERIAL")
      )
      replacement_done << true
    end
    coordinator = Thread.new do
      Timeout.timeout(0.1) { replacement_done.pop }
    rescue Timeout::Error
      nil
    ensure
      release_check << true
    end

    [failure, replacement, coordinator].each(&:join)
    app.send(:shutdown)

    events = parsed_events(output)
    error_index = events.index { |event| event["message"] == "stale transport failure" }
    final_status_index = events.rindex { |event| event["event"] == "secret_status" }
    assert error_index.nil? || error_index < final_status_index
  ensure
    release_check&.push(true)
    [failure, replacement, coordinator].compact.each do |thread|
      thread.kill
      thread.join
    end
    app&.send(:shutdown)
  end

  def test_delayed_older_state_publication_uses_the_latest_printer_snapshot
    sessions = []
    app, output, = build_app(
      input: StringIO.new,
      secrets: Secrets.new({ "0309C123456789" => SECRET }),
      session_factory: lambda { |**arguments| sessions << Session.new(arguments); sessions.last }
    )
    app.handle("op" => "configure", "protocol" => 1, "config" => printer_config)
    first_entered = Queue.new
    release_first = Queue.new
    calls_mutex = Mutex.new
    calls = 0
    original_emit_state = app.method(:emit_state)
    app.define_singleton_method(:emit_state) do |**arguments|
      first = calls_mutex.synchronize do
        calls += 1
        calls == 1
      end
      if first
        first_entered << true
        release_first.pop
      end
      original_emit_state.call(**arguments)
    end
    older = Thread.new { sessions.first.report("print" => { "mc_percent" => 10 }) }
    first_entered.pop
    newer = Thread.new { sessions.first.report("print" => { "mc_percent" => 20 }) }
    newer.join
    release_first << true
    older.join
    app.send(:shutdown)

    percents = parsed_events(output).filter_map do |event|
      event.dig("printer", "percent") if event["event"] == "state"
    end
    assert_equal 20, percents.last
    refute_includes percents.drop_while { |percent| percent != 20 }.drop(1), 10
  ensure
    release_first&.push(true)
    [older, newer].compact.each do |thread|
      thread.kill
      thread.join
    end
    app&.send(:shutdown)
  end

  def test_blocked_output_does_not_block_reconfiguration_or_shutdown
    output = BlockingOutput.new
    sessions = []
    app, = build_app(
      input: StringIO.new, output: output,
      secrets: Secrets.new({ "0309C123456789" => SECRET, "SECOND_SERIAL" => SECRET }),
      session_factory: lambda { |**arguments| sessions << Session.new(arguments); sessions.last },
      writer_join_seconds: 0.02
    )
    first = Thread.new do
      app.handle("op" => "configure", "protocol" => 1, "config" => printer_config)
    end
    Timeout.timeout(1) { output.entered.pop }

    refute_nil first.join(0.1), "configuration blocked in output.write"
    replacement = Thread.new do
      app.handle(
        "op" => "configure", "protocol" => 1,
        "config" => printer_config("serial" => "SECOND_SERIAL")
      )
    end
    refute_nil replacement.join(0.1), "reconfiguration blocked behind output.write"
    stopping = Thread.new { app.send(:shutdown) }
    refute_nil stopping.join(0.1), "shutdown waited for blocked output.write"
    assert sessions.all?(&:stopped)
  ensure
    output&.release&.push(true)
    [first, replacement, stopping].compact.each do |thread|
      thread.kill
      thread.join
    end
    app&.send(:shutdown)
  end

  def test_eof_cleanup_finishes_when_output_write_is_blocked
    output = BlockingOutput.new
    app, _output, sessions, workers = build_app(
      input: commands({ op: "configure", protocol: 1, config: printer_config }),
      output: output,
      secrets: Secrets.new({ "0309C123456789" => SECRET }),
      writer_join_seconds: 0.02
    )
    runner = Thread.new { app.run }
    Timeout.timeout(1) { output.entered.pop }

    refute_nil runner.join(0.1), "EOF cleanup waited for blocked output.write"
    assert sessions.first.stopped
    assert workers.first.stopped
  ensure
    output&.release&.push(true)
    runner&.kill
    runner&.join
    app&.send(:shutdown)
  end

  def test_signal_style_interrupt_cleanup_finishes_when_output_write_is_blocked
    output = BlockingOutput.new
    input = BlockingInput.new
    app, = build_app(
      input: input, output: output, writer_join_seconds: 0.02
    )
    runner = Thread.new do
      begin
        app.run
      rescue Interrupt
        :interrupted
      end
    end
    Timeout.timeout(1) { output.entered.pop }
    Timeout.timeout(1) { input.entered.pop }

    runner.raise(Interrupt)

    refute_nil runner.join(0.1), "interrupt cleanup waited for blocked output.write"
    assert_equal :interrupted, runner.value
  ensure
    input&.release&.push(true)
    output&.release&.push(true)
    runner&.kill
    runner&.join
    app&.send(:shutdown)
  end

  def test_writer_epipe_interrupts_blocked_input_and_stops_runtime
    input = BlockingAfterInput.new(
      { op: "configure", protocol: 1, config: printer_config }
    )
    output = FailingAfterOutput.new
    app, _output, sessions, workers = build_app(
      input: input, output: output,
      secrets: Secrets.new({ "0309C123456789" => SECRET }),
      writer_join_seconds: 0.02
    )
    result = Queue.new
    runner = Thread.new do
      begin
        app.run
      rescue StandardError => error
        result << error
      end
    end
    Timeout.timeout(1) { input.entered.pop }
    Timeout.timeout(1) { output.entered.pop }

    output.release << true

    refute_nil runner.join(0.2), "writer EPIPE did not interrupt blocked stdin"
    error = result.pop
    assert_instance_of BambuCompanion::IpcOutputError, error
    assert_equal "IPC output unavailable", error.message
    assert_nil error.cause
    refute_includes error.full_message, SECRET
    assert sessions.first.stopped
    assert workers.first.stopped
  ensure
    input&.release&.push(true)
    output&.release&.push(true)
    runner&.kill
    runner&.join
    begin
      app&.send(:shutdown)
    rescue BambuCompanion::IpcOutputError
      nil
    end
  end

  def test_background_geometry_queue_overflow_interrupts_blocked_input
    input = BlockingAfterInput.new(
      { op: "configure", protocol: 1, config: printer_config }, start_blocked: true
    )
    output = BlockingOutput.new
    app, _output, sessions, workers = build_app(
      input: input, output: output, outbound_capacity: 1,
      writer_join_seconds: 0.02,
      secrets: Secrets.new({ "0309C123456789" => SECRET })
    )
    result = Queue.new
    runner = Thread.new do
      begin
        app.run
      rescue StandardError => error
        result << error
      end
    end
    Timeout.timeout(1) { output.entered.pop }
    input.start << true
    Timeout.timeout(1) { input.entered.pop }
    background_result = Queue.new
    background = Thread.new do
      begin
        workers.first.arguments.fetch(:emitter).emit(
          "geometry_begin", generation: 9, segmentCount: 1
        )
      rescue StandardError => error
        background_result << error
      end
    end
    background.join

    refute_nil runner.join(0.2), "queue overflow did not interrupt blocked stdin"
    error = result.pop
    assert_instance_of BambuCompanion::IpcOutputError, error
    assert_nil error.cause
    assert_instance_of BambuCompanion::IpcOutputError, background_result.pop
    assert sessions.first.stopped
    assert workers.first.stopped
  ensure
    input&.release&.push(true)
    output&.release&.push(true)
    background&.kill
    background&.join
    runner&.kill
    runner&.join
    begin
      app&.send(:shutdown)
    rescue BambuCompanion::IpcOutputError
      nil
    end
  end

  def test_output_failure_after_shutdown_does_not_raise_in_former_run_thread
    app, = build_app(input: commands({ op: "shutdown" }))
    run_finished = Queue.new
    continue = Queue.new
    result = Queue.new
    runner = Thread.new do
      app.run
      run_finished << true
      continue.pop
      result << :unrelated_work_completed
    rescue StandardError => error
      result << error
    end
    Timeout.timeout(1) { run_finished.pop }

    app.send(
      :handle_output_failure,
      BambuCompanion::IpcOutputError.new("IPC output unavailable")
    )
    continue << true

    refute_nil runner.join(0.2), "closed application raised in its former run thread"
    assert_equal :unrelated_work_completed, result.pop
  ensure
    continue&.push(true)
    runner&.kill
    runner&.join
    app&.send(:shutdown)
  end

  def test_signal_cleanup_survives_delayed_async_output_failure
    assert_cleanup_survives_delayed_output_failure(:signal)
  end

  def test_eof_cleanup_survives_delayed_async_output_failure
    assert_cleanup_survives_delayed_output_failure(:eof)
  end

  def test_ipc_interrupt_is_masked_before_the_first_ensure_instruction
    input = BlockingAfterInput.new(
      { op: "configure", protocol: 1, config: printer_config }
    )
    output = FailingAfterOutput.new
    app, _captured, sessions, workers = build_app(
      input: input, output: output,
      secrets: Secrets.new({ "0309C123456789" => SECRET }),
      writer_join_seconds: 0.02
    )
    emitter = app.instance_variable_get(:@emitter)
    failure_entered = Queue.new
    deliver_failure = Queue.new
    failure_delivered = Queue.new
    original_failure = emitter.instance_variable_get(:@on_failure)
    emitter.instance_variable_set(
      :@on_failure,
      lambda do |error|
        failure_entered << true
        deliver_failure.pop
        original_failure.call(error)
      ensure
        failure_delivered << true
      end
    )
    close_calls = Queue.new
    original_close = emitter.method(:close)
    emitter.define_singleton_method(:close) do
      close_calls << true
      original_close.call
    end
    result = Queue.new
    runner = Thread.new do
      app.run
    rescue BambuCompanion::IpcOutputError => error
      result << error
    end
    Timeout.timeout(1) { input.entered.pop }
    Timeout.timeout(1) { output.entered.pop }
    output.release << true
    Timeout.timeout(1) { failure_entered.pop }

    cleanup_entered = Queue.new
    release_cleanup = Queue.new
    application_path = File.expand_path("../lib/bambu_companion/application.rb", __dir__)
    cleanup_line = first_run_ensure_instruction(application_path)
    trace = TracePoint.new(:line) do |event|
      next unless Thread.current.equal?(runner)
      next unless File.expand_path(event.path) == application_path
      next unless event.lineno == cleanup_line

      trace.disable
      cleanup_entered << true
      release_cleanup.pop
    end
    trace.enable
    input.release << true
    Timeout.timeout(1) { cleanup_entered.pop }
    deliver_failure << true
    Timeout.timeout(1) { failure_delivered.pop }
    release_cleanup << true

    refute_nil runner.join(0.2), "IPC interruption escaped before cleanup masking"
    error = result.pop
    assert_instance_of BambuCompanion::IpcOutputError, error
    assert_equal "IPC output unavailable", error.message
    assert sessions.first.stopped
    assert workers.first.stopped
    assert_equal true, close_calls.pop(true)
    assert_nil app.instance_variable_get(:@run_thread)
    refute emitter.instance_variable_get(:@writer).alive?
    assert_nil error.cause
    refute_includes error.full_message, SECRET
  ensure
    trace&.disable
    input&.release&.push(true)
    output&.release&.push(true)
    deliver_failure&.push(true)
    release_cleanup&.push(true)
    runner&.kill
    runner&.join
    begin
      app&.send(:shutdown)
    rescue BambuCompanion::IpcOutputError
      nil
    end
  end

  def test_clear_secret_false_reports_failure_without_claiming_storage_was_cleared
    secrets = Secrets.new({ "0309C123456789" => SECRET })
    secrets.define_singleton_method(:clear) do |serial|
      @cleared << serial
      false
    end
    app, output, sessions, workers = build_app(
      input: commands(
        { op: "configure", protocol: 1, config: printer_config },
        { op: "clear_secret" },
        { op: "shutdown" }
      ),
      secrets: secrets
    )

    app.run

    events = parsed_events(output)
    refute(events.any? do |event|
      event["event"] == "secret_status" && event["stored"] == false
    end)
    failure = events.find { |event| event["code"] == "clear_failed" }
    refute_nil failure
    assert_equal "Unable to clear stored LAN access code", failure.fetch("message")
    assert(events.any? { |event| event["event"] == "secret_required" })
    assert sessions.first.stopped
    assert workers.first.stopped
  end

  private

  def first_run_ensure_instruction(application_path)
    lines = File.readlines(application_path)
    run_start = lines.index { |line| line.match?(/^    def run$/) }
    handle_start = lines.index.with_index do |line, index|
      index > run_start && line.match?(/^    def handle\(/)
    end
    ensure_line = (run_start...handle_start).find do |index|
      lines[index].match?(/^\s+ensure$/)
    end
    ((ensure_line + 1)...handle_start).find do |index|
      stripped = lines[index].strip
      !stripped.empty? && stripped != "begin" && stripped != "end"
    end + 1
  end

  def assert_cleanup_survives_delayed_output_failure(exit_trigger)
    input = BlockingAfterInput.new(
      { op: "configure", protocol: 1, config: printer_config }
    )
    output = FailingAfterOutput.new
    app, _captured, sessions, workers = build_app(
      input: input, output: output,
      secrets: Secrets.new({ "0309C123456789" => SECRET }),
      writer_join_seconds: 0.02
    )
    emitter = app.instance_variable_get(:@emitter)
    failure_entered = Queue.new
    deliver_failure = Queue.new
    failure_delivered = Queue.new
    original_failure = emitter.instance_variable_get(:@on_failure)
    emitter.instance_variable_set(
      :@on_failure,
      lambda do |error|
        failure_entered << true
        deliver_failure.pop
        original_failure.call(error)
      ensure
        failure_delivered << true
      end
    )
    close_calls = Queue.new
    original_close = emitter.method(:close)
    emitter.define_singleton_method(:close) do
      close_calls << true
      original_close.call
    end
    result = Queue.new
    runner = Thread.new do
      app.run
    rescue BambuCompanion::IpcOutputError, Interrupt => error
      result << error
    end
    Timeout.timeout(1) { input.entered.pop }
    Timeout.timeout(1) { output.entered.pop }
    output.release << true
    Timeout.timeout(1) { failure_entered.pop }

    publication = BlockingInsideFirstMutex.new
    app.instance_variable_set(:@publication_mutex, publication)
    exit_trigger == :signal ? runner.raise(Interrupt) : input.release << true
    Timeout.timeout(1) { publication.entered.pop }
    deliver_failure << true
    Timeout.timeout(1) { failure_delivered.pop }
    publication.release << true

    refute_nil runner.join(0.2), "#{exit_trigger} cleanup remained interrupted"
    error = result.pop
    assert_instance_of BambuCompanion::IpcOutputError, error
    assert_equal "IPC output unavailable", error.message
    assert sessions.first.stopped
    assert workers.first.stopped
    assert_equal true, close_calls.pop(true)
    assert_nil app.instance_variable_get(:@run_thread)
    refute emitter.instance_variable_get(:@writer).alive?
    assert_nil error.cause
    refute_includes error.full_message, SECRET
  ensure
    input&.release&.push(true)
    output&.release&.push(true)
    deliver_failure&.push(true)
    publication&.release&.push(true)
    runner&.kill
    runner&.join
    begin
      app&.send(:shutdown)
    rescue BambuCompanion::IpcOutputError
      nil
    end
  end

  public

  def test_clear_secret_exception_is_generic_and_still_requests_a_secret
    secrets = Secrets.new({ "0309C123456789" => SECRET })
    secrets.define_singleton_method(:clear) do |_serial|
      raise "keyring exposed #{SECRET}"
    end
    app, output, = build_app(
      input: commands(
        { op: "configure", protocol: 1, config: printer_config },
        { op: "clear_secret" },
        { op: "shutdown" }
      ),
      secrets: secrets
    )

    app.run

    events = parsed_events(output)
    refute(events.any? do |event|
      event["event"] == "secret_status" && event["stored"] == false
    end)
    failure = events.find { |event| event["code"] == "clear_failed" }
    assert_equal "Unable to clear stored LAN access code", failure.fetch("message")
    assert(events.any? { |event| event["event"] == "secret_required" })
    refute_includes output.string, SECRET
  end

  def test_clear_secret_success_is_the_only_path_that_confirms_not_stored
    secrets = Secrets.new({ "0309C123456789" => SECRET })
    app, output, = build_app(
      input: commands(
        { op: "configure", protocol: 1, config: printer_config },
        { op: "clear_secret" },
        { op: "shutdown" }
      ),
      secrets: secrets
    )

    app.run

    events = parsed_events(output)
    statuses = events.select { |event| event["event"] == "secret_status" }
    assert_equal([true, false], statuses.map { |event| event.fetch("stored") })
    refute(events.any? { |event| event["code"] == "clear_failed" })
    assert(events.any? { |event| event["event"] == "secret_required" })
    assert_equal ["0309C123456789"], secrets.cleared
  end

  def test_malformed_unknown_and_wrong_protocol_commands_emit_stable_errors_and_continue
    raw_input = StringIO.new(
      "{\"op\":\"set_secret\",\"accessCode\":\"#{SECRET}\"\n" \
      "#{JSON.generate(op: "configure", protocol: 2, config: printer_config)}\n" \
      "#{JSON.generate(op: "configure", protocol: 1, config: printer_config)}\n" \
      "#{JSON.generate(op: "not_a_command")}\n" \
      "#{JSON.generate(op: "shutdown")}\n"
    )
    app, output, sessions, = build_app(
      input: raw_input,
      secrets: Secrets.new({ "0309C123456789" => SECRET })
    )

    app.run

    errors = parsed_events(output).select { |event| event["event"] == "error" }
    assert_equal(%w[invalid_ipc unsupported_protocol unknown_op], errors.map { |error| error.fetch("code") })
    assert_equal "Invalid IPC command", errors.first.fetch("message")
    assert_equal 1, sessions.length
    assert_equal "hello", parsed_events(output).first.fetch("event")
    refute_includes output.string, SECRET
  end

  def test_secret_bearing_runtime_errors_are_redacted_and_do_not_stop_command_processing
    secrets = Secrets.new
    factories = 0
    app, output, = build_app(
      input: commands(
        { op: "configure", protocol: 1, config: printer_config },
        { op: "set_secret", accessCode: SECRET, persist: false },
        { op: "shutdown" }
      ),
      secrets: secrets,
      session_factory: lambda do |**|
        factories += 1
        raise "connection rejected #{SECRET}"
      end
    )

    app.run

    assert_equal 1, factories
    refute_includes output.string, SECRET
    error = parsed_events(output).find { |event| event["event"] == "error" && event["code"] == "runtime_start" }
    refute_nil error
    assert_includes error.fetch("message"), "[REDACTED]"
  end

  def test_secret_rotation_invalidates_old_callbacks_before_changing_redaction_secret
    sessions = []
    secrets = Secrets.new({ "0309C123456789" => OLD_SECRET })
    secrets.define_singleton_method(:store) do |serial, value|
      sessions.first.fail_with(RuntimeError.new("old connection rejected #{OLD_SECRET}"))
      super(serial, value)
    end
    app, output, = build_app(
      input: commands(
        { op: "configure", protocol: 1, config: printer_config },
        { op: "set_secret", accessCode: SECRET, persist: true },
        { op: "shutdown" }
      ),
      secrets: secrets,
      session_factory: lambda { |**arguments| sessions << Session.new(arguments); sessions.last }
    )

    app.run

    refute_includes output.string, OLD_SECRET
    refute_includes output.string, SECRET
    refute(parsed_events(output).any? { |event| event["event"] == "error" })
    assert_equal 2, sessions.length
  end

  def test_mqtt_authentication_rejection_has_a_stable_non_retryable_error_code
    sessions = []
    app, output, = build_app(
      input: StringIO.new,
      secrets: Secrets.new({ "0309C123456789" => SECRET }),
      session_factory: lambda { |**arguments| sessions << Session.new(arguments); sessions.last }
    )
    app.handle("op" => "configure", "protocol" => 1, "config" => printer_config)

    sessions.first.fail_with(
      MQTT::ProtocolException.new("Connection refused: not authorised")
    )
    app.send(:shutdown)

    error = parsed_events(output).find do |event|
      event["event"] == "error" && event["scope"] == "mqtt"
    end
    refute_nil error
    assert_equal "authentication", error.fetch("code")
    assert_equal false, error.fetch("retryable")
  end

  def test_secret_replacement_survives_a_session_thread_protocol_exception
    secrets = Secrets.new({ "0309C123456789" => OLD_SECRET })
    sessions = []
    app, output, = build_app(
      input: StringIO.new, secrets: secrets,
      session_factory: lambda do |**arguments|
        sessions << ProtocolFailingSession.new(arguments)
        sessions.last
      end
    )
    app.handle("op" => "configure", "protocol" => 1, "config" => printer_config)
    Timeout.timeout(1) do
      Thread.pass while app.instance_variable_get(:@mqtt_thread)&.alive?
    end

    app.handle(
      "op" => "set_secret", "accessCode" => SECRET, "persist" => true
    )
    app.send(:shutdown)

    assert_equal [["0309C123456789", SECRET]], secrets.stored
    assert parsed_events(output).any? do |event|
      event["event"] == "secret_status" && event["stored"] == true
    end
  end

  def test_eof_stops_the_active_session_and_worker
    app, _output, sessions, workers = build_app(
      input: commands({ op: "configure", protocol: 1, config: printer_config }),
      secrets: Secrets.new({ "0309C123456789" => SECRET })
    )

    app.run

    assert sessions.first.stopped
    assert workers.first.stopped
  end

  def test_daemon_term_signal_exits_cleanly
    root = File.expand_path("..", __dir__)
    stdin = stdout = stderr = wait = nil
    stdin, stdout, stderr, wait = Open3.popen3(RbConfig.ruby, File.join(root, "daemon.rb"))
    hello = Timeout.timeout(2) { stdout.gets }
    assert_equal 1, JSON.parse(hello).fetch("protocol")

    Process.kill("TERM", wait.pid)
    status = Timeout.timeout(2) { wait.value }

    assert status.success?, stderr.read
  ensure
    stdin&.close
    stdout&.close
    stderr&.close
    if wait&.alive?
      Process.kill("KILL", wait.pid)
      wait.value
    end
  end

  def test_daemon_exits_with_constant_fatal_when_async_stdout_writer_fails
    root = File.expand_path("..", __dir__)
    stdin = stdout = stderr = wait = nil
    stdin, stdout, stderr, wait = Open3.popen3(RbConfig.ruby, File.join(root, "daemon.rb"))
    hello = Timeout.timeout(2) { stdout.gets }
    assert_equal 1, JSON.parse(hello).fetch("protocol")
    stdout.close
    stdin.puts(JSON.generate(op: "unknown", accessCode: SECRET))
    stdin.flush

    status = Timeout.timeout(2) { wait.value }
    fatal = stderr.read

    refute status.success?
    assert_equal "bambu-companion: fatal error\n", fatal
    refute_includes fatal, SECRET
  ensure
    stdin&.close
    stdout&.close unless stdout&.closed?
    stderr&.close
    if wait&.alive?
      Process.kill("KILL", wait.pid)
      wait.value
    end
  end


  def test_daemon_fatal_error_is_constant_and_never_prints_secret_cause
    root = File.expand_path("..", __dir__)
    script = <<~RUBY
      $LOAD_PATH.unshift #{File.join(root, "lib").inspect}
      require "bambu_companion/application"
      class << BambuCompanion::Application
        def new(*)
          cause = IOError.new(ENV.fetch("DAEMON_SECRET_SENTINEL"))
          raise RuntimeError, "outer failure", cause: cause
        end
      end
      load #{File.join(root, "daemon.rb").inspect}
    RUBY

    stdout, stderr, status = Open3.capture3(
      { "DAEMON_SECRET_SENTINEL" => SECRET }, RbConfig.ruby, "-e", script
    )

    refute status.success?
    assert_empty stdout
    assert_equal "bambu-companion: fatal error\n", stderr
    refute_includes stderr, SECRET
  end
end
