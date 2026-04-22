require "open3"
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
      redactor.redact_string((env_prefix + argv).join(" "))
    end
  end

  CommandResult = Struct.new(:stdout, :stderr, :status, keyword_init: true)

  class Command
    def self.capture(spec, input: nil, redactor:)
      stdout, stderr, status = Open3.capture3(spec.env, *spec.argv, stdin_data: input)
      result = CommandResult.new(stdout: stdout, stderr: stderr, status: status.exitstatus)
      return result if status.success?

      raise CommandError.new(
        "command failed (#{status.exitstatus}): #{spec.display(redactor)}\n#{redactor.redact_string(stderr)}",
        command: spec,
        status: status.exitstatus,
        stdout: redactor.redact_string(stdout),
        stderr: redactor.redact_string(stderr)
      )
    rescue Errno::ENOENT => e
      raise CommandError.new(
        "command not found: #{spec.argv.first}",
        command: spec,
        status: 127,
        stderr: e.message
      )
    end
  end
end
