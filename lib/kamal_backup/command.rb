require "open3"
require "securerandom"
require "shellwords"
require_relative "errors"

module KamalBackup
  class CommandSpec
    attr_reader :argv, :env

    def initialize(argv:, env: {})
      @argv = Array(argv).compact.map(&:to_s)
      @env = env.each_with_object({}) do |(key, value), result|
        next if value.nil? || value.to_s.empty?

        result[key.to_s] = value.to_s
      end

      raise ArgumentError, "command argv cannot be empty" if @argv.empty?
    end

    def display(redactor)
      env_prefix = env.keys.sort.map { |key| "#{key}=#{redactor.redact_value(key, env[key])}" }
      redactor.redact_string((env_prefix + [argv.shelljoin]).join(" "))
    end
  end

  CommandResult = Struct.new(:stdout, :stderr, :status, :streamed, keyword_init: true)

  class CommandOutput
    LEVELS = {
      "DEBUG" => 0,
      "INFO" => 1,
      "WARN" => 2,
      "ERROR" => 3,
      "FATAL" => 4
    }.freeze
    LEVEL_COLORS = {
      "DEBUG" => :black,
      "INFO" => :blue,
      "WARN" => :yellow,
      "ERROR" => :red,
      "FATAL" => :red
    }.freeze
    COLOR_CODES = {
      black: 30,
      red: 31,
      green: 32,
      yellow: 33,
      blue: 34,
      magenta: 35,
      cyan: 36,
      white: 37,
      light_black: 90,
      light_red: 91,
      light_green: 92,
      light_yellow: 93,
      light_blue: 94,
      light_magenta: 95,
      light_cyan: 96,
      light_white: 97
    }.freeze

    def initialize(io: $stdout, env: ENV, verbosity: :info)
      @io = io
      @env = env
      @verbosity = LEVELS.fetch(verbosity.to_s.upcase)
      @mutex = Mutex.new
      @buffers = {}
    end

    def info(message, redactor:)
      write_message("INFO", redactor.redact_string(message))
    end

    def error(message, redactor:)
      write_message("ERROR", colorize(redactor.redact_string(message), :red, :bold))
    end

    def decorate(value, color, mode = nil)
      colorize(value, color, mode)
    end

    def command_start(spec, redactor:)
      id = SecureRandom.hex(4)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      display = spec.display(redactor)

      write_message("INFO", "Running #{colorize(display, :yellow, :bold)} #{local_target}", id)
      write_message("DEBUG", "Command: #{colorize(display, :blue)}", id)

      { id: id, started_at: started_at, redactor: redactor }
    end

    def command_output(context, _stream, data, redactor:)
      raw = data.to_s
      return if raw.empty?
      return unless log_level?("DEBUG")

      synchronize do
        key = [context.fetch(:id), _stream]
        @buffers[key] = "#{@buffers[key]}#{raw}"
        flush_complete_output_lines(context, key, redactor: redactor)
      end
    end

    def command_exit(context, status)
      runtime = Process.clock_gettime(Process::CLOCK_MONOTONIC) - context.fetch(:started_at)
      result = status.to_i.zero? ? "successful" : "failed"
      result_color = status.to_i.zero? ? :green : :red

      synchronize do
        flush_output_buffers(context)
        write_message_unlocked("INFO", "Finished in #{format("%.3f seconds", runtime)} with exit status #{status} (#{colorize(result, result_color, :bold)}).", context.fetch(:id))
      end
    end

    private
      def write_message(level, message, id = nil)
        return unless log_level?(level)

        synchronize { write_message_unlocked(level, message, id) }
      end

      def write_message_unlocked(level, message, id = nil)
        @io.puts(format_message(level, message, id)) if log_level?(level)
      end

      def synchronize(&block)
        @mutex.synchronize(&block)
      end

      def flush_complete_output_lines(context, key, redactor:)
        buffer = @buffers.fetch(key)
        output = +""

        while (index = buffer.index("\n"))
          output << buffer.slice!(0..index)
        end

        @buffers[key] = buffer
        write_output(context, output, redactor: redactor, stream: key.last) unless output.empty?
      end

      def flush_output_buffers(context)
        id = context.fetch(:id)
        keys = @buffers.keys.select { |key_id, _stream| key_id == id }

        keys.each do |key|
          output = @buffers.delete(key)
          next if output.to_s.empty?

          write_output(context, output, redactor: context.fetch(:redactor), stream: key.last)
        end
      end

      def write_output(context, output, redactor:, stream: nil)
        color = stream == :stderr ? :red : :green

        redactor.redact_string(output).each_line do |line|
          write_message_unlocked("DEBUG", colorize("\t#{line}".chomp, color), context.fetch(:id))
        end
        @io.flush if @io.respond_to?(:flush)
      end

      def format_message(level, message, id = nil)
        message = "[#{colorize(id, :green)}] #{message}" if id
        "#{colorize(level.rjust(6), LEVEL_COLORS.fetch(level))} #{message}"
      end

      def local_target
        user = @env["USER"].to_s.empty? ? @env["USERNAME"].to_s : @env["USER"].to_s

        if user.empty?
          "on #{colorize("localhost", :blue)}"
        else
          "as #{colorize(user, :blue)}@#{colorize("localhost", :blue)}"
        end
      end

      def log_level?(level)
        LEVELS.fetch(level) >= @verbosity
      end

      def colorize(value, color, mode = nil)
        string = value.to_s
        return string unless colorize?
        return string unless COLOR_CODES.key?(color)

        prefix = mode == :bold ? "\e[1;" : "\e[0;"
        "#{prefix}#{COLOR_CODES.fetch(color)};49m#{string}\e[0m"
      end

      def colorize?
        @env["SSHKIT_COLOR"] || (@io.respond_to?(:tty?) && @io.tty?)
      end
  end

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
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
          path = File.join(dir, name)
          File.executable?(path) && !File.directory?(path)
        end
      end

      def capture(spec, input: nil, redactor:, log: true, log_output: true, tee_stdout: nil, tee_stderr: nil)
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
        result = CommandResult.new(stdout: stdout, stderr: stderr, status: status.exitstatus, streamed: !!(tee_stdout || tee_stderr))

        if status.success?
          result
        else
          raise command_failure(spec, status.exitstatus, stdout, stderr, redactor)
        end
      rescue Errno::ENOENT => e
        raise command_not_found(spec, e)
      end

      def collect_stream(io, command_output: self.output, context: nil, stream: :stdout, log_output: true, tee_io: nil, redactor: nil)
        captured_output = +""
        tee_buffer = +""

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

          if status.success?
            result
          else
            raise command_failure(spec, status.exitstatus, stdout, stderr, redactor)
          end
        end

        def popen_capture(spec, input:, redactor:, output:, context:, log_output:, tee_stdout:, tee_stderr:)
          Open3.popen3(spec.env, *spec.argv) do |stdin, stdout, stderr, wait_thread|
            stdin_writer = Thread.new do
              stdin.write(input) if input
            ensure
              stdin.close unless stdin.closed?
            end
            stdout_reader = Thread.new do
              collect_stream(stdout, command_output: output, context: context, stream: :stdout, log_output: log_output, tee_io: tee_stdout, redactor: redactor)
            end
            stderr_reader = Thread.new do
              collect_stream(stderr, command_output: output, context: context, stream: :stderr, log_output: log_output, tee_io: tee_stderr, redactor: redactor)
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
