# frozen_string_literal: true

require 'open3'
require 'pty'
require 'shellwords'
require_relative 'errors'

module KamalBackup
  class CommandSpec
    attr_reader :argv, :env, :host

    def initialize(argv:, env: {}, host: nil)
      @argv = Array(argv).compact.map(&:to_s)
      @host = host.to_s unless host.to_s.empty?
      @env = env.each_with_object({}) do |(key, value), result|
        next if value.nil? || value.to_s.empty?

        result[key.to_s] = value.to_s
      end

      raise ArgumentError, 'command argv cannot be empty' if @argv.empty?
    end

    def display(redactor)
      env_prefix = env.keys.sort.map { |key| "#{key}=#{redactor.redact_value(key, env[key])}" }
      redactor.redact_string((env_prefix + [argv.shelljoin]).join(' '))
    end
  end

  CommandResult = Struct.new(:stdout, :stderr, :status, :streamed, keyword_init: true)

  class Command
    class << self
      attr_accessor :output

      def with_output(output)
        previous_output = self.output
        self.output = output
        yield
      ensure
        self.output = previous_output
      end

      def available?(name)
        ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? do |dir|
          path = File.join(dir, name)
          File.executable?(path) && !File.directory?(path)
        end
      end

      def capture(spec, redactor:, input: nil, log: true, log_output: true, tee_stdout: nil, tee_stderr: nil)
        output = log ? self.output : nil
        return capture_quietly(spec, input: input, redactor: redactor) unless output || tee_stdout || tee_stderr

        context = output&.command_start(spec, redactor: redactor)
        stdout, stderr, status = popen_capture(
          spec,
          input: input,
          redactor: redactor,
          output: output,
          context: context,
          log_output: log_output,
          tee_stdout: tee_stdout,
          tee_stderr: tee_stderr
        )
        output&.command_exit(context, status.exitstatus)
        result = CommandResult.new(stdout: stdout, stderr: stderr, status: status.exitstatus,
                                   streamed: !(tee_stdout || tee_stderr).nil?)

        raise command_failure(spec, status.exitstatus, stdout, stderr, redactor) unless status.success?

        result
      rescue Errno::ENOENT => e
        raise command_not_found(spec, e)
      end

      def capture_pty(spec, redactor:, tee_stdout: nil)
        output = +''
        tee_buffer = +''
        result = nil

        PTY.spawn(spec.env, *spec.argv) do |reader, writer, pid|
          writer.close

          begin
            loop do
              chunk = reader.readpartial(16 * 1024)
              output << chunk
              tee_buffer = tee_stream(tee_stdout, redactor, tee_buffer, chunk) if tee_stdout
            end
          rescue EOFError, Errno::EIO
            flush_tee_stream(tee_stdout, redactor, tee_buffer) if tee_stdout
          ensure
            reader.close unless reader.closed?
          end

          _, status = Process.wait2(pid)
          result = CommandResult.new(stdout: output, stderr: '', status: status.exitstatus, streamed: !tee_stdout.nil?)

          raise command_failure(spec, status.exitstatus, output, output, redactor) unless status.success?
        end

        result
      rescue Errno::ENOENT => e
        raise command_not_found(spec, e)
      end

      def collect_stream(io, command_output: output, context: nil, stream: :stdout, log_output: true, tee_io: nil,
                         redactor: nil)
        captured_output = +''
        tee_buffer = +''

        loop do
          chunk = io.readpartial(16 * 1024)
          captured_output << chunk
          command_output&.command_output(context, stream, chunk, redactor: redactor) if log_output && context
          tee_buffer = tee_stream(tee_io, redactor, tee_buffer, chunk) if tee_io
        rescue EOFError
          flush_tee_stream(tee_io, redactor, tee_buffer) if tee_io
          break
        end

        captured_output
      end

      private

      def tee_stream(io, redactor, buffer, chunk)
        buffer << chunk

        while (index = buffer.index("\n"))
          io.print(redactor.redact_string(buffer.slice!(0..index)))
        end

        io.flush if io.respond_to?(:flush)
        buffer
      end

      def flush_tee_stream(io, redactor, buffer)
        return if buffer.empty?

        io.print(redactor.redact_string(buffer))
        io.flush if io.respond_to?(:flush)
      end

      def capture_quietly(spec, input:, redactor:)
        stdout, stderr, status = Open3.capture3(spec.env, *spec.argv, stdin_data: input)
        result = CommandResult.new(stdout: stdout, stderr: stderr, status: status.exitstatus, streamed: false)

        raise command_failure(spec, status.exitstatus, stdout, stderr, redactor) unless status.success?

        result
      end

      def popen_capture(spec, input:, redactor:, output:, context:, log_output:, tee_stdout:, tee_stderr:)
        Open3.popen3(spec.env, *spec.argv) do |stdin, stdout, stderr, wait_thread|
          stdin_writer = Thread.new do
            stdin.write(input) if input
          ensure
            stdin.close unless stdin.closed?
          end
          stdout_reader = Thread.new do
            collect_stream(stdout, command_output: output, context: context, stream: :stdout, log_output: log_output,
                                   tee_io: tee_stdout, redactor: redactor)
          end
          stderr_reader = Thread.new do
            collect_stream(stderr, command_output: output, context: context, stream: :stderr, log_output: log_output,
                                   tee_io: tee_stderr, redactor: redactor)
          end

          stdin_writer.join
          [stdout_reader.value, stderr_reader.value, wait_thread.value]
        end
      end

      def command_failure(spec, status, stdout, stderr, redactor)
        CommandError.new(
          "command failed (#{status}): #{spec.display(redactor)}\n#{redactor.redact_string(stderr)}",
          command: spec,
          status: status,
          stdout: redactor.redact_string(stdout),
          stderr: redactor.redact_string(stderr)
        )
      end

      def command_not_found(spec, error)
        CommandError.new(
          "command not found: #{spec.argv.first}",
          command: spec,
          status: 127,
          stderr: error.message
        )
      end
    end
  end
end
