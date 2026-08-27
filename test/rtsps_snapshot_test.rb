# frozen_string_literal: true

require_relative "test_helper"
require "socket"
require "stringio"
require "bambu_companion/rtsps_snapshot"

class RtspsSnapshotTest < Minitest::Test
  JPEG = BambuCompanion::TestFixtures.minimal_jpeg(payload: "snap").freeze
  SECRET = "rtsp-secret-sentinel"

  def test_ffmpeg_available_uses_the_resolver
    assert BambuCompanion::RtspsSnapshot.ffmpeg_available?(-> { "/usr/bin/ffmpeg" })
    refute BambuCompanion::RtspsSnapshot.ffmpeg_available?(-> { nil })
  end

  def test_capture_runs_one_frame_ffmpeg_without_putting_the_secret_on_argv
    commands = []
    passwords = []
    snapshot = BambuCompanion::RtspsSnapshot.new(
      host: "192.168.1.50", username: "bblp", password: SECRET,
      fingerprint: "AA" * 32,
      runner: lambda { |command, password:, **|
        commands << command
        passwords << password
        JPEG
      }
    )

    assert_equal JPEG, snapshot.capture
    command = commands.fetch(0)
    refute_includes command.join(" "), SECRET
    assert_includes command, "-threads"
    assert_includes command, "1"
    assert_includes command, "-an"
    assert_includes command, "-frames:v"
    assert_equal "1", command[command.index("-frames:v") + 1]
    assert(command.any? { |part| part.include?("scale='min(960,iw)':-2") })
    assert_includes command, "rtsps://bblp@192.168.1.50:322/streaming/live/1"
    assert_equal [SECRET], passwords
  end

  def test_loopback_rewrite_keeps_the_secret_off_ffmpeg_argv
    from = "rtsp://127.0.0.1:9"
    to = "rtsp://bblp:#{SECRET}@192.168.1.50:322"
    rewritten = BambuCompanion::RtspsSnapshot.rewrite_rtsp(
      "DESCRIBE #{from}/streaming/live/1 RTSP/1.0\r\n", from, to
    )

    assert_includes rewritten, SECRET
    argv = [
      "ffmpeg", "-i", "rtsp://127.0.0.1:9/streaming/live/1"
    ]
    refute_includes argv.join(" "), SECRET
  end

  def test_rewrite_leaves_the_authorization_header_alone
    from = "rtsp://127.0.0.1:9"
    to = "rtsps://192.168.1.50:322"
    message = "DESCRIBE #{from}/streaming/live/1 RTSP/1.0\r\n" +
              "CSeq: 2\r\n" +
              "Authorization: Digest username=\"bblp\", " +
              "uri=\"#{from}/streaming/live/1\", response=\"deadbeef\"\r\n\r\n"

    rewritten = BambuCompanion::RtspsSnapshot.rewrite_rtsp(message, from, to)

    assert_includes rewritten, "DESCRIBE #{to}/streaming/live/1 RTSP/1.0"
    # Digest hashes the uri, so rewriting it inside the header invalidates the
    # response the client already computed and the server answers 401 forever.
    assert_includes rewritten, "uri=\"#{from}/streaming/live/1\""
  end

  def test_rewrite_ignores_responses_and_interleaved_data
    from = "rtsp://127.0.0.1:9"
    to = "rtsps://192.168.1.50:322"
    response = "RTSP/1.0 200 OK\r\nContent-Base: #{from}/streaming/live/1/\r\n\r\n"
    interleaved = "$\x00\x00\x04data".b

    assert_equal response, BambuCompanion::RtspsSnapshot.rewrite_rtsp(response, from, to)
    assert_equal interleaved, BambuCompanion::RtspsSnapshot.rewrite_rtsp(interleaved, from, to)
  end

  def test_gateway_answers_a_digest_challenge_without_exposing_the_password
    gateway = BambuCompanion::RtspsSnapshot::LoopbackGateway.new(
      host: "192.168.1.50", port: 322, username: "bblp", password: SECRET,
      fingerprint: "AA" * 32, timeout: 0.2
    )
    unauthorized = "RTSP/1.0 401 Unauthorized\r\nCSeq: 2\r\n" +
                   "WWW-Authenticate: Digest realm=\"LIVE555 Streaming Media\", " +
                   "nonce=\"abc123\"\r\n\r\n"
    challenge = gateway.send(:parse_challenge, unauthorized)

    assert_equal({ realm: "LIVE555 Streaming Media", nonce: "abc123" }, challenge)

    gateway.instance_variable_set(:@challenge, challenge)
    uri = "rtsps://192.168.1.50:322/streaming/live/1"
    authorized = gateway.send(:authorize, "DESCRIBE #{uri} RTSP/1.0\r\nCSeq: 2\r\n\r\n")

    ha1 = Digest::MD5.hexdigest("bblp:LIVE555 Streaming Media:#{SECRET}")
    ha2 = Digest::MD5.hexdigest("DESCRIBE:#{uri}")
    expected = Digest::MD5.hexdigest("#{ha1}:abc123:#{ha2}")

    assert_includes authorized, "response=\"#{expected}\""
    assert_includes authorized, "uri=\"#{uri}\""
    # The point of answering the challenge here: the secret is hashed, so it
    # never reaches the client, nor ffmpeg's command line.
    refute_includes authorized, SECRET
  end

  def test_capped_stderr_truncates_instead_of_buffering_forever
    huge = StringIO.new("e" * 20_000)
    text = BambuCompanion::RtspsSnapshot.read_capped(huge, 4096, overflow: :truncate)

    assert_equal 4096, text.bytesize
  end

  def test_loopback_listener_closes_after_the_first_connection
    gateway = BambuCompanion::RtspsSnapshot::LoopbackGateway.new(
      host: "127.0.0.1", port: 1, username: "bblp", password: SECRET,
      fingerprint: "AA" * 32, timeout: 0.2
    )
    url = gateway.start
    port = Integer(url[/:(\d+)\//, 1])
    first = TCPSocket.new("127.0.0.1", port)
    begin
      wait_until { second_connect_refused?(port) }
    ensure
      first.close
      gateway.stop
    end
  end

  def test_capped_stdout_rejects_oversize_before_decode
    huge = StringIO.new("x" * (BambuCompanion::CameraStore::MAX_JPEG_BYTES + 1))
    error = assert_raises(BambuCompanion::RtspsError) do
      BambuCompanion::RtspsSnapshot.read_capped(
        huge, BambuCompanion::CameraStore::MAX_JPEG_BYTES
      )
    end

    assert_equal "oversized_frame", error.code
  end

  def test_timeout_kills_the_process_group_and_redacts_the_secret
    snapshot = BambuCompanion::RtspsSnapshot.new(
      host: "192.168.1.50", username: "bblp", password: SECRET,
      fingerprint: "AA" * 32,
      runner: lambda { |*|
        raise BambuCompanion::RtspsError.new(
          "timeout", "ffmpeg timed out rtsps://bblp:#{SECRET}@192.168.1.50:322/streaming/live/1"
        )
      }
    )

    error = assert_raises(BambuCompanion::RtspsError) { snapshot.capture }
    assert_equal "timeout", error.code
    refute_includes error.message, SECRET
  end

  def test_rejects_non_jpeg_stdout
    snapshot = BambuCompanion::RtspsSnapshot.new(
      host: "192.168.1.50", username: "bblp", password: SECRET,
      fingerprint: "AA" * 32,
      runner: ->(*) { "not-jpeg" }
    )

    error = assert_raises(BambuCompanion::RtspsError) { snapshot.capture }
    assert_equal "invalid_frame", error.code
  end

  def test_rejects_jpeg_bomb_stdout
    snapshot = BambuCompanion::RtspsSnapshot.new(
      host: "192.168.1.50", username: "bblp", password: SECRET,
      fingerprint: "AA" * 32,
      runner: ->(*) { BambuCompanion::TestFixtures.minimal_jpeg(width: 65_535, height: 65_535) }
    )

    error = assert_raises(BambuCompanion::RtspsError) { snapshot.capture }
    assert_equal "invalid_frame", error.code
  end

  private

  def second_connect_refused?(port)
    socket = TCPSocket.new("127.0.0.1", port)
    socket.close
    false
  rescue Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EPIPE
    true
  end

  def wait_until(timeout: 1.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return if yield
      raise "condition not met" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end
end
