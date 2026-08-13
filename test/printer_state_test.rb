# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "bambu_companion/printer_state"

class PrinterStateTest < Minitest::Test
  def setup
    @state = BambuCompanion::PrinterState.new(clock: -> { Time.utc(2026, 8, 12, 12, 0, 0) })
  end

  def test_merges_partial_reports_without_zeroing_absent_values
    first = @state.update("print" => {
      "nozzle_temper" => 215.25, "bed_temper" => 60,
      "mc_percent" => 12, "gcode_state" => "PREPARE"
    })
    second = @state.update("print" => { "mc_percent" => 13 })

    assert_equal 215.25, second.snapshot.fetch(:nozzle_temp)
    assert_equal 60.0, second.snapshot.fetch(:bed_temp)
    assert_equal 13, second.snapshot.fetch(:percent)
    refute second.load_model
    assert_equal "2026-08-12T12:00:00Z", first.snapshot.fetch(:last_update)
  end

  def test_exposes_live_print_telemetry_for_the_detailed_panel
    update = @state.update("print" => {
      "nozzle_target_temper" => 220, "bed_target_temper" => 65,
      "mc_remaining_time" => 6, "spd_lvl" => 2, "spd_mag" => 100,
      "wifi_signal" => "-49dBm", "cooling_fan_speed" => "11",
      "heatbreak_fan_speed" => "10"
    })

    assert_equal 220.0, update.snapshot.fetch(:nozzle_target_temp)
    assert_equal 65.0, update.snapshot.fetch(:bed_target_temp)
    assert_equal 6, update.snapshot.fetch(:remaining_minutes)
    assert_equal 2, update.snapshot.fetch(:speed_level)
    assert_equal 100, update.snapshot.fetch(:speed_magnitude)
    assert_equal "-49dBm", update.snapshot.fetch(:wifi_signal)
    assert_equal 11.0, update.snapshot.fetch(:cooling_fan_speed)
    assert_equal 10.0, update.snapshot.fetch(:heatbreak_fan_speed)
  end

  def test_rejects_nonfinite_numbers_and_oversized_report_strings
    update = @state.update("print" => {
      "nozzle_temper" => Float::INFINITY,
      "bed_temper" => -Float::INFINITY,
      "subtask_name" => "x" * 4097
    })

    assert_nil update.snapshot[:nozzle_temp]
    assert_nil update.snapshot[:bed_temp]
    assert_nil update.snapshot[:subtask_name]
    JSON.generate(update.snapshot)
  end

  def test_detects_running_transition_and_late_job_identity_once
    @state.update("print" => { "gcode_state" => "IDLE" })
    started = @state.update("print" => { "gcode_state" => "RUNNING" })
    named = @state.update("print" => { "subtask_name" => "benchy.gcode.3mf", "plate_idx" => 0 })
    repeated = @state.update("print" => { "mc_percent" => 1 })

    assert started.load_model
    assert named.load_model
    refute repeated.load_model
    refute_respond_to named, :job_key
  end

  def test_progressive_identity_enrichment_does_not_reload_the_same_running_job
    @state.update("print" => { "gcode_state" => "IDLE" })
    started = @state.update("print" => { "gcode_state" => "RUNNING" })
    named = @state.update("print" => { "subtask_name" => "benchy.gcode.3mf" })
    plated = @state.update("print" => { "plate_idx" => 0 })
    identified = @state.update("print" => { "task_id" => "task-42" })

    assert started.load_model
    assert named.load_model
    refute plated.load_model
    refute identified.load_model
  end

  def test_changed_identity_detects_a_new_job_while_still_running
    @state.update("print" => {
      "gcode_state" => "RUNNING", "task_id" => "task-1",
      "subtask_name" => "first.gcode.3mf"
    })

    changed = @state.update("print" => {
      "task_id" => "task-2", "subtask_name" => "second.gcode.3mf"
    })

    assert changed.load_model
  end

  def test_stable_id_dominates_changes_to_weak_identity_hints
    @state.update("print" => {
      "gcode_state" => "RUNNING", "task_id" => "task-1",
      "subtask_name" => "draft"
    })

    renamed = @state.update("print" => { "subtask_name" => "final.gcode.3mf" })

    refute renamed.load_model
  end

  def test_first_stable_id_dominates_simultaneous_weak_hint_enrichment
    @state.update("print" => { "gcode_state" => "RUNNING", "subtask_name" => "draft" })

    identified = @state.update("print" => {
      "task_id" => "task-1", "subtask_name" => "final.gcode.3mf"
    })

    refute identified.load_model
  end

  def test_weak_identity_change_detects_new_job_when_no_stable_id_exists
    @state.update("print" => { "gcode_state" => "RUNNING", "subtask_name" => "first.gcode.3mf" })

    changed = @state.update("print" => { "subtask_name" => "second.gcode.3mf" })

    assert changed.load_model
  end

  def test_finished_job_then_same_file_running_again_reloads_the_model
    first = @state.update("print" => {
      "gcode_state" => "RUNNING", "subtask_name" => "repeat.gcode.3mf"
    })
    finished = @state.update("print" => { "gcode_state" => "FINISH" })
    restarted = @state.update("print" => {
      "gcode_state" => "RUNNING", "subtask_name" => "repeat.gcode.3mf"
    })

    assert first.load_model
    refute finished.load_model
    assert restarted.load_model
  end

  def test_mutating_a_snapshot_string_does_not_change_internal_state
    update = @state.update("print" => { "gcode_state" => "RUNNING", "task_id" => "task-1" })

    assert_raises(FrozenError) { update.snapshot.fetch(:gcode_state).replace("IDLE") }

    assert_equal "RUNNING", @state.snapshot.fetch(:gcode_state)
    refute @state.update("print" => { "mc_percent" => 1 }).load_model
  end

  def test_connection_marks_cached_data_stale
    @state.connected!
    refute @state.snapshot.fetch(:stale)
    @state.disconnected!
    assert @state.snapshot.fetch(:stale)
  end
end
