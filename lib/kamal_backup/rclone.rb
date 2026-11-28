# frozen_string_literal: true

require_relative 'command'
require_relative 'restic'

module KamalBackup
  # Copies one rclone remote to another, for example a Cloudflare R2 bucket to
  # an AWS S3 bucket. Remotes are configured with rclone's own
  # RCLONE_CONFIG_<REMOTE>_* variables or an rclone config file.
  class Rclone
    COPY_FLAGS = %w[--fast-list].freeze

    attr_reader :config, :redactor

    def initialize(config, redactor:, runner: nil)
      @config = config
      @redactor = redactor
      @runner = runner
    end

    def copy(source, destination)
      log("copying #{source} to #{destination}")
      run(['copy', source, destination] + COPY_FLAGS)
    end

    private

    def run(args)
      return @runner.call(args, env: rclone_env) if @runner

      Command.capture(CommandSpec.new(argv: ['rclone'] + args, env: rclone_env), redactor: redactor)
    end

    def rclone_env
      Restic.environment_for(config)
    end

    def log(message)
      if Command.output
        Command.output.info(message, redactor: redactor)
      else
        $stdout.puts("[kamal-backup] #{redactor.redact_string(message)}")
      end
    end
  end
end
