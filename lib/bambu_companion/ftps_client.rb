# frozen_string_literal: true

require "net/ftp"
require "openssl"
require "tempfile"
require "uri"
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

  class FtpsError < StandardError
    attr_reader :code

    def initialize(code, message)
      @code = String(code)
      super(message)
    end
  end

  class FtpsClient
    PRINT_EXTENSION = /(?:\.gcode(?:\.3mf)?|\.3mf)\z/i
    HINT_KEYS = %w[file url gcode_file subtask_name].freeze
    BARE_SOCKET_CLEANUP_VERSION = "0.3.9"
    LIST_BLOCK_SIZE = 64 * 1024
    LIST_ROOTS = ["/", "/cache", "/model"].freeze
    DEFAULT_MAX_LIST_ENTRIES = 10_000
    DEFAULT_MAX_LIST_BYTES = 4 * 1024 * 1024
    DEFAULT_MAX_LIST_LINE_BYTES = 16 * 1024

    def initialize(config:, secret:, max_bytes: 1 << 30, ftp_factory: nil,
                   sleeper: ->(seconds) { sleep(seconds) }, attempts: 3,
                   max_list_entries: DEFAULT_MAX_LIST_ENTRIES,
                   max_list_bytes: DEFAULT_MAX_LIST_BYTES,
                   max_list_line_bytes: DEFAULT_MAX_LIST_LINE_BYTES,
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

      @max_list_entries = Integer(max_list_entries)
      unless @max_list_entries.positive?
        raise ArgumentError, "max_list_entries must be positive"
      end

      @max_list_bytes = Integer(max_list_bytes)
      raise ArgumentError, "max_list_bytes must be positive" unless @max_list_bytes.positive?

      @max_list_line_bytes = Integer(max_list_line_bytes)
      unless @max_list_line_bytes.positive?
        raise ArgumentError, "max_list_line_bytes must be positive"
      end
    end

    def download(hints:, destination:, cancelled: -> { false })
      raise_cancelled if cancelled.call

      @attempts.times do |attempt|
        return download_once(hints: hints, destination: destination, cancelled: cancelled)
      rescue FtpsError => error
        raise unless %w[file_not_found transport].include?(error.code) &&
                     attempt + 1 < @attempts

        raise_cancelled if cancelled.call

        @sleeper.call(0.75 * (attempt + 1))
        raise_cancelled if cancelled.call
      end
    end

    private

    def download_once(hints:, destination:, cancelled:)
      ftp = @ftp_factory.call(@config, @secret)
      remote = resolve_remote(ftp, hints, cancelled: cancelled)
      raise_cancelled if cancelled.call

      bytes = 0
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

    def resolve_remote(ftp, hints, cancelled:)
      paths = list_paths(ftp, cancelled: cancelled)
      records = hint_records(hints)

      explicit_paths = records.filter_map { |record| record[:path] }
      unless explicit_paths.empty?
        exact_paths = unique_matches(paths, explicit_paths)
        return exact_paths.first if exact_paths.length == 1
        raise_ambiguous if exact_paths.length > 1

        raise_not_found
      end

      exact_names = prefer_active_files(unique_basename_matches(
        paths, records.filter_map { |record| record[:basename] }
      ))
      return exact_names.first if exact_names.length == 1
      raise_ambiguous if exact_names.length > 1

      tokens = records.filter_map { |record| record[:token] }.uniq
      matches = prefer_active_files(
        paths.select { |path| tokens.include?(canonical_name(path)) }
      )
      return matches.first if matches.length == 1
      raise_ambiguous if matches.length > 1

      raise_not_found
    end

    def unique_matches(paths, candidates)
      unique_value_matches(paths, candidates) { |path| path }
    end

    def unique_basename_matches(paths, basenames)
      unique_value_matches(paths, basenames) { |path| File.basename(path) }
    end

    def unique_value_matches(paths, candidates)
      case_sensitive = paths.select { |path| candidates.include?(yield(path)) }
      return case_sensitive.uniq unless case_sensitive.empty?

      paths.select do |path|
        value = yield(path)
        candidates.any? { |candidate| value.casecmp?(candidate) }
      end.uniq
    end

    def prefer_active_files(matches)
      active = matches.reject { |path| path.start_with?("/model/") }
      active.empty? ? matches : active
    end

    def raise_ambiguous
      raise FtpsError.new(
        "ambiguous_file", "Multiple SD-card files match the active print"
      ), cause: nil
    end

    def raise_not_found
      raise FtpsError.new(
        "file_not_found", "Print file not found on SD card"
      ), cause: nil
    end

    def list_paths(ftp, cancelled:)
      paths = {}
      budget = { bytes: 0, entries: 0 }
      LIST_ROOTS.each do |root|
        stream_listing(ftp, root, budget: budget, cancelled: cancelled) do |entry|
          check_cancelled!(cancelled)

          budget[:entries] += 1
          raise_listing_too_large if budget[:entries] > @max_list_entries

          normalized = normalize_listing(root, entry)
          paths[normalized] = true if PRINT_EXTENSION.match?(normalized)
        end
      end
      paths.keys
    end

    def stream_listing(ftp, root, budget:, cancelled:)
      line = String.new(capacity: @max_list_line_bytes, encoding: Encoding::BINARY)
      check_cancelled!(cancelled)
      ftp.retrbinary("NLST #{root}", LIST_BLOCK_SIZE) do |chunk|
        check_cancelled!(cancelled)
        chunk = String(chunk)
        budget[:bytes] += chunk.bytesize
        raise_listing_too_large if budget[:bytes] > @max_list_bytes

        offset = 0
        while (newline = chunk.index("\n", offset))
          append_listing_segment(line, chunk, offset, newline - offset)
          line.delete_suffix!("\r")
          check_cancelled!(cancelled)
          yield line
          line.clear
          offset = newline + 1
        end
        append_listing_segment(line, chunk, offset, chunk.bytesize - offset)
      end
      unless line.empty?
        line.delete_suffix!("\r")
        check_cancelled!(cancelled)
        yield line
      end
    rescue Net::FTPError => error
      return if root != "/" && directory_missing_error?(error)

      raise
    end

    def append_listing_segment(line, chunk, offset, length)
      return if length.zero?
      raise_listing_too_large if line.bytesize + length > @max_list_line_bytes

      line << chunk.byteslice(offset, length)
    end

    def check_cancelled!(cancelled)
      raise_cancelled if cancelled.call
    end

    def raise_listing_too_large
      raise FtpsError.new(
        "too_large", "SD-card listing exceeds safe limits"
      ), cause: nil
    end

    def directory_missing_error?(error)
      error.message.match?(
        /\A550\b.*\b(?:not found|no files(?: found)?|does not exist)\b/i
      )
    end

    def normalize_listing(root, entry)
      text = String(entry).tr("\\", "/")
      return nil if unsafe_text?(text)

      text = text.gsub(%r{/+}, "/")
      segments = text.split("/")
      return nil if segments.any? { |segment| segment == "." || segment == ".." }

      if root == "/"
        remainder = text.delete_prefix("/")
        return nil if remainder.empty? || remainder.include?("/")

        "/#{remainder}"
      else
        directory = root.delete_prefix("/")
        remainder = text.delete_prefix("/").delete_prefix("#{directory}/")
        return nil if remainder.empty? || remainder.include?("/")

        "/#{directory}/#{remainder}"
      end
    end

    def hint_records(hints)
      values = hints.to_h
      HINT_KEYS.filter_map do |key|
        value = values[key] || values[key.to_sym]
        next if value.nil?

        if key == "subtask_name"
          human_hint_record(value)
        else
          path_hint_record(value)
        end
      end
    end

    def human_hint_record(value)
      text = String(value).strip
      return nil if text.empty? || unsafe_text?(text)

      token = canonical_name(text)
      return nil if token.empty?

      { token: token }
    end

    def path_hint_record(value)
      text = String(value).strip
      return nil if text.empty? || unsafe_text?(text)

      uri = nil
      if text.match?(/\A[a-z][a-z0-9+.-]*:/i)
        uri = URI.parse(text)
        return nil unless %w[file ftp ftps].include?(uri.scheme)
        return nil unless safe_uri_host?(uri)
        return nil if uri.userinfo

        text = URI::RFC2396_PARSER.unescape(uri.path.to_s)
      end
      return nil if text.empty? || unsafe_text?(text)

      text = text.tr("\\", "/").gsub(%r{/+}, "/")
      segments = text.split("/")
      return nil if segments.any? { |segment| segment == "." || segment == ".." }

      sd_path = text.match(%r{\A/(?:mnt/)?sdcard(/.*)\z}i)&.captures&.first
      if uri && uri.scheme != "file"
        sd_path ||= text
      elsif uri || text.start_with?("/")
        return nil unless sd_path
      end

      basename = File.basename(sd_path || text)
      return nil unless PRINT_EXTENSION.match?(basename)

      token = canonical_name(basename)
      return nil if token.empty?

      {
        path: normalize_explicit_path(sd_path),
        basename: sd_path ? nil : basename,
        token: token
      }
    rescue URI::InvalidURIError
      nil
    end

    def normalize_explicit_path(path)
      return nil unless path

      path.start_with?("/") ? path : "/#{path}"
    end

    def safe_uri_host?(uri)
      host = uri.host.to_s
      return host.empty? || host.casecmp?("localhost") if uri.scheme == "file"

      host.empty? || host.casecmp?(@config.host)
    end

    def unsafe_text?(text)
      text.match?(/[\x00-\x1f\x7f]/)
    end

    def canonical_name(value)
      File.basename(String(value)).downcase
          .sub(/\.gcode\.3mf\z/, "").sub(/\.gcode\z/, "").sub(/\.3mf\z/, "")
          .gsub(/[^a-z0-9]+/, "")
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
