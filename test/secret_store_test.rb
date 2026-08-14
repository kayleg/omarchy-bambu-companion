# frozen_string_literal: true

require_relative "test_helper"
require "bambu_companion/secret_store"
require "fileutils"
require "rbconfig"
require "stringio"
require "tmpdir"

class SecretStoreTest < Minitest::Test
  Result = Struct.new(:stdout, :stderr, :success?, :stdout_present?, keyword_init: true)

  class FakeWaiter
    attr_reader :join_timeouts, :pid, :value_calls

    def initialize(join_results:, pid: 12_345, status: Result.new(stdout: "", stderr: "", success?: false))
      @join_results = join_results.dup
      @pid = pid
      @status = status
      @join_timeouts = []
      @value_calls = 0
    end

    def join(timeout)
      @join_timeouts << timeout
      @join_results.shift ? self : nil
    end

    def value
      @value_calls += 1
      @status
    end
  end

  class InterruptingWaiter < FakeWaiter
    def initialize(**arguments)
      super
      @interrupted = false
    end

    def join(timeout)
      unless @interrupted
        @interrupted = true
        raise Interrupt
      end

      super
    end
  end

  class CleanupInterruptingWaiter < FakeWaiter
    def initialize(**arguments)
      super
      @join_calls = 0
    end

    def join(timeout)
      @join_calls += 1
      raise Interrupt if @join_calls == 2

      super
    end
  end

  def test_store_sends_secret_only_on_stdin
    calls = []
    runner = lambda do |argv, stdin_data: ""|
      calls << [argv, stdin_data]
      Result.new(stdout: "", stderr: "", success?: true)
    end
    store = BambuCompanion::SecretStore.new(
      runner: runner, executable_resolver: ->(_name) { "/usr/bin/secret-tool" }
    )

    assert store.store("SERIAL1", "secret-value")
    argv, stdin_data = calls.fetch(0)
    refute_includes argv.join(" "), "secret-value"
    assert_equal "secret-value", stdin_data
    assert_includes argv, "SERIAL1"
  end

  def test_lookup_clear_all_and_unavailable_storage
    responses = [
      Result.new(stdout: "stored-code\n", stderr: "", success?: true),
      Result.new(stdout: "", stderr: "", success?: true, stdout_present?: true),
      Result.new(stdout: "", stderr: "", success?: true),
      Result.new(stdout: "", stderr: "", success?: true)
    ]
    store = BambuCompanion::SecretStore.new(
      runner: ->(_argv, **) { responses.shift },
      executable_resolver: ->(_name) { "/usr/bin/secret-tool" }
    )

    assert_equal "stored-code", store.lookup("SERIAL1")
    assert store.clear_all

    missing = BambuCompanion::SecretStore.new(
      runner: ->(*) { raise "must not run" },
      executable_resolver: ->(_name) { nil }
    )
    refute missing.available?
    assert_nil missing.lookup("SERIAL1")
    refute missing.store("SERIAL1", "x")
    refute missing.clear_all
  end

  def test_clear_all_unlocks_then_deletes_every_plugin_credential
    calls = []
    responses = [
      Result.new(stdout: "", stderr: "", success?: true, stdout_present?: true),
      Result.new(stdout: "", stderr: "", success?: true),
      Result.new(stdout: "", stderr: "", success?: true)
    ]
    store = BambuCompanion::SecretStore.new(
      runner: lambda { |argv, stdin_data: "", capture_stdout: true|
        calls << [argv, stdin_data, capture_stdout]
        responses.shift
      },
      executable_resolver: ->(_name) { "/usr/bin/secret-tool" }
    )

    assert_respond_to store, :clear_all
    assert store.clear_all
    plugin_filter = ["application", BambuCompanion::SecretStore::PLUGIN_ID]
    assert_equal ["/usr/bin/secret-tool", "search", "--all", "--unlock", *plugin_filter], calls[0][0]
    assert_equal "", calls[0][1]
    assert_equal false, calls[0][2]
    assert_equal ["/usr/bin/secret-tool", "clear", *plugin_filter], calls[1][0]
    assert_equal "", calls[1][1]
    assert_equal 3, calls.length
    assert_equal ["/usr/bin/secret-tool", "search", "--all", *plugin_filter], calls[2][0]
    assert_equal false, calls[2][2]
  end

  def test_clear_all_does_not_claim_success_when_locked_items_cannot_be_removed
    calls = []
    responses = [
      Result.new(stdout: "", stderr: "", success?: true, stdout_present?: true),
      Result.new(stdout: "", stderr: "", success?: false)
    ]
    store = BambuCompanion::SecretStore.new(
      runner: lambda { |argv, **|
        calls << argv
        responses.shift
      },
      executable_resolver: ->(_name) { "/usr/bin/secret-tool" }
    )

    refute store.clear_all
    assert_equal 2, calls.length
    assert_equal "search", calls.first.fetch(1)
    assert_equal "clear", calls.last.fetch(1)
  end

  def test_clear_all_detects_a_locked_credential_remaining_after_partial_clear
    calls = []
    responses = [
      Result.new(stdout: "", stderr: "", success?: true, stdout_present?: true),
      Result.new(stdout: "", stderr: "", success?: true),
      Result.new(stdout: "", stderr: "", success?: true, stdout_present?: true)
    ]
    store = BambuCompanion::SecretStore.new(
      runner: lambda { |argv, **|
        calls << argv
        responses.shift
      },
      executable_resolver: ->(_name) { "/usr/bin/secret-tool" }
    )

    refute store.clear_all
    operations = calls.map { |argv| argv.fetch(1) }
    assert_equal %w[search clear search], operations
    refute_includes calls.last, "--unlock"
  end

  def test_clear_all_succeeds_without_delete_when_no_credentials_exist
    calls = []
    responses = [
      Result.new(stdout: "", stderr: "", success?: true, stdout_present?: false),
      Result.new(stdout: "", stderr: "", success?: false)
    ]
    store = BambuCompanion::SecretStore.new(
      runner: lambda { |argv, **|
        calls << argv
        responses.shift
      },
      executable_resolver: ->(_name) { "/usr/bin/secret-tool" }
    )

    assert store.clear_all
    assert_equal 1, calls.length
  end

  def test_runner_can_drain_stdout_without_retaining_secrets
    parameters = BambuCompanion::SecretStore.instance_method(:run_command).parameters
    assert_includes parameters, [:key, :capture_stdout]

    process_stdout = StringIO.new("secret-that-must-not-be-retained")
    store = BambuCompanion::SecretStore.new(
      executable_resolver: ->(_name) { "/usr/bin/secret-tool" },
      process_spawner: lambda do |_argv|
        status = Result.new(stdout: "", stderr: "", success?: true)
        [StringIO.new, process_stdout, StringIO.new,
         FakeWaiter.new(join_results: [true], status: status)]
      end
    )

    result = store.send(:run_command, ["secret-tool"], stdin_data: "", capture_stdout: false)

    assert result.success?
    assert_empty result.stdout
    assert result.stdout_present?
    assert_equal process_stdout.size, process_stdout.pos
  end

  def test_rejects_oversized_secrets_from_lookup_and_store
    calls = []
    store = BambuCompanion::SecretStore.new(
      runner: lambda { |argv, stdin_data: ""|
        calls << [argv, stdin_data]
        Result.new(stdout: "x" * 257, stderr: "", success?: true)
      },
      executable_resolver: ->(_name) { "/usr/bin/secret-tool" }
    )

    assert_nil store.lookup("SERIAL1")
    refute store.store("SERIAL1", "x" * 257)
    assert_equal 1, calls.length
  end

  def test_default_resolver_ignores_relative_path_entries
    Dir.mktmpdir do |dir|
      executable = File.join(dir, "secret-tool")
      File.write(executable, "#!/bin/sh\n")
      FileUtils.chmod(0o700, executable)
      store = BambuCompanion::SecretStore.new
      original_path = ENV.fetch("PATH", nil)

      begin
        Dir.chdir(dir) do
          ENV["PATH"] = "."
          assert_nil store.send(:find_executable, "secret-tool")
          ENV["PATH"] = dir
          assert_equal executable, store.send(:find_executable, "secret-tool")
        end
      ensure
        original_path ? ENV["PATH"] = original_path : ENV.delete("PATH")
      end
    end
  end

  def test_default_runner_bounds_captured_process_output_while_draining_it
    oversized = "x" * (BambuCompanion::SecretStore::MAX_CAPTURE_BYTES * 2)
    process_stderr = StringIO.new(oversized)
    store = BambuCompanion::SecretStore.new(
      executable_resolver: ->(_name) { "/usr/bin/secret-tool" },
      process_spawner: lambda do |_argv|
        [StringIO.new, StringIO.new(oversized), process_stderr,
         FakeWaiter.new(join_results: [true])]
      end
    )

    result = store.send(:run_command, ["secret-tool"], stdin_data: "")

    assert_operator result.stdout.bytesize, :<=, BambuCompanion::SecretStore::MAX_CAPTURE_BYTES
    refute_respond_to result, :stderr
    assert_equal process_stderr.size, process_stderr.pos
  end

  def test_uses_the_resolved_secret_tool_path_for_all_commands
    calls = []
    resolver_calls = 0
    responses = [
      Result.new(stdout: "stored-code\n", stderr: "", success?: true),
      Result.new(stdout: "", stderr: "", success?: true),
      Result.new(stdout: "", stderr: "", success?: true, stdout_present?: true),
      Result.new(stdout: "", stderr: "", success?: true),
      Result.new(stdout: "", stderr: "", success?: true)
    ]
    path = "/custom/bin/secret-tool"
    store = BambuCompanion::SecretStore.new(
      runner: lambda { |argv, stdin_data: "", **|
        calls << [argv, stdin_data]
        responses.shift
      },
      executable_resolver: ->(_name) { resolver_calls += 1; path }
    )

    assert_equal "stored-code", store.lookup("SERIAL1")
    assert store.store("SERIAL1", "secret-value")
    assert store.clear_all
    assert_equal([path, path, path, path, path], calls.map { |argv, _stdin_data| argv.first })
    assert_equal 1, resolver_calls
  end

  def test_default_runner_bounds_wait_terminates_kills_and_reaps_a_stuck_process
    process_stdin = StringIO.new
    process_stdout = StringIO.new
    process_stderr = StringIO.new
    waiter = FakeWaiter.new(join_results: [false, false, true])
    signals = []
    spawned_argv = nil
    store = BambuCompanion::SecretStore.new(
      executable_resolver: ->(_name) { "/usr/bin/secret-tool" },
      timeout_seconds: 0.01,
      terminate_grace_seconds: 0.02,
      process_spawner: lambda do |argv|
        spawned_argv = argv
        [process_stdin, process_stdout, process_stderr, waiter]
      end,
      process_signaler: ->(signal, pid) { signals << [signal, pid] }
    )

    refute store.store("SERIAL1", "secret-value")

    refute_includes spawned_argv.join(" "), "secret-value"
    assert_equal "secret-value", process_stdin.string
    assert_equal [0.01, 0.02, 0.02], waiter.join_timeouts
    assert_equal [["TERM", waiter.pid], ["KILL", waiter.pid]], signals
    assert_equal 1, waiter.value_calls
    assert process_stdin.closed?
    assert process_stdout.closed?
    assert process_stderr.closed?
  end

  def test_rejects_nonfinite_timeouts
    assert_raises(ArgumentError) do
      BambuCompanion::SecretStore.new(timeout_seconds: Float::INFINITY)
    end
    assert_raises(ArgumentError) do
      BambuCompanion::SecretStore.new(terminate_grace_seconds: Float::INFINITY)
    end
  end

  def test_default_runner_returns_promptly_and_reaps_a_real_stuck_process
    child_pid = nil
    store = BambuCompanion::SecretStore.new(
      executable_resolver: ->(_name) { "/usr/bin/secret-tool" },
      timeout_seconds: 0.05,
      terminate_grace_seconds: 0.05,
      process_spawner: lambda do |_argv|
        handles = Open3.popen3(RbConfig.ruby, "-e", "sleep 30")
        child_pid = handles.last.pid
        handles
      end
    )

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    refute store.store("SERIAL1", "secret-value")
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    assert_operator elapsed, :<, 1.0
    assert_raises(Errno::ESRCH) { Process.kill(0, child_pid) }
  ensure
    if child_pid
      begin
        Process.kill("KILL", child_pid)
        Process.wait(child_pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
  end

  def test_interruption_terminates_and_reaps_the_spawned_process_before_propagating
    process_stdin = StringIO.new
    process_stdout = StringIO.new
    process_stderr = StringIO.new
    waiter = InterruptingWaiter.new(join_results: [true])
    signals = []
    store = BambuCompanion::SecretStore.new(
      executable_resolver: ->(_name) { "/usr/bin/secret-tool" },
      timeout_seconds: 0.01,
      terminate_grace_seconds: 0.02,
      process_spawner: lambda do |_argv|
        [process_stdin, process_stdout, process_stderr, waiter]
      end,
      process_signaler: ->(signal, pid) { signals << [signal, pid] }
    )

    assert_raises(Interrupt) { store.store("SERIAL1", "secret-value") }

    assert_equal [["TERM", waiter.pid]], signals
    assert_equal 1, waiter.value_calls
    assert process_stdin.closed?
    assert process_stdout.closed?
    assert process_stderr.closed?
  end

  def test_interruption_during_terminate_grace_still_kills_and_reaps_before_propagating
    process_stdin = StringIO.new
    process_stdout = StringIO.new
    process_stderr = StringIO.new
    waiter = CleanupInterruptingWaiter.new(join_results: [false, true])
    signals = []
    store = BambuCompanion::SecretStore.new(
      executable_resolver: ->(_name) { "/usr/bin/secret-tool" },
      timeout_seconds: 0.01,
      terminate_grace_seconds: 0.02,
      process_spawner: lambda do |_argv|
        [process_stdin, process_stdout, process_stderr, waiter]
      end,
      process_signaler: ->(signal, pid) { signals << [signal, pid] }
    )

    assert_raises(Interrupt) { store.store("SERIAL1", "secret-value") }

    assert_equal [["TERM", waiter.pid], ["KILL", waiter.pid]], signals
    assert_equal 1, waiter.value_calls
    assert process_stdin.closed?
    assert process_stdout.closed?
    assert process_stderr.closed?
  end
end
