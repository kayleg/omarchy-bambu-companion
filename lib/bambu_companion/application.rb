# frozen_string_literal: true

require "digest"
require_relative "config"
require_relative "ipc"
require_relative "secret_store"
require_relative "printer_state"
require_relative "mqtt_session"
require_relative "ftps_client"
require_relative "gcode_source"
require_relative "gcode_parser"
require_relative "model_worker"
require_relative "tls_certificate"

module BambuCompanion
  class Application
    PROTOCOL = 1
    MAX_IPC_LINE_BYTES = IpcLineFramer::DEFAULT_MAX_LINE_BYTES
    MAX_ACCESS_CODE_BYTES = SecretStore::MAX_SECRET_BYTES
    RUNTIME_JOIN_SECONDS = 0.5
    MODEL_HINT_KEYS = %i[file url gcode_file subtask_name plate_idx].freeze
    MODEL_RETRY_DELAYS = [5.0, 10.0, 20.0, 30.0].freeze
    MODEL_MAX_RETRIES = 6

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
      @mqtt_factory = mqtt_factory || ->(**arguments) { MqttSession.new(**arguments) }
      @worker_factory = worker_factory || method(:build_worker)
      @installation_id = String(installation_id)
      @monotonic_clock = monotonic_clock
      @tls_probe = tls_probe
      @control_mutex = Mutex.new
      @state_mutex = Mutex.new
      @publication_mutex = Mutex.new
      @runtime_id = 0
      @sequence = 0
      @shutdown = false
      @run_thread = nil
      @config = nil
      @secret = nil
      @printer = PrinterState.new
      @last_hints = {}.freeze
      @model_retry_attempt = 0
      @model_retry_at = nil
      @mqtt = nil
      @mqtt_thread = nil
      @worker = nil
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
              begin
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

    def handle(command)
      case command_value(command, "op")
      when "configure"
        configure(command)
      when "set_secret"
        set_secret(command)
      when "clear_secret"
        clear_secret(command)
      when "refresh_model"
        refresh_model
      when "probe_tls"
        probe_tls(command)
      when "shutdown"
        request_shutdown
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

    def command_value(command, key, default = nil)
      return command[key] if command.key?(key)

      symbol = key.to_sym
      command.key?(symbol) ? command[symbol] : default
    end

    def configure(command)
      protocol = command_value(command, "protocol")
      unless protocol == PROTOCOL
        emit_error(
          scope: "config", code: "unsupported_protocol",
          message: "Unsupported IPC protocol", retryable: false
        )
        return
      end

      raw = command_value(command, "config", {})
      candidate = Config.from_h(raw || {})
      cancel_tls_probe
      runtime_id = replace_runtime(candidate)

      found = lookup_secret(candidate.serial)
      if !found.is_a?(String) || found.empty? || found.bytesize > MAX_ACCESS_CODE_BYTES
        set_current_secret(nil)
        @emitter.emit("secret_required", storageAvailable: storage_available?)
        return
      end

      set_current_secret(String(found))
      @emitter.emit("secret_status", stored: true)
      unless candidate.trusted_tls?
        @emitter.emit("tls_required")
        return
      end

      start_runtime(runtime_id)
    end

    def probe_tls(command)
      protocol = command_value(command, "protocol")
      unless protocol == PROTOCOL
        emit_error(
          scope: "config", code: "unsupported_protocol",
          message: "Unsupported IPC protocol", retryable: false
        )
        return
      end
      request_id = command_value(command, "requestId")
      unless request_id.is_a?(Integer) && request_id.between?(0, 2_147_483_647)
        raise ConfigError, "requestId is invalid"
      end

      config = Config.from_h(command_value(command, "config", {}) || {})
      start_tls_probe(config, request_id)
    end

    def set_secret(command)
      config = current_config
      unless config
        emit_error(
          scope: "secret", code: "invalid_state",
          message: "A printer configuration is required", retryable: false
        )
        return
      end

      value = command_value(command, "accessCode")
      unless value.is_a?(String) && !value.strip.empty?
        raise ConfigError, "LAN access code is empty"
      end
      secret = value.strip
      if secret.bytesize > MAX_ACCESS_CODE_BYTES
        raise ConfigError, "LAN access code is too long"
      end

      persist = command_value(command, "persist", true)
      raise ConfigError, "persist must be boolean" unless [true, false].include?(persist)

      runtime_id = restart_runtime
      set_current_secret(secret)
      stored = persist ? store_secret(config.serial, secret) : false
      @emitter.emit("secret_status", stored: !!stored)
      start_runtime(runtime_id)
    end

    def clear_secret(command)
      request_id = command_value(command, "requestId")
      valid_request_id = request_id.nil? || (request_id.is_a?(Integer) &&
        request_id.between?(0, 2_147_483_647))
      raise ConfigError, "requestId is invalid" unless valid_request_id

      config = current_config
      unless config
        payload = {
          scope: "secret", code: "invalid_state",
          message: "A printer configuration is required", retryable: false
        }
        payload[:requestId] = request_id unless request_id.nil?
        @emitter.emit("error", payload)
        return
      end

      invalidate_runtime
      stop_runtime
      set_current_secret(nil)
      cleared = clear_stored_secrets
      if cleared
        payload = { stored: false }
        payload[:requestId] = request_id unless request_id.nil?
        @emitter.emit("secret_status", payload)
      else
        payload = {
          scope: "secret", code: "clear_failed",
          message: "Unable to clear stored LAN access code", retryable: true
        }
        payload[:requestId] = request_id unless request_id.nil?
        @emitter.emit("error", payload)
      end
      payload = { storageAvailable: storage_available? }
      payload[:requestId] = request_id unless request_id.nil?
      @emitter.emit("secret_required", payload)
    end

    def refresh_model
      config, worker, hints = @control_mutex.synchronize do
        [@config, @worker, @last_hints]
      end
      return unless config && worker

      unless hints.empty?
        worker.submit(hints: hints)
        arm_model_retry(worker)
      end
    rescue StandardError => error
      emit_error(
        scope: "gcode", code: "refresh_failed", message: error.message,
        retryable: true
      )
    end

    def replace_runtime(config)
      runtime_id = invalidate_runtime
      stop_runtime
      @state_mutex.synchronize do
        @printer = PrinterState.new
      end
      @control_mutex.synchronize do
        @config = config
        @secret = nil
        @last_hints = {}.freeze
        reset_model_retry_unlocked
      end
      runtime_id
    end

    def restart_runtime
      runtime_id = invalidate_runtime
      stop_runtime
      runtime_id
    end

    def start_runtime(runtime_id)
      config, secret = @control_mutex.synchronize { [@config, @secret] }
      return unless active_runtime?(runtime_id) && config && secret
      unless config.trusted_tls?
        @emitter.emit("tls_required")
        return
      end

      worker = @worker_factory.call(
        config: config, secret: secret, emitter: @emitter,
        on_status: ->(*) { emit_state(runtime_id: runtime_id, worker: worker) }
      )
      attach_worker(runtime_id, worker)
      worker.start
      return cleanup_unattached(worker: worker) unless active_runtime?(runtime_id)

      session = @mqtt_factory.call(
        config: config, secret: secret,
        on_report: ->(report) { handle_report(report, runtime_id: runtime_id, worker: worker) },
        on_connection: lambda do |connected, error|
          handle_connection(connected, error, runtime_id: runtime_id, worker: worker)
        end,
        on_error: ->(error) { emit_network_error(error, runtime_id: runtime_id) }
      )
      start_session_thread(runtime_id, session)
    rescue StandardError => error
      cleanup_failed_runtime(runtime_id, worker: worker, session: session)
      emit_runtime_error(
        runtime_id: runtime_id,
        scope: "internal", code: "runtime_start", message: error.message,
        retryable: true
      )
    end

    def start_session_thread(runtime_id, session)
      gate = Queue.new
      thread = Thread.new do
        gate.pop
        begin
          session.run
        rescue MQTT::Exception, StandardError => error
          emit_network_error(error, runtime_id: runtime_id)
        end
      end
      thread.report_on_exception = false
      attached = @control_mutex.synchronize do
        next false unless active_runtime_unlocked?(runtime_id)

        @mqtt = session
        @mqtt_thread = thread
        true
      end
      unless attached
        thread.kill
        thread.join
        session.stop
        return
      end

      gate << true
    end

    def handle_report(report, runtime_id:, worker:, load_model: true)
      printer = current_printer_for(runtime_id)
      return unless printer

      update = @state_mutex.synchronize { printer.update(report) }
      hints = update.snapshot.slice(*MODEL_HINT_KEYS).freeze
      @control_mutex.synchronize do
        @last_hints = hints if active_runtime_unlocked?(runtime_id)
      end
      if load_model && update.load_model && active_runtime?(runtime_id)
        worker.submit(hints: hints)
        arm_model_retry(worker)
      elsif load_model
        retry_model_if_due(
          runtime_id: runtime_id, worker: worker,
          hints: hints, printer_snapshot: update.snapshot
        )
      end
      emit_state(runtime_id: runtime_id, worker: worker)
    rescue ModelWorker::StoppedError
      nil
    rescue StandardError => error
      emit_runtime_error(
        runtime_id: runtime_id,
        scope: "internal", code: "report_processing", message: error.message,
        retryable: true
      )
    end

    def handle_connection(connected, _error, runtime_id:, worker:)
      printer = current_printer_for(runtime_id)
      return unless printer

      @state_mutex.synchronize do
        connected ? printer.connected! : printer.disconnected!
      end
      emit_state(runtime_id: runtime_id, worker: worker)
    end

    def emit_network_error(error, runtime_id:)
      if error.is_a?(TlsCertificateError)
        emit_runtime_error(
          runtime_id: runtime_id,
          scope: "tls", code: error.code, message: error.message,
          retryable: false
        )
        return
      end

      authentication = MqttSession.authentication_error?(error)
      emit_runtime_error(
        runtime_id: runtime_id,
        scope: "mqtt", code: authentication ? "authentication" : "connection",
        message: error.message, retryable: !authentication
      )
    end

    def emit_state(runtime_id:, worker:)
      @publication_mutex.synchronize do
        printer = current_printer_for(runtime_id)
        next unless printer

        printer_snapshot = @state_mutex.synchronize { printer.snapshot }
        model = worker.snapshot(printer_snapshot)
        @emitter.emit(
          "state", sequence: next_sequence,
          printer: printer_payload(printer_snapshot), model: model_payload(model)
        )
      end
    rescue ModelWorker::StoppedError
      nil
    rescue IpcOutputError
      raise
    rescue StandardError => error
      emit_runtime_error(
        runtime_id: runtime_id,
        scope: "internal", code: "state_snapshot", message: error.message,
        retryable: true
      )
    end

    def printer_payload(state)
      {
        connected: state[:connected], stale: state[:stale],
        lastUpdate: state[:last_update], gcodeState: state[:gcode_state],
        subtaskName: state[:subtask_name], percent: state[:percent],
        nozzleTemp: state[:nozzle_temp], nozzleTargetTemp: state[:nozzle_target_temp],
        bedTemp: state[:bed_temp], bedTargetTemp: state[:bed_target_temp],
        layer: state[:layer], totalLayers: state[:total_layers],
        remainingMinutes: state[:remaining_minutes], speedLevel: state[:speed_level],
        speedMagnitude: state[:speed_magnitude], wifiSignal: state[:wifi_signal],
        coolingFanSpeed: state[:cooling_fan_speed],
        heatbreakFanSpeed: state[:heatbreak_fan_speed]
      }
    end

    def model_payload(model)
      {
        status: model[:status], generation: model[:generation],
        segmentCount: model[:segment_count], zCurrent: model[:z_current],
        zMode: model[:z_mode], error: model[:error]
      }
    end

    def retry_model_if_due(runtime_id:, worker:, hints:, printer_snapshot:)
      unless printer_snapshot[:gcode_state].to_s.upcase == "RUNNING" && !hints.empty?
        clear_model_retry(worker)
        return false
      end

      model = worker.snapshot(printer_snapshot)
      status = model[:status].to_s
      if status == "ready"
        clear_model_retry(worker)
        return false
      end
      return false unless status == "error"
      return clear_model_retry(worker) if model.dig(:error, :code) == "certificate_changed"
      return false unless take_model_retry_slot(runtime_id, worker)

      worker.submit(hints: hints)
      true
    end

    def arm_model_retry(worker)
      now = @monotonic_clock.call
      @control_mutex.synchronize do
        next false unless @worker.equal?(worker)

        @model_retry_attempt = 0
        @model_retry_at = now + MODEL_RETRY_DELAYS.first
        true
      end
    end

    def clear_model_retry(worker)
      @control_mutex.synchronize do
        next false unless @worker.equal?(worker)

        reset_model_retry_unlocked
        true
      end
    end

    def take_model_retry_slot(runtime_id, worker)
      now = @monotonic_clock.call
      @control_mutex.synchronize do
        next false unless active_runtime_unlocked?(runtime_id) && @worker.equal?(worker)
        next false unless @model_retry_at && now >= @model_retry_at
        next false if @model_retry_attempt >= MODEL_MAX_RETRIES

        @model_retry_attempt += 1
        if @model_retry_attempt >= MODEL_MAX_RETRIES
          @model_retry_at = nil
        else
          delay_index = [@model_retry_attempt, MODEL_RETRY_DELAYS.length - 1].min
          @model_retry_at = now + MODEL_RETRY_DELAYS[delay_index]
        end
        true
      end
    end

    def reset_model_retry_unlocked
      @model_retry_attempt = 0
      @model_retry_at = nil
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
            host: config.host, mqtt_port: config.mqtt_port,
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

    def build_worker(config:, secret:, emitter:, on_status:)
      ModelWorker.new(
        ftps_client: secret && FtpsClient.new(config: config, secret: secret),
        source: GcodeSource.new,
        parser: GcodeParser.new(max_segments: config.max_segments),
        emitter: emitter,
        on_status: on_status
      )
    end

    def attach_worker(runtime_id, worker)
      attached = @control_mutex.synchronize do
        next false unless active_runtime_unlocked?(runtime_id)

        @worker = worker
        true
      end
      return if attached

      worker.stop
    end

    def cleanup_failed_runtime(runtime_id, worker: nil, session: nil)
      attached_worker = attached_session = attached_thread = nil
      @control_mutex.synchronize do
        if @runtime_id == runtime_id
          attached_worker = @worker
          attached_session = @mqtt
          attached_thread = @mqtt_thread
          @worker = @mqtt = @mqtt_thread = nil
        end
      end
      safely_stop(session || attached_session)
      stop_thread(attached_thread)
      safely_stop(worker || attached_worker)
    end

    def cleanup_unattached(worker: nil, session: nil)
      safely_stop(session)
      safely_stop(worker)
    end

    def stop_runtime
      session = session_thread = worker = nil
      @control_mutex.synchronize do
        session = @mqtt
        session_thread = @mqtt_thread
        worker = @worker
        @mqtt = @mqtt_thread = @worker = nil
        reset_model_retry_unlocked
      end
      safely_stop(session)
      stop_thread(session_thread)
      safely_stop(worker)
    end

    def safely_stop(runtime)
      runtime&.stop
    rescue MQTT::Exception, StandardError
      nil
    end

    def stop_thread(thread)
      return unless thread
      return if thread.equal?(Thread.current)

      unless thread.join(RUNTIME_JOIN_SECONDS)
        thread.kill
        thread.join(RUNTIME_JOIN_SECONDS)
      end
    rescue MQTT::Exception, StandardError
      thread.kill if thread&.alive?
    end

    def lookup_secret(serial)
      @secret_store.lookup(serial)
    rescue StandardError
      emit_error(
        scope: "secret", code: "lookup_failed",
        message: "Unable to read stored LAN access code",
        retryable: true
      )
      nil
    end

    def store_secret(serial, secret)
      @secret_store.store(serial, secret)
    rescue StandardError
      emit_error(
        scope: "secret", code: "store_failed",
        message: "Unable to store LAN access code",
        retryable: true
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
        message: "Secret storage unavailable",
        retryable: true
      )
      false
    end

    def emit_error(scope:, code:, message:, retryable:)
      @emitter.error(
        scope: scope, code: code, message: String(message), retryable: retryable
      )
    end

    def emit_runtime_error(runtime_id:, scope:, code:, message:, retryable:)
      @publication_mutex.synchronize do
        next false unless active_runtime?(runtime_id)

        emit_error(
          scope: scope, code: code, message: message, retryable: retryable
        )
      end
    end

    def next_sequence
      @sequence += 1
    end

    def set_current_secret(secret)
      @control_mutex.synchronize { @secret = secret }
    end

    def current_config
      @control_mutex.synchronize { @config }
    end

    def current_printer_for(runtime_id)
      @control_mutex.synchronize do
        @printer if active_runtime_unlocked?(runtime_id)
      end
    end

    def invalidate_runtime
      @publication_mutex.synchronize do
        @control_mutex.synchronize { @runtime_id += 1 }
      end
    end

    def active_runtime?(runtime_id)
      @control_mutex.synchronize { active_runtime_unlocked?(runtime_id) }
    end

    def active_runtime_unlocked?(runtime_id)
      !@shutdown && @runtime_id == runtime_id
    end

    def request_shutdown
      @publication_mutex.synchronize do
        @control_mutex.synchronize do
          unless @shutdown
            @shutdown = true
            @runtime_id += 1
          end
        end
      end
    end

    def shutdown_requested?
      @control_mutex.synchronize { @shutdown }
    end

    def handle_output_failure(_error)
      @control_mutex.synchronize do
        target = @run_thread
        return if @shutdown || !target || target.equal?(Thread.current) || !target.alive?

        target.raise(IpcOutputError, "IPC output unavailable", cause: nil)
      end
    rescue ThreadError
      nil
    end

    def shutdown
      request_shutdown
      cancel_tls_probe
      stop_runtime
      @emitter.close
    end
  end
end
