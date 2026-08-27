# frozen_string_literal: true

require "cgi"
require "digest"
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

    RTSP_METHODS = %w[
      OPTIONS DESCRIBE ANNOUNCE SETUP PLAY PAUSE TEARDOWN
      GET_PARAMETER SET_PARAMETER RECORD REDIRECT
    ].freeze

    def self.request?(bytes)
      RTSP_METHODS.any? { |method| bytes.start_with?("#{method} ") }
    end

    # Substitute in the request line only. The previous whole-message gsub also
    # rewrote the uri="..." inside an Authorization header; RTSP Digest hashes
    # that value, so altering it guaranteed a mismatch and a 401 that no
    # credential could satisfy. Leaving the remainder untouched also preserves
    # the printer's own absolute URLs once it has redirected the client.
    def self.rewrite_rtsp(data, from_prefix, to_prefix)
      bytes = String(data).b
      return bytes unless request?(bytes)

      head, separator, rest = bytes.partition("\r\n".b)
      return bytes if separator.empty?

      head.gsub(from_prefix.b, to_prefix.b) + separator + rest
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
        # The upstream URL carries no userinfo: LIVE555 (the RTSP server on X1
        # and H2 hardware) answers with a Digest challenge, which credentials in
        # the request line do not satisfy. This gateway answers the challenge on
        # the client's behalf, so the password still never reaches ffmpeg's argv.
        from = "rtsp://127.0.0.1:#{@local_port}"
        to = "rtsps://#{@host}:#{@port}"
        loop do
          break if @stop

          ready, = IO.select([@local, @remote], nil, nil, 0.2)
          next unless ready

          closed = false
          ready.each do |socket|
            data = socket.read_nonblock(READ_CHUNK_BYTES, exception: false)
            if data.nil? || data.empty?
              closed = true
              break
            end
            next if data == :wait_readable

            if socket.equal?(@local)
              forward_request(RtspsSnapshot.rewrite_rtsp(data, from, to))
            else
              closed = true unless forward_response(data)
            end
          end
          break if closed
        end
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError, TlsCertificateError
        nil
      end

      # Send a request upstream, carrying an Authorization header once a
      # challenge has been seen. The request is retained so a 401 can be
      # answered by replaying it rather than surfacing the failure to ffmpeg,
      # which has no credentials of its own by design.
      def forward_request(bytes)
        if RtspsSnapshot.request?(bytes)
          @pending = bytes
          @retried = false
          bytes = authorize(bytes) if @challenge
        end
        @remote.write(bytes)
        true
      end

      # Returns false when the caller should treat the connection as finished.
      def forward_response(bytes)
        if !@retried && @pending && bytes.start_with?("RTSP/".b)
          challenge = parse_challenge(bytes)
          if challenge
            @challenge = challenge
            @retried = true
            @remote.write(authorize(@pending))
            return true
          end
        end
        @local.write(bytes)
        true
      end

      def parse_challenge(bytes)
        return nil unless bytes[/\ARTSP\/\d\.\d 401\b/]

        header = bytes[/^WWW-Authenticate:\s*Digest\s*(.+)$/i, 1]
        return nil unless header

        realm = header[/realm="([^"]*)"/i, 1]
        nonce = header[/nonce="([^"]*)"/i, 1]
        return nil unless realm && nonce

        { realm: realm, nonce: nonce }
      end

      def authorize(bytes)
        head, separator, rest = bytes.partition("\r\n\r\n".b)
        return bytes if separator.empty?

        line, _, headers = head.partition("\r\n".b)
        method, uri = line.split(" ", 3)
        return bytes if method.nil? || uri.nil?

        headers = headers.gsub(/^Authorization:.*\r\n?/i, "")
        headers += "\r\n" unless headers.empty? || headers.end_with?("\r\n")
        "#{line}\r\n#{headers}#{authorization(method, uri)}\r\n#{separator}#{rest}"
      end

      def authorization(method, uri)
        ha1 = Digest::MD5.hexdigest("#{@username}:#{@challenge[:realm]}:#{@password}")
        ha2 = Digest::MD5.hexdigest("#{method}:#{uri}")
        response = Digest::MD5.hexdigest("#{ha1}:#{@challenge[:nonce]}:#{ha2}")
        %(Authorization: Digest username="#{@username}", ) +
          %(realm="#{@challenge[:realm]}", nonce="#{@challenge[:nonce]}", ) +
          %(uri="#{uri}", response="#{response}")
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
