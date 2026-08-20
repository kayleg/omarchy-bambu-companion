# frozen_string_literal: true

require_relative "test_helper"
require "bambu_companion/demo_session"

class DemoSessionTest < Minitest::Test
  class Emitter
    attr_reader :events

    def initialize
      @events = []
    end

    def emit(event, payload = {})
      @events << [event, payload]
      true
    end
  end

  class Worker
    attr_reader :arguments, :submissions

    def initialize(arguments)
      @arguments = arguments
      @submissions = []
      @stopped = false
    end

    def start = self
    def stop = @stopped = true
    def stopped? = @stopped

    def submit(**arguments)
      @submissions << arguments
    end

    def snapshot(printer)
      {
        status: "ready", generation: 1, segment_count: 42,
        z_current: printer.fetch(:layer) * 0.3, z_mode: "layer",
        error: nil, load_phase: "", load_progress: nil,
        loaded_bytes: 0, total_bytes: 0
      }
    end
  end

  def setup
    @emitter = Emitter.new
    @workers = []
    @factory = lambda do |**arguments|
      @workers << Worker.new(arguments)
      @workers.last
    end
    @session = BambuCompanion::DemoSession.new(
      path: "/tmp/omarchy.gcode", session_id: 12,
      emitter: @emitter, worker_factory: @factory
    )
  end

  def test_uses_the_local_model_pipeline_and_publishes_a_mid_print_snapshot
    @session.start
    worker = @workers.fetch(0)

    assert_equal [{ hints: {}, local_path: "/tmp/omarchy.gcode" }], worker.submissions
    assert_equal BambuCompanion::DemoSession::MAX_SEGMENTS,
                 worker.arguments.fetch(:max_segments)

    worker.arguments.fetch(:emitter).emit("geometry_begin", generation: 1)

    geometry = @emitter.events.find { |event,| event == "geometry_begin" }.last
    state = @emitter.events.find { |event,| event == "demo_state" }.last
    assert_equal 12, geometry.fetch(:demoSession)
    assert_equal 12, state.fetch(:demoSession)
    assert_equal "OMARCHY LOGO", state.dig(:printer, :subtaskName)
    assert_equal 52, state.dig(:printer, :percent)
    assert_equal 17, state.dig(:printer, :layer)
    assert_equal 33, state.dig(:printer, :totalLayers)
    assert_equal 5.1, state.dig(:model, :zCurrent)
  end

  def test_refresh_reuses_the_bundled_file_and_stop_blocks_late_publication
    @session.start
    assert @session.refresh_preview
    assert_equal 2, @workers.first.submissions.length
    @emitter.events.clear

    @session.stop
    refute @session.refresh_preview
    assert @workers.first.stopped?
    @workers.first.arguments.fetch(:on_status).call
    assert_empty @emitter.events
  end
end
