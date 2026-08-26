# frozen_string_literal: true

require_relative "camera_store"
require_relative "tls_certificate"

module BambuCompanion
  class JpegTcpError < StandardError
    attr_reader :code

    def initialize(code, message)
      @code = String(code)
      super(message)
    end
  end

  class JpegTcpClient
    PORT = 6000
    AUTH_TYPE = 0x3000
    AUTH_PAYLOAD_BYTES = 0x40
    HEADER_BYTES = 16
    TOKEN_BYTES = 32
    MAX_JPEG_BYTES = CameraStore::MAX_JPEG_BYTES
    CONNECT_TIMEOUT = 8.0

    def initialize(host:, username:, password:, fingerprint:,
                   port: PORT, socket_factory: nil, cancelled: -> { false },
                   connect_timeout: CONNECT_TIMEOUT)
      @host = String(host)
      @port = Integer(port)
      @username = String(username)
      @password = String(password)
      @fingerprint = fingerprint
      @socket_factory = socket_factory || method(:open_tls_socket)
      @cancelled = cancelled
      @connect_timeout = connect_timeout
      @socket = nil
    end

    def each_frame
      @socket = @socket_factory.call(
        host: @host, port: @port, fingerprint: @fingerprint,
        connect_timeout: @connect_timeout
      )
      @socket.write(auth_packet)
      loop do
        break if cancelled?

        jpeg = read_frame
        break if jpeg.equal?(:eof)

        yield jpeg if jpeg
      end
    ensure
      close
    end

    def close
      socket = @socket
      @socket = nil
      socket&.close
    rescue StandardError
      nil
    end

    private

    def cancelled?
      @cancelled.call
    rescue StandardError
      true
    end

    def auth_packet
      [AUTH_PAYLOAD_BYTES, AUTH_TYPE, 0, 0].pack("V4") +
        padded(@username) + padded(@password)
    end

    def padded(value)
      String(value).b.byteslice(0, TOKEN_BYTES).to_s.ljust(TOKEN_BYTES, "\0")
    end

    def read_frame
      header = read_exact(HEADER_BYTES)
      return :eof if header.nil?

      payload_size, = header.unpack("V")
      if payload_size < 2 || payload_size > MAX_JPEG_BYTES
        raise JpegTcpError.new("oversized_frame", "Camera frame exceeds the size limit")
      end

      payload = read_exact(payload_size)
      return :eof if payload.nil?
      return unless payload.start_with?(CameraStore::JPEG_SOI) &&
                    payload.end_with?(CameraStore::JPEG_EOI)

      payload
    end

    def read_exact(length)
      buffer = String.new(encoding: Encoding::BINARY)
      while buffer.bytesize < length
        return if cancelled?

        buffer << @socket.readpartial(length - buffer.bytesize).b
      end
      buffer
    rescue EOFError
      nil
    end

    def open_tls_socket(host:, port:, fingerprint:, connect_timeout:)
      TlsCertificate.open_pinned(
        host: host, port: port, fingerprint: fingerprint,
        connect_timeout: connect_timeout
      )
    rescue TlsCertificateError
      raise
    rescue StandardError
      raise JpegTcpError.new("connection", "Unable to open the camera JPEG socket")
    end
  end
end
