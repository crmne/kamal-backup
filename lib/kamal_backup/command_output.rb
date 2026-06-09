# frozen_string_literal: true

require 'securerandom'

module KamalBackup
  class CommandOutput
    LEVELS = {
      'DEBUG' => 0,
      'INFO' => 1,
      'WARN' => 2,
      'ERROR' => 3,
      'FATAL' => 4
    }.freeze
    LEVEL_COLORS = {
      'DEBUG' => :black,
      'INFO' => :blue,
      'WARN' => :yellow,
      'ERROR' => :red,
      'FATAL' => :red
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
      write_message('INFO', redactor.redact_string(message))
    end

    def error(message, redactor:)
      write_message('ERROR', colorize(redactor.redact_string(message), :red, :bold))
    end

    def decorate(value, color, mode = nil)
      colorize(value, color, mode)
    end

    def command_start(spec, redactor:)
      id = SecureRandom.hex(4)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      display = spec.display(redactor)

      write_message('INFO', "Running #{colorize(display, :yellow, :bold)} #{target_for(spec)}", id)
      write_message('DEBUG', "Command: #{colorize(display, :blue)}", id)

      { id: id, started_at: started_at, redactor: redactor }
    end

    def command_output(context, stream, data, redactor:)
      raw = data.to_s
      return if raw.empty?
      return unless log_level?('DEBUG')

      synchronize do
        key = [context.fetch(:id), stream]
        @buffers[key] = "#{@buffers[key]}#{raw}"
        flush_complete_output_lines(context, key, redactor: redactor)
      end
    end

    def command_exit(context, status)
      runtime = Process.clock_gettime(Process::CLOCK_MONOTONIC) - context.fetch(:started_at)
      result = status.to_i.zero? ? 'successful' : 'failed'
      result_color = status.to_i.zero? ? :green : :red

      synchronize do
        flush_output_buffers(context)
        message = "Finished in #{format('%.3f seconds', runtime)} with exit status #{status} " \
                  "(#{colorize(result, result_color, :bold)})."
        write_message_unlocked('INFO', message, context.fetch(:id))
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
      output = +''

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
        write_message_unlocked('DEBUG', colorize("\t#{line}".chomp, color), context.fetch(:id))
      end
      @io.flush if @io.respond_to?(:flush)
    end

    def format_message(level, message, id = nil)
      message = "[#{colorize(id, :green)}] #{message}" if id
      "#{colorize(level.rjust(6), LEVEL_COLORS.fetch(level))} #{message}"
    end

    def local_target
      if (remote_host = @env['KAMAL_HOST'].to_s) && !remote_host.empty?
        return "on #{colorize(remote_host, :blue)}"
      end

      user = @env['USER'].to_s.empty? ? @env['USERNAME'].to_s : @env['USER'].to_s

      if user.empty?
        "on #{colorize('localhost', :blue)}"
      else
        "as #{colorize(user, :blue)}@#{colorize('localhost', :blue)}"
      end
    end

    def target_for(spec)
      if spec.host
        "on #{colorize(spec.host, :blue)}"
      else
        local_target
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
      @env['SSHKIT_COLOR'] || (@io.respond_to?(:tty?) && @io.tty?)
    end
  end
end
