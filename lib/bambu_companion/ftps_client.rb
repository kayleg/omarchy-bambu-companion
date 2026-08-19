# frozen_string_literal: true

require "net/ftp"
require "openssl"
require "tempfile"
require_relative "ftps_error"
require_relative "sd_card_file_locator"
require_relative "tls_certificate"

module BambuCompanion
  module PinnedFtpsTransport
    private

    def start_tls_session(socket)
      tls_socket = OpenSSL::SSL::SSLSocket.new(socket, @ssl_context)
      tls_socket.sync_close = true
      tls_socket.hostname = @host if tls_socket.respond_to?(:hostname=)
      if @ssl_session &&
         Process.clock_gettime(Process::CLOCK_REALTIME) <
         @ssl_session.time.to_f + @ssl_session.timeout
        tls_socket.session = @ssl_session
      end
      ssl_socket_connect(tls_socket, @ssl_handshake_timeout || @open_timeout)
      # Exact leaf pinning authenticates the endpoint even though Bambu's
      # certificate hostname is its serial number rather than the configured IP.
      tls_socket
    rescue OpenSSL::SSL::SSLError => error
      TlsCertificate.raise_if_pin_rejected!(@ssl_context, error)
    end
  end

  class FtpsClient
    BARE_SOCKET_CLEANUP_VERSION = "0.3.9"

    def initialize(config:, secret:, max_bytes: 1 << 30, ftp_factory: nil,
                   sleeper: ->(seconds) { sleep(seconds) }, attempts: 3,
                   max_list_entries: SdCardFileLocator::DEFAULT_MAX_ENTRIES,
                   max_list_bytes: SdCardFileLocator::DEFAULT_MAX_BYTES,
                   max_list_line_bytes: SdCardFileLocator::DEFAULT_MAX_LINE_BYTES,
                   file_locator: nil,
                   ftp_class: Net::FTP)
      @config = config
      @secret = String(secret)
      @max_bytes = Integer(max_bytes)
      raise ArgumentError, "max_bytes must be positive" unless @max_bytes.positive?

      @ftp_factory = ftp_factory || method(:open_ftp)
      @ftp_class = ftp_class
      @sleeper = sleeper
      @attempts = Integer(attempts)
      raise ArgumentError, "attempts must be positive" unless @attempts.positive?

      @file_locator = file_locator || SdCardFileLocator.new(
        host: config.host, max_entries: max_list_entries,
        max_bytes: max_list_bytes, max_line_bytes: max_list_line_bytes
      )
    end

    def download(hints:, destination:, cancelled: -> { false }, progress: ->(*) {})
      raise_cancelled if cancelled.call

      @attempts.times do |attempt|
        return download_once(
          hints: hints, destination: destination, cancelled: cancelled,
          progress: progress
        )
      rescue FtpsError => error
        raise unless %w[file_not_found transport].include?(error.code) &&
                     attempt + 1 < @attempts

        raise_cancelled if cancelled.call

        @sleeper.call(0.75 * (attempt + 1))
        raise_cancelled if cancelled.call
      end
    end

    private

    def download_once(hints:, destination:, cancelled:, progress:)
      ftp = @ftp_factory.call(@config, @secret)
      remote = @file_locator.find(ftp, hints, cancelled: cancelled)
      raise_cancelled if cancelled.call

      bytes = 0
      total_bytes = remote_size(ftp, remote)
      if total_bytes && total_bytes > @max_bytes
        raise FtpsError.new(
          "too_large", "Print file exceeds #{@max_bytes} bytes"
        ), cause: nil
      end
      progress.call(0, total_bytes)
      temporary = Tempfile.create(
        [".#{File.basename(destination)}-", ".part"],
        File.dirname(destination), mode: 0o600, binmode: true
      )
      temporary_path = temporary.path
      ftp.retrbinary("RETR #{remote}", 64 * 1024) do |chunk|
        raise_cancelled if cancelled.call

        bytes += chunk.bytesize
        if bytes > @max_bytes
          raise FtpsError.new(
            "too_large", "Print file exceeds #{@max_bytes} bytes"
          ), cause: nil
        end
        temporary.write(chunk)
        progress.call(bytes, total_bytes)
      end
      temporary.close
      File.rename(temporary_path, destination)
      temporary_path = nil
      remote
    rescue FtpsError
      raise
    rescue TlsCertificateError => error
      raise FtpsError.new(error.code, error.message), cause: nil
    rescue StandardError
      raise FtpsError.new("transport", "FTPS transfer failed"), cause: nil
    ensure
      safely_close(temporary)
      safely_unlink(temporary_path)
      safely_close(ftp)
    end

    def raise_cancelled
      raise FtpsError.new("cancelled", "FTPS download cancelled"), cause: nil
    end

    def remote_size(ftp, remote)
      size = Integer(ftp.size(remote))
      size if size >= 0
    rescue Net::FTPError, ArgumentError, TypeError, NoMethodError
      nil
    end

    def safely_close(object)
      object&.close
    rescue StandardError
      nil
    end

    def cleanup_failed_ftp(ftp)
      bare_socket = pinned_bare_socket(ftp)
      safely_close(ftp)
      safely_close_socket(bare_socket)
    end

    def pinned_bare_socket(ftp)
      return nil unless Net::FTP::VERSION == BARE_SOCKET_CLEANUP_VERSION
      return nil unless ftp.is_a?(Net::FTP)
      return nil unless ftp.instance_variable_defined?(:@bare_sock)

      ftp.instance_variable_get(:@bare_sock)
    end

    def safely_close_socket(socket)
      return unless socket
      return if socket.respond_to?(:closed?) && socket.closed?

      socket.close
    rescue StandardError
      nil
    end

    def safely_unlink(path)
      File.unlink(path) if path && File.file?(path)
    rescue StandardError
      nil
    end

    def open_ftp(config, secret)
      ftp = build_ftp(config)
      ftp.connect(config.host, config.ftps_port)
      ftp.login(config.username, secret)
      # Bambu answers 332 to PBSZ/PROT before USER/PASS.
      ftp.sendcmd("PBSZ 0")
      ftp.sendcmd("PROT P")
      ftp.instance_variable_set(:@private_data_connection, true)
      ftp
    rescue StandardError
      cleanup_failed_ftp(ftp)
      raise
    end

    def build_ftp(config)
      ftp = @ftp_class.new(
        nil, ssl: {},
        implicit_ftps: true, private_data_connection: false, passive: true,
        open_timeout: 8, read_timeout: 30, ssl_handshake_timeout: 8
      )
      return ftp unless ftp.is_a?(Net::FTP)

      context = ftp.instance_variable_get(:@ssl_context)
      TlsCertificate.configure_pinned_context(
        context, config.ftps_tls_fingerprint
      )
      ftp.singleton_class.prepend(PinnedFtpsTransport)
      ftp
    end
  end
end
