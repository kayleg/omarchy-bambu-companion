# frozen_string_literal: true

require_relative "model_worker"

module BambuCompanion
  class DemoSession
    MAX_SEGMENTS = 20_000
    PRINTER = {
      connected: true,
      stale: false,
      lastUpdate: "STATIC SNAPSHOT",
      gcodeState: "RUNNING",
      subtaskName: "OMARCHY LOGO",
      percent: 52,
      nozzleTemp: 210.0,
      nozzleTargetTemp: 210.0,
      bedTemp: 60.0,
      bedTargetTemp: 60.0,
      layer: 17,
      totalLayers: 33,
      remainingMinutes: 35,
      speedLevel: 2,
      speedMagnitude: 100,
      wifiSignal: "LOCAL",
      coolingFanSpeed: 8.0,
      heatbreakFanSpeed: 6.0
    }.freeze

    def initialize(path:, session_id:, emitter:, worker_factory: nil)
      @path = File.expand_path(path)
      @emitter = TaggedEmitter.new(emitter, Integer(session_id))
      @mutex = Mutex.new
      @stopped = false
      factory = worker_factory || ->(**arguments) { ModelWorker.for_local(**arguments) }
      @worker = factory.call(
        max_segments: MAX_SEGMENTS,
        emitter: @emitter,
        on_status: ->(*) { emit_state }
      )
    end

    def start
      return self unless active?

      @worker.submit(hints: {}, local_path: @path)
      emit_state
      @worker.start if active?
      self
    rescue StandardError
      stop
      raise
    end

    def refresh_preview
      return false unless active?

      @worker.submit(hints: {}, local_path: @path)
      true
    rescue ModelWorker::StoppedError
      false
    end

    def stop
      worker = @mutex.synchronize do
        return self if @stopped

        @stopped = true
        @worker
      end
      worker.stop
      self
    end

    private

    def active?
      @mutex.synchronize { !@stopped }
    end

    def emit_state
      return false unless active?

      @emitter.emit(
        "demo_state", printer: PRINTER,
        model: ModelWorker.ipc_payload(@worker.snapshot(PRINTER))
      )
    rescue ModelWorker::StoppedError
      false
    end

    class TaggedEmitter
      def initialize(emitter, session_id)
        @emitter = emitter
        @session_id = session_id
      end

      def emit(event, payload = {})
        @emitter.emit(event, payload.merge(demoSession: @session_id))
      end
    end
  end
end
