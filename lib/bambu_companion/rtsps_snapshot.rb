# frozen_string_literal: true

require "cgi"
require "open3"
require "socket"
require "timeout"
require_relative "camera_store"
require_relative "tls_certificate"

module BambuCompanion
  class RtspsError < StandardError
    attr_reader :code

    def initialize(code, message)
      @code = String(code)
      super(message)
    end
  end

  class RtspsSnapshot
    PORT = 322
    PATH = "/streaming/live/1"
    TIMEOUT = 8.0
    KILL_GRACE_SECONDS = 0.5
    READ_CHUNK_BYTES = 16_384

    def self.ffmpeg_available?(resolver = nil)
      path = (resolver || method(:find_ffmpeg)).call
      !(path.nil? || path.to_s.empty?)
    end

    def self.find_ffmpeg
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
        next if dir.empty?

        candidate = File.join(dir, "ffmpeg")
        return candidate if File.executable?(candidate)
      end
      nil
    end

    def self.read_capped(io, max, overflow: :reject)
      limit = Integer(max)
      buffer = String.new(encoding: Encoding::BINARY)
      loop do
        remaining = limit + 1 - buffer.bytesize
        break if remaining <= 0

        chunk = io.read([READ_CHUNK_BYTES, remaining].min)
        break if chunk.nil? || chunk.empty?

        buffer << chunk.b
        next unless buffer.bytesize > limit
        return buffer.byteslice(0, limit) if overflow == :truncate

        raise RtspsError.new("oversized_frame", "Camera snapshot exceeds the size limit")
      end
      buffer
    end

    def self.rewrite_rtsp(data, from_prefix, to_prefix)
      String(data).b.gsub(from_prefix.b, to_prefix.b)
    end

    def initialize(host:, username:, password:, fingerprint:,
                   port: PORT, timeout: TIMEOUT, runner: nil)
      @host = String(host)
      @port = Integer(port)
      @username = String(username)
      @password = String(password)
      @fingerprint = fingerprint
      @timeout = timeout
      @runner = runner
    end

    def capture
      jpeg = @runner ? capture_via_runner : capture_via_loopback
      validate!(jpeg)
      String(jpeg).b
    rescue RtspsError => error
      raise RtspsError.new(error.code, redact(error.message)), cause: nil
    end

    private

    def capture_via_runner
      @runner.call(
        ffmpeg_argv(public_url), password: @password, env: ENV, timeout: @timeout
      )
    end

    def capture_via_loopback
      gateway = LoopbackGateway.new(
        host: @host, port: @port, username: @username, password: @password,
        fingerprint: @fingerprint, timeout: @timeout
      )
      input = gateway.start
      begin
        run_ffmpeg(ffmpeg_argv(input), timeout: @timeout)
      ensure
        gateway.stop
      end
    end

    def ffmpeg_argv(input_url)
      [
        "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
        "-rtsp_transport", "tcp", "-timeout", "5000000",
        "-threads", "1", "-an",
        "-i", input_url,
        "-frames:v", "1",
        "-vf", "scale='min(960,iw)':-2",
        "-f", "image2", "-q:v", "5", "pipe:1"
      ]
    end

    def public_url
      "rtsps://#{@username}@#{@host}:#{@port}#{PATH}"
    end

    def validate!(jpeg)
      data = String(jpeg).b
      if data.bytesize > CameraStore::MAX_JPEG_BYTES
        raise RtspsError.new("oversized_frame", "Camera snapshot exceeds the size limit")
      end
      return if CameraStore.valid_jpeg?(data)

      raise RtspsError.new("invalid_frame", "Camera snapshot was not a JPEG still")
    end

    def run_ffmpeg(argv, timeout:)
      stdin, stdout, stderr, wait = Open3.popen3(*argv, pgroup: true)
      begin
        Timeout.timeout(timeout) do
          output = self.class.read_capped(stdout, CameraStore::MAX_JPEG_BYTES)
          status = wait.value
          unless status.success?
            detail = self.class.read_capped(stderr, 4096, overflow: :truncate)
            raise RtspsError.new(
              "capture_failed",
              redact("ffmpeg exited #{status.exitstatus}: #{detail}")
            )
          end
          output
        end
      rescue Timeout::Error
        kill_group(wait.pid)
        raise RtspsError.new("timeout", "Camera snapshot timed out")
      ensure
        [stdin, stdout, stderr].each do |io|
          io.close
        rescue StandardError
          nil
        end
      end
    end

    def kill_group(pid)
      Process.kill("-TERM", pid)
      begin
        Timeout.timeout(KILL_GRACE_SECONDS) { Process.wait(pid) }
      rescue Timeout::Error
        Process.kill("-KILL", pid)
        Process.wait(pid)
      end
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    def redact(text)
      String(text).gsub(@password, "[REDACTED]").gsub(CGI.escape(@password), "[REDACTED]")
    end

    class LoopbackGateway
      def initialize(host:, port:, username:, password:, fingerprint:, timeout:)
        @host = host
        @port = port
        @username = username
        @password = password
        @fingerprint = fingerprint
        @timeout = timeout
        @stop = false
      end

      def start
        @server = TCPServer.new("127.0.0.1", 0)
        @local_port = @server.addr[1]
        @thread = Thread.new { serve }
        @thread.report_on_exception = false
        "rtsp://127.0.0.1:#{@local_port}#{PATH}"
      end

      def stop
        @stop = true
        [@server, @local, @remote].each do |socket|
          socket&.close
        rescue StandardError
          nil
        end
        @thread&.join(KILL_GRACE_SECONDS)
      end

      private

      def serve
        @local = @server.accept
        begin
          @server.close
        ensure
          @server = nil
        end
        return unless local_peer?(@local)

        @remote = TlsCertificate.open_pinned(
          host: @host, port: @port, fingerprint: @fingerprint,
          connect_timeout: @timeout
        )
        from = "rtsp://127.0.0.1:#{@local_port}"
        to = "rtsp://#{@username}:#{CGI.escape(@password)}@#{@host}:#{@port}"
        loop do
          break if @stop

          ready, = IO.select([@local, @remote], nil, nil, 0.2)
          next unless ready

          closed = false
          ready.each do |socket|
            data = socket.recv_nonblock(READ_CHUNK_BYTES, exception: false)
            if data.nil? || data.empty?
              closed = true
              break
            end
            next if data == :wait_readable

            if socket.equal?(@local)
              @remote.write(RtspsSnapshot.rewrite_rtsp(data, from, to))
            else
              @local.write(data)
            end
          end
          break if closed
        end
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError, TlsCertificateError
        nil
      end

      def local_peer?(socket)
        ip = socket.peeraddr[3]
        ip == "127.0.0.1" || ip == "::1"
      rescue StandardError
        false
      end
    end
  end
end
