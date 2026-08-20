# frozen_string_literal: true

require "digest"
require_relative "config"
require_relative "ipc"
require_relative "printer_connection"
require_relative "secret_store"
require_relative "tls_certificate"

module BambuCompanion
  class Application
    PROTOCOL = 1
    MAX_IPC_LINE_BYTES = IpcLineFramer::DEFAULT_MAX_LINE_BYTES
    MAX_ACCESS_CODE_BYTES = SecretStore::MAX_SECRET_BYTES
    THREAD_JOIN_SECONDS = 0.5

    def self.installation_id(root = File.expand_path("../..", __dir__))
      candidates = [root, File.join(root, ".git"), File.join(root, ".git", "config")]
      identity = candidates.filter_map do |path|
        stat = File.stat(path)
        [stat.dev, stat.ino]
      rescue SystemCallError
        nil
      end.flatten.join(":")
      Digest::SHA256.hexdigest(identity)
    end

    def initialize(input: $stdin, output: $stdout, secret_store: SecretStore.new,
                   mqtt_factory: nil, worker_factory: nil,
                   outbound_capacity: AsyncIpcEmitter::DEFAULT_CAPACITY,
                   writer_join_seconds: AsyncIpcEmitter::DEFAULT_JOIN_SECONDS,
                   monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                   installation_id: self.class.installation_id,
                   tls_probe: TlsProbe.new)
      @input = input
      @secret_store = secret_store
      @mqtt_factory = mqtt_factory
      @worker_factory = worker_factory
      @installation_id = String(installation_id)
      @monotonic_clock = monotonic_clock
      @tls_probe = tls_probe
      @control_mutex = Mutex.new
      @publication_mutex = Mutex.new
      @configuration_id = 0
      @sequence = 0
      @shutdown = false
      @run_thread = nil
      @config = nil
      @secret = nil
      @connection = nil
      @tls_probe_generation = 0
      @tls_probe_thread = nil
      @emitter = AsyncIpcEmitter.new(
        io: output,
        secret_provider: -> { @control_mutex.synchronize { @secret } },
        capacity: outbound_capacity,
        join_seconds: writer_join_seconds,
        on_failure: method(:handle_output_failure)
      )
    end

    def run
      Thread.handle_interrupt(IpcOutputError => :never, Interrupt => :never) do
        begin
          Thread.handle_interrupt(IpcOutputError => :immediate, Interrupt => :immediate) do
            @control_mutex.synchronize { @run_thread = Thread.current }
            @emitter.emit(
              "hello", protocol: PROTOCOL, secretStorage: "gnome-keyring",
              installationId: @installation_id
            )
            IpcLineFramer.new(@input, max_line_bytes: MAX_IPC_LINE_BYTES).each do |line|
              handle_line(line)
              break if shutdown_requested?
            end
          end
        ensure
          begin
            shutdown
          ensure
            @control_mutex.synchronize do
              @run_thread = nil if @run_thread.equal?(Thread.current)
            end
          end
        end
      end
    end

    def handle(raw_command)
      command = normalize_command(raw_command)
      case command["op"]
      when "configure" then configure(command)
      when "set_secret" then set_secret(command)
      when "clear_secret" then clear_secret(command)
      when "refresh_model" then refresh_model
      when "probe_tls" then probe_tls(command)
      when "shutdown" then request_shutdown
      else
        emit_error(
          scope: "config", code: "unknown_op",
          message: "Unknown IPC operation", retryable: false
        )
      end
    rescue ConfigError => error
      emit_error(
        scope: "config", code: "invalid_config", message: error.message,
        retryable: false
      )
    end

    private

    def handle_line(line)
      raise IpcError if line.equal?(IpcLineFramer::OVERSIZED)

      handle(IpcReader.parse(line))
    rescue IpcError
      emit_error(
        scope: "config", code: "invalid_ipc", message: "Invalid IPC command",
        retryable: true
      )
    rescue IpcOutputError
      raise
    rescue StandardError => error
      emit_error(
        scope: "internal", code: "command_failed", message: error.message,
        retryable: true
      )
    end

    def normalize_command(command)
      command.to_h.each_with_object({}) do |(key, value), normalized|
        normalized[String(key)] = value
      end
    rescue NoMethodError, TypeError
      raise ConfigError, "IPC command must be an object"
    end

    def supported_protocol?(command)
      return true if command["protocol"] == PROTOCOL

      emit_error(
        scope: "config", code: "unsupported_protocol",
        message: "Unsupported IPC protocol", retryable: false
      )
      false
    end

    def configure(command)
      return unless supported_protocol?(command)

      candidate = Config.from_h(command["config"] || {})
      cancel_tls_probe
      configuration_id = replace_configuration(candidate)
      return unless configuration_id

      found = lookup_secret(candidate.serial)
      if !found.is_a?(String) || found.empty? || found.bytesize > MAX_ACCESS_CODE_BYTES
        return unless set_current_secret(configuration_id, nil)

        available = storage_available?
        publish_configuration(configuration_id) do
          @emitter.emit("secret_required", storageAvailable: available)
        end
        return
      end

      return unless set_current_secret(configuration_id, String(found))

      publish_configuration(configuration_id) do
        @emitter.emit("secret_status", stored: true)
      end
      unless candidate.trusted_tls?
        publish_configuration(configuration_id) { @emitter.emit("tls_required") }
        return
      end

      start_connection(configuration_id)
    end

    def probe_tls(command)
      return unless supported_protocol?(command)

      request_id = command["requestId"]
      unless request_id.is_a?(Integer) && request_id.between?(0, 2_147_483_647)
        raise ConfigError, "requestId is invalid"
      end

      config = Config.from_h(command["config"] || {})
      start_tls_probe(config, request_id)
    end

    def set_secret(command)
      configuration_id, config = current_configuration
      unless config
        emit_error(
          scope: "secret", code: "invalid_state",
          message: "A printer configuration is required", retryable: false
        )
        return
      end

      value = command["accessCode"]
      raise ConfigError, "LAN access code is empty" unless value.is_a?(String) && !value.strip.empty?

      secret = value.strip
      raise ConfigError, "LAN access code is too long" if secret.bytesize > MAX_ACCESS_CODE_BYTES

      persist = command.fetch("persist", true)
      raise ConfigError, "persist must be boolean" unless [true, false].include?(persist)

      replacement = restart_connection(configuration_id)
      return unless replacement

      configuration_id, config = replacement
      return unless set_current_secret(configuration_id, secret)

      stored = persist ? store_secret(config.serial, secret) : false
      publish_configuration(configuration_id) do
        @emitter.emit("secret_status", stored: !!stored)
      end
      start_connection(configuration_id)
    end

    def clear_secret(command)
      request_id = command["requestId"]
      valid_request_id = request_id.nil? || (request_id.is_a?(Integer) &&
        request_id.between?(0, 2_147_483_647))
      raise ConfigError, "requestId is invalid" unless valid_request_id

      configuration_id, config = current_configuration
      unless config
        payload = {
          scope: "secret", code: "invalid_state",
          message: "A printer configuration is required", retryable: false
        }
        payload[:requestId] = request_id unless request_id.nil?
        @emitter.emit("error", payload)
        return
      end

      replacement = restart_connection(configuration_id)
      return unless replacement

      configuration_id, = replacement
      cleared = clear_stored_secrets
      publish_configuration(configuration_id) do
        payload = if cleared
                    { stored: false }
                  else
                    {
                      scope: "secret", code: "clear_failed",
                      message: "Unable to clear stored LAN access code", retryable: true
                    }
                  end
        payload[:requestId] = request_id unless request_id.nil?
        @emitter.emit(cleared ? "secret_status" : "error", payload)

        required = { storageAvailable: storage_available? }
        required[:requestId] = request_id unless request_id.nil?
        @emitter.emit("secret_required", required)
      end
    end

    def refresh_model
      connection = @control_mutex.synchronize { @connection unless @shutdown }
      connection&.refresh_preview
    end

    def replace_configuration(config)
      connection = nil
      configuration_id = @publication_mutex.synchronize do
        values = @control_mutex.synchronize do
          next if @shutdown

          @configuration_id += 1
          connection = @connection
          @connection = nil
          @config = config
          @secret = nil
          @configuration_id
        end
        connection&.stop
        values
      end
      configuration_id
    end

    def restart_connection(expected_id)
      connection = nil
      replacement = @publication_mutex.synchronize do
        values = @control_mutex.synchronize do
          next unless !@shutdown && @configuration_id == expected_id && @config

          @configuration_id += 1
          connection = @connection
          @connection = nil
          @secret = nil
          [@configuration_id, @config]
        end
        connection&.stop if values
        values
      end
      replacement
    end

    def start_connection(configuration_id)
      config, secret = @control_mutex.synchronize do
        next unless current_configuration_unlocked?(configuration_id)

        [@config, @secret]
      end
      return unless config && secret
      unless config.trusted_tls?
        publish_configuration(configuration_id) { @emitter.emit("tls_required") }
        return
      end

      connection = PrinterConnection.new(
        config: config,
        secret: secret,
        emitter: @emitter,
        mqtt_factory: @mqtt_factory,
        worker_factory: @worker_factory,
        monotonic_clock: @monotonic_clock,
        next_sequence: -> { next_sequence }
      )
      attached = @publication_mutex.synchronize do
        @control_mutex.synchronize do
          next false unless current_configuration_unlocked?(configuration_id)
          next false unless @config.equal?(config) && @secret.equal?(secret) && !@connection

          @connection = connection
          true
        end
      end
      return connection.stop unless attached

      connection.start
    end

    def publish_configuration(configuration_id)
      @publication_mutex.synchronize do
        next false unless current_configuration?(configuration_id)

        yield
        true
      end
    end

    def set_current_secret(configuration_id, secret)
      @control_mutex.synchronize do
        next false unless current_configuration_unlocked?(configuration_id)

        @secret = secret
        true
      end
    end

    def current_configuration
      @control_mutex.synchronize { [@configuration_id, @config] unless @shutdown }
    end

    def current_configuration?(configuration_id)
      @control_mutex.synchronize { current_configuration_unlocked?(configuration_id) }
    end

    def current_configuration_unlocked?(configuration_id)
      !@shutdown && @configuration_id == configuration_id
    end

    def start_tls_probe(config, request_id)
      generation, previous = @control_mutex.synchronize do
        @tls_probe_generation += 1
        [@tls_probe_generation, @tls_probe_thread]
      end
      stop_thread(previous)

      gate = Queue.new
      thread = Thread.new do
        gate.pop
        begin
          result = @tls_probe.probe(
            host: config.host,
            mqtt_port: config.mqtt_port,
            ftps_port: config.ftps_port,
            cancelled: -> { tls_probe_cancelled?(generation) }
          )
          emit_tls_probe_result(generation, request_id, result)
        rescue TlsCertificateError => error
          emit_tls_probe_error(generation, request_id, error)
        rescue StandardError
          emit_tls_probe_error(
            generation, request_id,
            TlsCertificateError.new("probe_failed", "TLS certificate probe failed")
          )
        ensure
          @control_mutex.synchronize do
            @tls_probe_thread = nil if @tls_probe_thread.equal?(Thread.current)
          end
        end
      end
      thread.report_on_exception = false
      attached = @control_mutex.synchronize do
        next false if @shutdown || @tls_probe_generation != generation

        @tls_probe_thread = thread
        true
      end
      unless attached
        thread.kill
        thread.join
        return
      end

      gate << true
    end

    def emit_tls_probe_result(generation, request_id, result)
      publish_tls_probe(generation) do
        @emitter.emit(
          "tls_identity", requestId: request_id,
          mqtt: result.fetch("mqtt"), ftps: result.fetch("ftps")
        )
      end
    end

    def emit_tls_probe_error(generation, request_id, error)
      return if error.code == "cancelled"

      publish_tls_probe(generation) do
        @emitter.emit(
          "error", scope: "tls", code: "probe_failed",
          message: "Unable to read printer TLS certificates",
          retryable: true, requestId: request_id
        )
      end
    end

    def publish_tls_probe(generation)
      @publication_mutex.synchronize do
        next false unless active_tls_probe?(generation)

        yield
        true
      end
    end

    def active_tls_probe?(generation)
      @control_mutex.synchronize do
        !@shutdown && @tls_probe_generation == generation
      end
    end

    def tls_probe_cancelled?(generation)
      !active_tls_probe?(generation)
    end

    def cancel_tls_probe
      thread = @control_mutex.synchronize do
        @tls_probe_generation += 1
        current = @tls_probe_thread
        @tls_probe_thread = nil
        current
      end
      stop_thread(thread)
    end

    def stop_thread(thread)
      return unless thread
      return if thread.equal?(Thread.current)

      unless thread.join(THREAD_JOIN_SECONDS)
        thread.kill
        thread.join(THREAD_JOIN_SECONDS)
      end
    rescue StandardError
      thread.kill if thread&.alive?
    end

    def lookup_secret(serial)
      @secret_store.lookup(serial)
    rescue StandardError
      emit_error(
        scope: "secret", code: "lookup_failed",
        message: "Unable to read stored LAN access code", retryable: true
      )
      nil
    end

    def store_secret(serial, secret)
      @secret_store.store(serial, secret)
    rescue StandardError
      emit_error(
        scope: "secret", code: "store_failed",
        message: "Unable to store LAN access code", retryable: true
      )
      false
    end

    def clear_stored_secrets
      !!@secret_store.clear_all
    rescue StandardError
      false
    end

    def storage_available?
      @secret_store.available?
    rescue StandardError
      emit_error(
        scope: "secret", code: "storage_unavailable",
        message: "Secret storage unavailable", retryable: true
      )
      false
    end

    def emit_error(scope:, code:, message:, retryable:)
      @emitter.error(
        scope: scope, code: code, message: String(message), retryable: retryable
      )
    end

    def next_sequence
      @sequence += 1
    end

    def request_shutdown
      connection = nil
      @publication_mutex.synchronize do
        @control_mutex.synchronize do
          unless @shutdown
            @shutdown = true
            @configuration_id += 1
            connection = @connection
            @connection = nil
          end
        end
        connection&.stop
      end
    end

    def shutdown_requested?
      @control_mutex.synchronize { @shutdown }
    end

    def handle_output_failure(error)
      @control_mutex.synchronize do
        target = @run_thread
        return if @shutdown || !target || target.equal?(Thread.current) || !target.alive?

        target.raise(error)
      end
    rescue ThreadError
      nil
    end

    def shutdown
      request_shutdown
      cancel_tls_probe
      @emitter.close
    end
  end
end
