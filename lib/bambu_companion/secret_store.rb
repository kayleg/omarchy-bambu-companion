# frozen_string_literal: true

require "open3"

module BambuCompanion
  class SecretStore
    PLUGIN_ID = "io.github.ypmrg.bambu-companion"
    PLUGIN_ATTRIBUTES = ["application", PLUGIN_ID].freeze
    LABEL = "Bambu Companion LAN access code"
    DEFAULT_TIMEOUT_SECONDS = 3.0
    DEFAULT_TERMINATE_GRACE_SECONDS = 0.25
    MAX_SECRET_BYTES = 256
    MAX_CAPTURE_BYTES = 4096
    READ_CHUNK_BYTES = 4096

    CommandResult = Data.define(:stdout, :success?, :stdout_present?)

    def initialize(runner: nil, executable_resolver: nil,
                   timeout_seconds: DEFAULT_TIMEOUT_SECONDS,
                   terminate_grace_seconds: DEFAULT_TERMINATE_GRACE_SECONDS,
                   process_spawner: nil, process_signaler: nil)
      @timeout_seconds = Float(timeout_seconds)
      @terminate_grace_seconds = Float(terminate_grace_seconds)
      unless @timeout_seconds.finite? && @timeout_seconds.positive?
        raise ArgumentError, "timeout_seconds must be finite and positive"
      end
      unless @terminate_grace_seconds.finite? && @terminate_grace_seconds.positive?
        raise ArgumentError, "terminate_grace_seconds must be finite and positive"
      end

      @process_spawner = process_spawner || method(:spawn_process)
      @process_signaler = process_signaler || Process.method(:kill)
      @runner = runner || method(:run_command)
      @executable_resolver = executable_resolver || method(:find_executable)
    end

    def available?
      !secret_tool_path.nil?
    end

    def lookup(serial)
      path = secret_tool_path
      return nil unless path

      result = @runner.call([path, "lookup", *attributes(serial)], stdin_data: "")
      return nil unless result.success?

      secret = result.stdout.to_s.sub(/\r?\n\z/, "")
      secret if valid_secret?(secret)
    rescue SystemCallError
      nil
    end

    def store(serial, secret)
      path = secret_tool_path
      secret = String(secret)
      return false unless path && valid_secret?(secret)

      result = @runner.call(
        [path, "store", "--label=#{LABEL}", *attributes(serial)],
        stdin_data: secret
      )
      result.success?
    rescue SystemCallError
      false
    end

    def clear_all
      path = secret_tool_path
      return false unless path

      unlocked = search_all(path, unlock: true)
      return false unless unlocked.success?
      return true unless unlocked.stdout_present?

      cleared = @runner.call(
        [path, "clear", *PLUGIN_ATTRIBUTES], stdin_data: ""
      )
      return false unless cleared.success?

      remaining = search_all(path)
      remaining.success? && !remaining.stdout_present?
    rescue SystemCallError
      false
    end

    private

    def secret_tool_path
      return @secret_tool_path if defined?(@secret_tool_path)

      @secret_tool_path = @executable_resolver.call("secret-tool")
    end

    def attributes(serial)
      [*PLUGIN_ATTRIBUTES, "serial", String(serial)]
    end

    def search_all(path, unlock: false)
      argv = [path, "search", "--all"]
      argv << "--unlock" if unlock
      @runner.call(
        [*argv, *PLUGIN_ATTRIBUTES], stdin_data: "", capture_stdout: false
      )
    end

    def valid_secret?(secret)
      !secret.empty? && secret.bytesize <= MAX_SECRET_BYTES
    end

    def run_command(argv, stdin_data:, capture_stdout: true)
      process_stdin = process_stdout = process_stderr = waiter = nil
      stdout_reader = stderr_reader = nil
      cleanup_started = false
      cleanup_completed = false
      process_reaped = false

      process_stdin, process_stdout, process_stderr, waiter = @process_spawner.call(argv)
      stdout_reader = read_in_background(process_stdout, capture: capture_stdout)
      stderr_reader = read_in_background(process_stderr)
      process_stdin.write(stdin_data)
      safely_close(process_stdin)

      status = wait_for(waiter, @timeout_seconds)
      process_reaped = !status.nil?
      unless status
        cleanup_started = true
        status = terminate_and_reap(waiter)
        cleanup_completed = true
        process_reaped = !status.nil?
      end

      stdout_result = collect_reader(stdout_reader, process_stdout)
      collect_reader(stderr_reader, process_stderr)
      CommandResult.new(
        stdout: capture_stdout ? stdout_result : "",
        success?: !!status&.success?, stdout_present?: !stdout_result.empty?
      )
    rescue StandardError
      if waiter && !cleanup_started
        cleanup_started = true
        process_reaped = !terminate_and_reap(waiter).nil?
        cleanup_completed = true
      end
      CommandResult.new(stdout: "", success?: false, stdout_present?: false)
    ensure
      Thread.handle_interrupt(Interrupt => :never) do
        if waiter && !process_reaped && !cleanup_completed
          begin
            send_term = !cleanup_started
            cleanup_started = true
            process_reaped = !terminate_and_reap(waiter, send_term: send_term).nil?
            cleanup_completed = true
          rescue StandardError
            nil
          end
        end
        safely_close(process_stdin)
        safely_close(process_stdout)
        safely_close(process_stderr)
        stop_reader(stdout_reader)
        stop_reader(stderr_reader)
      end
    end

    def spawn_process(argv)
      Open3.popen3(*argv)
    end

    def read_in_background(io, capture: true)
      Thread.new { read_bounded(io, capture: capture) }
    end

    def read_bounded(io, capture: true)
      captured = String.new(encoding: Encoding::BINARY)
      saw_output = false
      loop do
        chunk = io.readpartial(READ_CHUNK_BYTES)
        saw_output = true unless chunk.empty?
        next unless capture

        remaining = MAX_CAPTURE_BYTES - captured.bytesize
        captured << chunk.byteslice(0, remaining) if remaining.positive?
      end
    rescue EOFError
      capture ? captured : (saw_output ? "1" : "")
    rescue StandardError
      ""
    end

    def wait_for(waiter, seconds)
      waiter.join(seconds) ? waiter.value : nil
    end

    def terminate_and_reap(waiter, send_term: true)
      if send_term
        safely_signal("TERM", waiter.pid)
        status = wait_for(waiter, @terminate_grace_seconds)
        return status if status
      end

      safely_signal("KILL", waiter.pid)
      wait_for(waiter, @terminate_grace_seconds)
    end

    def safely_signal(signal, pid)
      @process_signaler.call(signal, pid)
    rescue StandardError
      nil
    end

    def collect_reader(reader, io)
      return "" unless reader
      return reader.value if reader.join(@terminate_grace_seconds)

      safely_close(io)
      return reader.value if reader.join(@terminate_grace_seconds)

      stop_reader(reader)
      ""
    rescue StandardError
      ""
    end

    def stop_reader(reader)
      return unless reader&.alive?

      reader.kill
      reader.join(@terminate_grace_seconds)
    end

    def safely_close(io)
      io&.close unless io&.closed?
    rescue IOError, SystemCallError
      nil
    end

    def find_executable(name)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).select { |dir| File.absolute_path?(dir) }
         .map { |dir| File.join(dir, name) }
         .find { |path| File.file?(path) && File.executable?(path) }
    end
  end
end
