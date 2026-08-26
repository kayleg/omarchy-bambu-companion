# frozen_string_literal: true

require_relative "test_helper"
require "bambu_companion/jpeg_tcp_client"

class JpegTcpClientTest < Minitest::Test
  JPEG_A = "\xFF\xD8\xFFaaa\xFF\xD9".b.freeze
  JPEG_B = "\xFF\xD8\xFFbbb\xFF\xD9".b.freeze

  class FakeSocket
    attr_reader :writes, :closed

    def initialize(payload, chunk: nil)
      @payload = payload.b
      @chunk = chunk
      @offset = 0
      @writes = []
      @closed = false
    end

    def write(data)
      @writes << data.b
      data.bytesize
    end

    def readpartial(size)
      raise EOFError if @offset >= @payload.bytesize

      length = [@chunk || size, size, @payload.bytesize - @offset].min
      slice = @payload.byteslice(@offset, length)
      @offset += length
      slice
    end

    def close
      @closed = true
    end
  end

  def test_sends_openbambu_auth_packet_then_yields_jpeg_frames
    socket = FakeSocket.new(frame(JPEG_A) + frame(JPEG_B), chunk: 5)
    frames = []
    client(socket).each_frame { |jpeg| frames << jpeg }

    assert_equal [JPEG_A, JPEG_B], frames
    auth = socket.writes.fetch(0)
    assert_equal 80, auth.bytesize
    size, type, flags, reserved = auth.byteslice(0, 16).unpack("V4")
    assert_equal 0x40, size
    assert_equal 0x3000, type
    assert_equal 0, flags
    assert_equal 0, reserved
    assert_equal "bblp".ljust(32, "\0"), auth.byteslice(16, 32)
    assert_equal "lan-code".ljust(32, "\0"), auth.byteslice(48, 32)
  end

  def test_rejects_oversized_frame_and_closes_the_socket
    socket = FakeSocket.new(frame("x" * (1_048_577)))
    error = assert_raises(BambuCompanion::JpegTcpError) do
      client(socket).each_frame { nil }
    end

    assert_equal "oversized_frame", error.code
    assert socket.closed
  end

  def test_cancel_closes_the_socket_before_reading_frames
    socket = FakeSocket.new(frame(JPEG_A))
    cancelled = false
    frames = []
    client(socket, cancelled: -> { !cancelled && (cancelled = true); true }).each_frame do |jpeg|
      frames << jpeg
    end

    assert_empty frames
    assert socket.closed
    refute_empty socket.writes
  end

  private

  def client(socket, cancelled: -> { false })
    BambuCompanion::JpegTcpClient.new(
      host: "192.168.1.50", username: "bblp", password: "lan-code",
      fingerprint: "AA" * 32,
      socket_factory: ->(**) { socket },
      cancelled: cancelled
    )
  end

  def frame(jpeg)
    [jpeg.bytesize, 0, 1, 0].pack("V4") + jpeg.b
  end
end
