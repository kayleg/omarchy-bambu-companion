# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "stringio"
require "timeout"
require "tmpdir"
require "bambu_companion/gcode_parser"
require "bambu_companion/model_worker"

class ModelWorkerTest < Minitest::Test
  TIMEOUT = 2

  class Emitter
    def initialize
      @events = []
      @mutex = Mutex.new
      @notifications = Queue.new
    end

    def emit(event, payload = {})
      record = [event, payload]
      @mutex.synchronize { @events << record }
      @notifications << record
      true
    end

    def events = @mutex.synchronize { @events.dup }

    def wait_for(name, generation: nil)
      Timeout.timeout(TIMEOUT) do
        loop do
          event, payload = @notifications.pop
          return [event, payload] if event == name &&
                                     (generation.nil? || payload[:generation] == generation)
        end
      end
    end
  end

  class StatusCollector
    def initialize
      @snapshots = []
      @mutex = Mutex.new
      @notifications = Queue.new
    end

    def call(snapshot)
      @mutex.synchronize { @snapshots << snapshot }
      @notifications << snapshot
    end

    def snapshots = @mutex.synchronize { @snapshots.dup }

    def wait_for(status, generation: nil)
      Timeout.timeout(TIMEOUT) do
        loop do
          snapshot = @notifications.pop
          return snapshot if snapshot[:status] == status &&
                             (generation.nil? || snapshot[:generation] == generation)
        end
      end
    end
  end

  class InstrumentedMutex
    attr_reader :attempts, :paused, :release

    def initialize(pause_at: nil)
      @mutex = Mutex.new
      @counter_mutex = Mutex.new
      @attempt_count = 0
      @pause_at = pause_at
      @attempts = Queue.new
      @paused = Queue.new
      @release = Queue.new
    end

    def synchronize
      attempt = @counter_mutex.synchronize { @attempt_count += 1 }
      @attempts << [attempt, Thread.current]
      if attempt == @pause_at
        @paused << attempt
        @release.pop
      end
      @mutex.synchronize { yield }
    end
  end

  class BlockingEmitter < Emitter
    attr_reader :entered, :release

    def initialize(event:, generation:)
      super()
      @blocked_event = event
      @blocked_generation = generation
      @entered = Queue.new
      @release = Queue.new
      @blocked = false
    end

    def emit(event, payload = {})
      if !@blocked && event == @blocked_event && payload[:generation] == @blocked_generation
        @blocked = true
        @entered << true
        @release.pop
      end
      super
    end
  end

  class BlockingStatus < StatusCollector
    attr_reader :entered, :release

    def initialize(status:, generation:)
      super()
      @blocked_status = status
      @blocked_generation = generation
      @entered = Queue.new
      @release = Queue.new
      @blocked = false
    end

    def call(snapshot)
      if !@blocked && snapshot[:status] == @blocked_status &&
         snapshot[:generation] == @blocked_generation
        @blocked = true
        @entered << true
        @release.pop
      end
      super
    end
  end

  class BlockingFirstEnqueueQueue
    attr_reader :entered, :release

    def initialize
      @queue = SizedQueue.new(1)
      @mutex = Mutex.new
      @blocked = false
      @entered = Queue.new
      @release = Queue.new
    end

    def push(job, non_block = false)
      should_block = @mutex.synchronize do
        next false if @blocked

        @blocked = true
      end
      if should_block
        @entered << job
        @release.pop
      end
      @queue.push(job, non_block)
      self
    end

    def pop(non_block = false) = @queue.pop(non_block)
    def size = @queue.size
  end

  class MemorySource
    attr_reader :entered, :release

    def initialize(contents, blocked_path: nil, error_path: nil)
      @contents = contents
      @blocked_path = blocked_path
      @error_path = error_path
      @calls = []
      @mutex = Mutex.new
      @entered = Queue.new
      @release = Queue.new
    end

    def open(path, hints)
      @mutex.synchronize { @calls << [path, hints] }
      if path == @blocked_path
        @entered << path
        @release.pop
      end
      raise TestError.new("source_failed", "source failed") if path == @error_path

      yield StringIO.new(@contents.fetch(path))
    end

    def calls = @mutex.synchronize { @calls.dup }
  end

  class RecordingFileSource
    attr_reader :calls

    def initialize = @calls = []

    def open(path, hints)
      @calls << [path, hints]
      File.open(path, "rb") { |io| yield io }
    end
  end

  class TestError < StandardError
    attr_reader :code

    def initialize(code, message)
      @code = code
      super(message)
    end
  end

  class RecordingFtps
    attr_reader :calls

    def initialize(content:, remote: "/cache/remote.gcode")
      @content = content
      @remote = remote
      @calls = []
    end

    def download(hints:, destination:, cancelled:)
      @calls << { hints: hints, destination: destination, cancelled: cancelled }
      raise TestError.new("cancelled", "cancelled") if cancelled.call

      File.binwrite(destination, @content)
      @remote
    end
  end

  class BlockingFtps
    attr_reader :entered, :release, :cancelled

    def initialize
      @entered = Queue.new
      @release = Queue.new
      @cancelled = Queue.new
    end

    def download(hints:, destination:, cancelled:)
      @entered << [hints, destination]
      @release.pop
      was_cancelled = cancelled.call
      @cancelled << was_cancelled
      raise TestError.new("cancelled", "cancelled") if was_cancelled

      File.binwrite(destination, gcode(1))
      "/cache/old.gcode"
    end

    private

    def gcode(x)
      "G90\nM83\n;TYPE:WALL-OUTER\nG1 X0 Y0 Z0.2\nG1 X#{x} Y0 E1\n"
    end
  end

  class UncooperativeFtps
    attr_reader :destination, :finished

    def initialize
      @destination = Queue.new
      @block_forever = Queue.new
      @finished = Queue.new
    end

    def download(destination:, **)
      File.binwrite(destination, "partial")
      @destination << destination
      @block_forever.pop
    ensure
      @finished << true
    end
  end

  def test_publishes_complete_current_generation_in_bounded_json_chunks
    Dir.mktmpdir do |dir|
      path = File.join(dir, "demo.gcode")
      lines = ["G90", "M83", ";TYPE:WALL-OUTER", "G1 X0 Y0 Z0.2"]
      1_205.times { |index| lines << "G1 X#{index + 1} Y0 E1" }
      File.write(path, lines.join("\n"))
      emitter = Emitter.new
      worker = build_worker(
        source: file_source,
        parser: BambuCompanion::GcodeParser.new(max_segments: 2_000),
        emitter: emitter
      )

      job = worker.submit(hints: {}, local_path: path)

      assert worker.process(job)
      names = emitter.events.map(&:first)
      assert_equal "geometry_begin", names.first
      assert_equal "geometry_end", names.last
      chunks = emitter.events.select { |event,| event == "geometry_chunk" }
      assert_equal([500, 500, 205], chunks.map { |_, payload| payload.fetch(:segments).length })
      assert_equal([0, 1, 2], chunks.map { |_, payload| payload.fetch(:index) })
      assert(chunks.all? { |_, payload| payload.fetch(:generation) == job.generation })
      emitter.events.each { |event, payload| JSON.generate(payload.merge(event: event)) }
    end
  end

  def test_background_worker_processes_only_the_latest_pending_generation
    source = MemorySource.new(
      {
        "/old" => gcode(1),
        "/middle" => gcode(2),
        "/newest" => gcode(3)
      },
      blocked_path: "/old"
    )
    emitter = Emitter.new
    statuses = StatusCollector.new
    worker = build_worker(source: source, emitter: emitter, on_status: statuses).start

    old = worker.submit(hints: { file: "old" }, local_path: "/old")
    Timeout.timeout(TIMEOUT) { source.entered.pop }
    middle = worker.submit(hints: { file: "middle" }, local_path: "/middle")
    newest = worker.submit(hints: { file: "newest" }, local_path: "/newest")
    source.release << true
    emitter.wait_for("geometry_end", generation: newest.generation)

    assert_equal ["/old", "/newest"], source.calls.map(&:first)
    refute worker.current?(old)
    refute worker.current?(middle)
    assert worker.current?(newest)
    assert_equal [newest.generation], emitter.events.map { |_, payload| payload[:generation] }.uniq
    refute(statuses.snapshots.any? do |snapshot|
      [old.generation, middle.generation].include?(snapshot[:generation]) &&
        %w[ready error].include?(snapshot[:status])
    end)
  ensure
    worker&.stop
  end

  def test_pending_mailbox_never_exceeds_one_job_and_keeps_only_the_latest_submission
    paths = (1..200).to_h { |index| ["/job-#{index}", gcode(index)] }
    source = MemorySource.new(paths, blocked_path: "/job-1")
    emitter = Emitter.new
    worker = build_worker(source: source, emitter: emitter).start
    worker.submit(hints: {}, local_path: "/job-1")
    Timeout.timeout(TIMEOUT) { source.entered.pop }

    newest = nil
    2.upto(200) do |index|
      newest = worker.submit(hints: {}, local_path: "/job-#{index}")
    end

    assert_equal 1, worker.instance_variable_get(:@queue).size
    source.release << true
    emitter.wait_for("geometry_end", generation: newest.generation)
    assert_equal ["/job-1", "/job-200"], source.calls.map(&:first)
  ensure
    source&.release&.push(true)
    worker&.stop
  end

  def test_stop_replaces_a_pending_job_without_growing_or_blocking_the_mailbox
    source = MemorySource.new(
      { "/running" => gcode(1), "/pending" => gcode(2) },
      blocked_path: "/running"
    )
    worker = build_worker(source: source).start
    worker.submit(hints: {}, local_path: "/running")
    Timeout.timeout(TIMEOUT) { source.entered.pop }
    worker.submit(hints: {}, local_path: "/pending")

    Timeout.timeout(TIMEOUT) { worker.stop }

    assert_operator worker.instance_variable_get(:@queue).size, :<=, 1
  ensure
    source&.release&.push(true)
    worker&.stop
  end

  def test_generation_state_and_enqueue_are_one_atomic_submission
    worker = build_worker
    queue = BlockingFirstEnqueueQueue.new
    worker.instance_variable_set(:@queue, queue)
    results = Queue.new
    first_submitter = Thread.new do
      results << worker.submit(hints: {}, local_path: "/first")
    end
    Timeout.timeout(TIMEOUT) { queue.entered.pop }
    second_submitter = Thread.new do
      results << worker.submit(hints: {}, local_path: "/second")
    end

    assert worker.instance_variable_get(:@mutex).locked?,
           "generation/state mutex must stay locked through queue insertion"
    queue.release << true
    [first_submitter, second_submitter].each { |thread| thread.join(TIMEOUT) }
    jobs = 2.times.map { Timeout.timeout(TIMEOUT) { results.pop } }

    assert_equal [1, 2], jobs.map(&:generation).sort
    assert_equal 2, worker.send(:newest_queued_job).generation
  ensure
    queue&.release&.push(true)
    first_submitter&.join(TIMEOUT)
    second_submitter&.join(TIMEOUT)
  end

  def test_pending_mailbox_replaces_an_older_job_before_the_worker_starts
    worker = build_worker
    old = worker.submit(hints: {}, local_path: "/old")
    current = worker.submit(hints: {}, local_path: "/current")
    queue = worker.instance_variable_get(:@queue)

    selected = worker.send(:newest_queued_job)

    assert_equal 0, queue.size
    assert_equal current.generation, selected.generation
    refute_equal old.generation, selected.generation
  end

  def test_submit_waits_for_a_blocked_geometry_emission_to_finish
    emitter = BlockingEmitter.new(event: "geometry_begin", generation: 1)
    source = MemorySource.new({ "/old" => gcode(1), "/new" => gcode(2) })
    statuses = StatusCollector.new
    publication_mutex = InstrumentedMutex.new
    worker = build_worker(source: source, emitter: emitter, on_status: statuses)
    worker.instance_variable_set(:@publication_mutex, publication_mutex)
    worker.start
    old = worker.submit(hints: {}, local_path: "/old")
    Timeout.timeout(TIMEOUT) { emitter.entered.pop }
    drain_queue(publication_mutex.attempts)
    submitted = Queue.new
    submitter = Thread.new { submitted << worker.submit(hints: {}, local_path: "/new") }
    _, attempting_thread = Timeout.timeout(TIMEOUT) { publication_mutex.attempts.pop }

    assert_same submitter, attempting_thread
    assert_raises(ThreadError) { submitted.pop(true) }
    assert_equal old.generation, worker.snapshot({})[:generation]
    emitter.release << true
    current = Timeout.timeout(TIMEOUT) { submitted.pop }
    statuses.wait_for("ready", generation: current.generation)

    assert_equal 2, current.generation
  ensure
    emitter&.release&.push(true)
    submitter&.join(TIMEOUT)
    worker&.stop
  end

  def test_submit_waits_for_a_blocked_status_callback_to_finish
    statuses = BlockingStatus.new(status: "ready", generation: 1)
    source = MemorySource.new({ "/old" => gcode(1), "/new" => gcode(2) })
    publication_mutex = InstrumentedMutex.new
    worker = build_worker(source: source, on_status: statuses)
    worker.instance_variable_set(:@publication_mutex, publication_mutex)
    worker.start
    old = worker.submit(hints: {}, local_path: "/old")
    Timeout.timeout(TIMEOUT) { statuses.entered.pop }
    drain_queue(publication_mutex.attempts)
    submitted = Queue.new
    submitter = Thread.new { submitted << worker.submit(hints: {}, local_path: "/new") }
    _, attempting_thread = Timeout.timeout(TIMEOUT) { publication_mutex.attempts.pop }

    assert_same submitter, attempting_thread
    assert_raises(ThreadError) { submitted.pop(true) }
    assert_equal old.generation, worker.snapshot({})[:generation]
    statuses.release << true
    current = Timeout.timeout(TIMEOUT) { submitted.pop }
    statuses.wait_for("ready", generation: current.generation)

    assert(statuses.snapshots.any? do |snapshot|
      snapshot[:generation] == old.generation && snapshot[:status] == "ready"
    end)
  ensure
    statuses&.release&.push(true)
    submitter&.join(TIMEOUT)
    worker&.stop
  end

  def test_submit_winning_publication_race_suppresses_stale_geometry_end
    emitter = Emitter.new
    statuses = StatusCollector.new
    source = MemorySource.new({ "/old" => gcode(1), "/new" => gcode(2) })
    publication_mutex = InstrumentedMutex.new(pause_at: 5)
    worker = build_worker(source: source, emitter: emitter, on_status: statuses)
    worker.instance_variable_set(:@publication_mutex, publication_mutex)
    worker.start
    old = worker.submit(hints: {}, local_path: "/old")
    Timeout.timeout(TIMEOUT) { publication_mutex.paused.pop }

    current = worker.submit(hints: {}, local_path: "/new")
    publication_mutex.release << true
    statuses.wait_for("ready", generation: current.generation)

    refute(emitter.events.any? do |event, payload|
      event == "geometry_end" && payload[:generation] == old.generation
    end)
  ensure
    publication_mutex&.release&.push(true)
    worker&.stop
  end

  def test_submit_winning_publication_race_suppresses_stale_ready_status
    statuses = StatusCollector.new
    source = MemorySource.new({ "/old" => gcode(1), "/new" => gcode(2) })
    publication_mutex = InstrumentedMutex.new(pause_at: 6)
    worker = build_worker(source: source, on_status: statuses)
    worker.instance_variable_set(:@publication_mutex, publication_mutex)
    worker.start
    old = worker.submit(hints: {}, local_path: "/old")
    Timeout.timeout(TIMEOUT) { publication_mutex.paused.pop }

    current = worker.submit(hints: {}, local_path: "/new")
    publication_mutex.release << true
    statuses.wait_for("ready", generation: current.generation)

    refute(statuses.snapshots.any? do |snapshot|
      snapshot[:generation] == old.generation && snapshot[:status] == "ready"
    end)
  ensure
    publication_mutex&.release&.push(true)
    worker&.stop
  end

  def test_status_callback_can_submit_reentrantly_without_continuing_stale_job
    emitter = Emitter.new
    statuses = StatusCollector.new
    source = MemorySource.new({ "/old" => gcode(1), "/new" => gcode(2) })
    reentrant_result = Queue.new
    submitted = false
    worker = nil
    callback = lambda do |snapshot|
      statuses.call(snapshot)
      next unless !submitted && snapshot[:generation] == 1 && snapshot[:status] == "loading"

      submitted = true
      begin
        reentrant_result << worker.submit(hints: {}, local_path: "/new")
      rescue StandardError => error
        reentrant_result << error
      end
    end
    worker = build_worker(source: source, emitter: emitter, on_status: callback).start
    old = worker.submit(hints: {}, local_path: "/old")

    current = Timeout.timeout(TIMEOUT) { reentrant_result.pop }
    assert_instance_of BambuCompanion::ModelWorker::Job, current
    statuses.wait_for("ready", generation: current.generation)

    assert_equal old.generation + 1, current.generation
    assert_equal [current.generation], emitter.events.map { |_, payload| payload[:generation] }.uniq
    refute(statuses.snapshots.any? do |snapshot|
      snapshot[:generation] == old.generation && snapshot[:status] == "ready"
    end)
  ensure
    worker&.stop
  end

  def test_stale_source_error_is_not_published
    source = MemorySource.new(
      { "/new" => gcode(2) }, blocked_path: "/old", error_path: "/old"
    )
    emitter = Emitter.new
    statuses = StatusCollector.new
    worker = build_worker(source: source, emitter: emitter, on_status: statuses).start

    old = worker.submit(hints: {}, local_path: "/old")
    Timeout.timeout(TIMEOUT) { source.entered.pop }
    current = worker.submit(hints: {}, local_path: "/new")
    source.release << true
    statuses.wait_for("ready", generation: current.generation)

    refute(statuses.snapshots.any? do |snapshot|
      snapshot[:generation] == old.generation && snapshot[:status] == "error"
    end)
    assert_equal current.generation, worker.snapshot({})[:generation]
    assert_equal "ready", worker.snapshot({})[:status]
  ensure
    worker&.stop
  end

  def test_new_submission_cancels_remote_download_and_suppresses_its_error
    ftps = BlockingFtps.new
    source = MemorySource.new({ "/new" => gcode(2) })
    emitter = Emitter.new
    statuses = StatusCollector.new
    worker = build_worker(
      ftps_client: ftps, source: source, emitter: emitter, on_status: statuses
    ).start

    old = worker.submit(hints: { file: "old.gcode" })
    Timeout.timeout(TIMEOUT) { ftps.entered.pop }
    current = worker.submit(hints: {}, local_path: "/new")
    ftps.release << true
    statuses.wait_for("ready", generation: current.generation)

    assert Timeout.timeout(TIMEOUT) { ftps.cancelled.pop }
    refute(emitter.events.any? { |_, payload| payload[:generation] == old.generation })
    refute(statuses.snapshots.any? do |snapshot|
      snapshot[:generation] == old.generation && snapshot[:status] == "error"
    end)
  ensure
    worker&.stop
  end

  def test_remote_download_uses_source_name_and_cleans_temporary_file
    ftps = RecordingFtps.new(content: gcode(4), remote: "/cache/part.gcode")
    source = RecordingFileSource.new
    worker = build_worker(ftps_client: ftps, source: source)
    hints = { "file" => "part.gcode" }
    job = worker.submit(hints: hints)

    assert worker.process(job)
    path, source_hints = source.calls.fetch(0)
    assert_equal "/cache/part.gcode", source_hints.fetch("source_name")
    assert_equal hints, ftps.calls.fetch(0).fetch(:hints)
    refute_path_exists path
  end

  def test_local_path_uses_source_directly_without_ftps_or_caching
    source = MemorySource.new({ "/demo" => gcode(5) })
    ftps = Object.new
    ftps.define_singleton_method(:download) { |**| flunk("FTPS must not be called") }
    worker = build_worker(ftps_client: ftps, source: source)
    hints = { "plate_idx" => 0 }

    first = worker.submit(hints: hints, local_path: "/demo")
    hints["plate_idx"] = 9
    assert worker.process(first)
    second = worker.submit(hints: {}, local_path: "/demo")
    assert worker.process(second)

    assert_equal 2, source.calls.length
    assert_equal({ "plate_idx" => 0 }, source.calls.first.fetch(1))
  end

  def test_initial_submit_returns_before_its_worker_status_callback_begins
    callback_entered = Queue.new
    callback_release = Queue.new
    blocked_once = false
    callback = lambda do |_snapshot|
      next if blocked_once

      blocked_once = true
      callback_entered << true
      callback_release.pop
    end
    worker = build_worker(
      source: MemorySource.new({ "/demo" => gcode(1) }), on_status: callback
    ).start
    submitted = Queue.new
    submitter = Thread.new { submitted << worker.submit(hints: {}, local_path: "/demo") }

    job = Timeout.timeout(TIMEOUT) { submitted.pop }
    assert_instance_of BambuCompanion::ModelWorker::Job, job
    Timeout.timeout(TIMEOUT) { callback_entered.pop }
  ensure
    callback_release&.push(true)
    submitter&.join(TIMEOUT)
    worker&.stop
  end

  def test_stop_interrupts_an_uncooperative_download_and_cleans_tempfile
    ftps = UncooperativeFtps.new
    worker = build_worker(ftps_client: ftps).start
    worker.submit(hints: { file: "stuck.gcode" })
    path = Timeout.timeout(TIMEOUT) { ftps.destination.pop }
    assert_path_exists path

    Timeout.timeout(TIMEOUT) { worker.stop }
    Timeout.timeout(TIMEOUT) { ftps.finished.pop }

    refute_path_exists path
  ensure
    worker&.stop
  end

  def test_stop_called_from_worker_callback_does_not_join_itself
    result = Queue.new
    worker = nil
    callback = lambda do |snapshot|
      next unless snapshot[:status] == "ready"

      begin
        worker.stop
        result << :stopped
      rescue StandardError => error
        result << error
      end
    end
    worker = build_worker(
      source: MemorySource.new({ "/demo" => gcode(1) }), on_status: callback
    ).start
    worker.submit(hints: {}, local_path: "/demo")

    assert_equal :stopped, Timeout.timeout(TIMEOUT) { result.pop }
  ensure
    worker&.stop
  end

  def test_start_is_idempotent
    worker = build_worker

    assert_same worker, worker.start
    thread = worker.instance_variable_get(:@thread)
    assert_same worker, worker.start

    assert_same thread, worker.instance_variable_get(:@thread)
  ensure
    worker&.stop
  end

  def test_stop_is_idempotent
    worker = build_worker

    assert_same worker, worker.stop
    generation = worker.instance_variable_get(:@generation)
    queue_size = worker.instance_variable_get(:@queue).size
    assert_same worker, worker.stop

    assert_equal generation, worker.instance_variable_get(:@generation)
    assert_equal queue_size, worker.instance_variable_get(:@queue).size
  end

  def test_submit_after_stop_raises_without_mutating_state_or_queue
    worker = build_worker
    worker.stop
    state = worker.snapshot({})
    generation = worker.instance_variable_get(:@generation)
    queue_size = worker.instance_variable_get(:@queue).size

    error = assert_raises(BambuCompanion::ModelWorker::StoppedError) do
      worker.submit(hints: {}, local_path: "/late")
    end

    refute_respond_to error, :code
    assert_equal "Model worker has been stopped", error.message
    assert_equal state, worker.snapshot({})
    assert_equal generation, worker.instance_variable_get(:@generation)
    assert_equal queue_size, worker.instance_variable_get(:@queue).size
  end

  def test_stopped_error_from_reentrant_callback_is_not_swallowed
    worker = nil
    callback = lambda do |snapshot|
      next unless snapshot[:generation] == 1 && snapshot[:status] == "loading"

      worker.stop
      worker.submit(hints: {}, local_path: "/late")
    end
    worker = build_worker(
      source: MemorySource.new({ "/old" => gcode(1) }), on_status: callback
    )
    job = worker.submit(hints: {}, local_path: "/old")

    error = assert_raises(BambuCompanion::ModelWorker::StoppedError) do
      worker.process(job)
    end

    refute_respond_to error, :code
  ensure
    worker&.stop
  end

  def test_current_error_uses_stable_code_and_is_reflected_in_snapshot
    source = MemorySource.new({}, error_path: "/bad")
    statuses = StatusCollector.new
    worker = build_worker(source: source, on_status: statuses)
    job = worker.submit(hints: {}, local_path: "/bad")

    refute worker.process(job)
    snapshot = worker.snapshot({})
    assert_equal "error", snapshot[:status]
    assert_equal({ code: "source_failed", message: "source failed" }, snapshot[:error])
    assert_equal snapshot, statuses.snapshots.last
  end

  def test_error_snapshot_is_deeply_immutable
    source = Object.new
    source.define_singleton_method(:open) do |*, **|
      raise TestError.new(String.new("dynamic_code"), String.new("dynamic message"))
    end
    worker = build_worker(source: source)
    job = worker.submit(hints: {}, local_path: "/bad")

    refute worker.process(job)
    error = worker.snapshot({}).fetch(:error)

    assert_predicate error, :frozen?
    assert_predicate error.fetch(:code), :frozen?
    assert_predicate error.fetch(:message), :frozen?
  ensure
    worker&.stop
  end

  def test_z_progress_prefers_layer_and_clamps_layer_index
    geometry = geometry(layer_z: [0.2, 0.4, 0.6])

    assert_equal [0.4, "layer"], BambuCompanion::ZProgress.calculate(
      geometry, layer: 2, percent: 90
    )
    assert_equal [0.2, "layer"], BambuCompanion::ZProgress.calculate(
      geometry, "layer_num" => 0, "percent" => 90
    )
    assert_equal [0.6, "layer"], BambuCompanion::ZProgress.calculate(
      geometry, layer_num: 99, percent: 1
    )
  end

  def test_z_progress_uses_percent_when_layer_metadata_was_decimated
    model = geometry(
      bounds: { min_z: 0.0, max_z: 25_000.0 },
      layer_z: (0..12_500).map { |index| index * 2.0 },
      layer_z_exact: false
    )

    assert_equal [12_500.0, "estimated"], BambuCompanion::ZProgress.calculate(
      model, layer: 6_250, percent: 50
    )
  end

  def test_z_progress_interpolates_and_clamps_percent_to_bounds
    model = geometry(bounds: { min_z: 0.2, max_z: 10.2 })

    assert_equal [5.2, "estimated"], BambuCompanion::ZProgress.calculate(model, percent: 50)
    assert_equal [0.2, "estimated"], BambuCompanion::ZProgress.calculate(model, percent: -5)
    assert_equal [10.2, "estimated"], BambuCompanion::ZProgress.calculate(
      model, "percent" => "105"
    )
  end

  def test_z_progress_interpolation_avoids_overflow_and_remains_json_safe
    model = geometry(bounds: { min_z: -Float::MAX, max_z: Float::MAX })

    z, mode = BambuCompanion::ZProgress.calculate(model, percent: 50)

    assert_equal 0.0, z
    assert_equal "estimated", mode
    assert z.finite?
    assert_equal %({"zCurrent":0.0}), JSON.generate(zCurrent: z)
  end

  def test_nonfinite_layer_and_percent_values_fall_back_without_unsafe_snapshot_json
    model = geometry(layer_z: [0.2, 0.4])
    assert_equal [5.2, "estimated"], BambuCompanion::ZProgress.calculate(
      model, layer: Float::INFINITY, percent: 50
    )
    assert_equal [0.4, "layer"], BambuCompanion::ZProgress.calculate(
      model, layer: 2, percent: Float::NAN
    )
    assert_equal [nil, "unknown"], BambuCompanion::ZProgress.calculate(
      model, layer: Float::NAN, percent: Float::INFINITY
    )

    worker = build_worker(source: MemorySource.new({ "/demo" => gcode(1) }))
    job = worker.submit(hints: {}, local_path: "/demo")
    assert worker.process(job)
    snapshot = worker.snapshot(layer: Float::NAN, percent: Float::INFINITY)

    assert_nil snapshot[:z_current]
    assert_equal "unknown", snapshot[:z_mode]
    assert_equal "unknown", JSON.parse(JSON.generate(snapshot)).fetch("z_mode")
  end

  def test_z_progress_is_unknown_without_usable_layer_or_finite_bounds
    no_bounds = geometry(bounds: { min_z: nil, max_z: Float::INFINITY })

    assert_equal [nil, "unknown"], BambuCompanion::ZProgress.calculate(nil, layer: 1)
    assert_equal [nil, "unknown"], BambuCompanion::ZProgress.calculate(no_bounds, percent: 50)
    assert_equal [nil, "unknown"], BambuCompanion::ZProgress.calculate(geometry, {})
  end

  private

  def build_worker(ftps_client: nil, source: MemorySource.new({}),
                   parser: BambuCompanion::GcodeParser.new(max_segments: 2_000),
                   emitter: Emitter.new, on_status: StatusCollector.new)
    BambuCompanion::ModelWorker.new(
      ftps_client: ftps_client,
      source: source,
      parser: parser,
      emitter: emitter,
      on_status: on_status
    )
  end

  def file_source
    Object.new.tap do |source|
      source.define_singleton_method(:open) do |path, _hints, &block|
        File.open(path, "rb") { |io| block.call(io) }
      end
    end
  end

  def gcode(x)
    "G90\nM83\n;TYPE:WALL-OUTER\nG1 X0 Y0 Z0.2\nG1 X#{x} Y0 E1\n"
  end

  def geometry(bounds: { min_z: 0.2, max_z: 10.2 }, layer_z: [], layer_z_exact: true)
    BambuCompanion::Geometry.new(
      segments: [], bounds: bounds, layer_z: layer_z,
      layer_z_exact: layer_z_exact
    )
  end

  def drain_queue(queue)
    loop { queue.pop(true) }
  rescue ThreadError
    nil
  end
end
