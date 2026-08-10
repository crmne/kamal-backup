# frozen_string_literal: true

require 'json'
require 'thor'
require_relative 'app'
require_relative 'cli/helpers'
require_relative 'command_output'
require_relative 'config'
require_relative 'kamal_bridge'
require_relative 'redactor'
require_relative 'version'

module KamalBackup
  class CLI < Thor
    class CommandBase < Thor
      include Helpers

      class_option :yes, aliases: '-y', type: :boolean, default: false, desc: 'Skip confirmation prompt'
      class_option :config_file, aliases: '-c', type: :string, desc: 'Path to Kamal deploy config file'
      class_option :destination, aliases: '-d', type: :string, desc: 'Kamal destination to use'
      remove_command :tree
    end

    class RestoreCLI < CommandBase
      def self.basename
        CLI.basename
      end

      desc 'local [SNAPSHOT]', 'Restore the backup into the local database and configured file paths'
      def local(snapshot = 'latest')
        confirm!("Restore #{snapshot} into the local database and configured file paths? This will overwrite local data.")
        puts(JSON.pretty_generate(local_restore_app.restore_to_local_machine(snapshot)))
      end

      method_option :"confirm-production-restore", type: :boolean, default: false,
                                                   desc: 'Confirm production restore without interactive prompts'
      desc 'production [SNAPSHOT]', 'Restore the backup into the production database and configured file paths'
      def production(snapshot = 'latest')
        confirm_production_restore!(snapshot)

        if deployment_mode?
          exec_remote(['kamal-backup', 'restore', 'production', snapshot, '--confirm-production-restore'])
        else
          puts(JSON.pretty_generate(direct_app.restore_to_production(snapshot)))
        end
      end
    end

    class DrillCLI < CommandBase
      def self.basename
        CLI.basename
      end

      method_option :check, type: :string, desc: 'Run a verification command after the restore'
      desc 'local [SNAPSHOT]', 'Run a restore drill on the local machine'
      def local(snapshot = 'latest')
        confirm!("Run a local restore drill for #{snapshot}? This will overwrite local data.")
        result = local_restore_app.drill_on_local_machine(snapshot, check_command: options[:check])
        puts(JSON.pretty_generate(result))
        exit(1) unless result[:status] == 'ok'
      end

      method_option :database, type: :string, desc: 'Scratch database name for PostgreSQL or MySQL'
      method_option :"sqlite-path", type: :string, desc: 'Scratch SQLite path for production-side drills'
      method_option :files, type: :string, default: '/restore/files',
                            desc: 'Scratch Active Storage target for the drill'
      method_option :check, type: :string, desc: 'Run a verification command after the restore'
      desc 'production [SNAPSHOT]', 'Run a restore drill on production infrastructure using scratch targets'
      def production(snapshot = 'latest')
        confirm!("Run a production-side restore drill for #{snapshot}? This will restore into scratch targets on production infrastructure.")

        if deployment_mode?
          argv = ['kamal-backup', 'drill', 'production', snapshot, '--files', options[:files], '--yes']
          argv.concat(['--database', production_database_name]) if production_database_name
          argv.concat(['--sqlite-path', options[:"sqlite-path"]]) if options[:"sqlite-path"]
          argv.concat(['--check', options[:check]]) if options[:check]
          exec_remote(argv)
        else
          result = direct_app.drill_on_production(
            snapshot,
            database_name: production_database_name,
            sqlite_path: options[:"sqlite-path"],
            file_target: options[:files],
            check_command: options[:check]
          )
          puts(JSON.pretty_generate(result))
          exit(1) unless result[:status] == 'ok'
        end
      end

      no_commands do
        def production_database_name
          if local_command_config.database_adapter == 'sqlite'
            nil
          else
            options[:database] || prompt_required('Scratch database name')
          end
        end
      end
    end

    class << self
      attr_accessor :command_env

      def normalize_global_options(argv)
        tokens = Array(argv).dup
        leading = []

        while tokens.any?
          token = tokens.first

          case token
          when '-d', '--destination', '-c', '--config-file'
            leading << tokens.shift
            leading << tokens.shift if tokens.any?
          when /\A--destination=.+\z/, /\A--config-file=.+\z/
            leading << tokens.shift
          else
            break
          end
        end

        if leading.empty? || tokens.empty?
          Array(argv)
        else
          [tokens.shift, *leading, *tokens]
        end
      end
    end

    package_name 'kamal-backup'
    map %w[-v --version] => :version
    class_option :config_file, aliases: '-c', type: :string, desc: 'Path to Kamal deploy config file'
    class_option :destination, aliases: '-d', type: :string, desc: 'Kamal destination to use'
    remove_command :tree
    desc 'restore SUBCOMMAND ...ARGS', 'Restore database and configured file backups locally or into production'
    subcommand 'restore', RestoreCLI
    desc 'drill SUBCOMMAND ...ARGS', 'Run a restore drill on the local machine or on production infrastructure'
    subcommand 'drill', DrillCLI

    def self.basename
      'kamal-backup'
    end

    def self.start(argv = ARGV, env: ENV)
      self.command_env = env
      output = CommandOutput.new(io: $stderr, env: env)
      Command.with_output(output) do
        super(normalize_global_options(argv))
      end
    rescue StandardError => e
      output.error("(#{e.class}): #{e.message}", redactor: Redactor.new(env: env))
      exit(1)
    rescue Interrupt
      output.error('(Interrupt): interrupted', redactor: Redactor.new(env: env))
      exit(130)
    ensure
      self.command_env = nil
    end

    include Helpers

    method_option :force, type: :boolean, default: false,
                          desc: 'Run a backup even if the configured schedule is not due'
    desc 'backup', 'Run a due database and configured file backup'
    def backup
      if remote_command_mode?
        argv = %w[kamal-backup backup]
        argv << '--force' if options[:force]
        exec_remote(argv)
      else
        print_backup_result(direct_app.backup(force: options[:force]))
      end
    end

    desc 'list', 'List matching restic snapshots'
    def list
      if remote_command_mode?
        exec_remote(%w[kamal-backup list])
      else
        puts(direct_app.snapshots)
      end
    end

    desc 'check', 'Run restic check and record the latest result'
    def check
      if remote_command_mode?
        exec_remote(%w[kamal-backup check])
      else
        puts(direct_app.check)
      end
    end

    desc 'unlock', 'Clear stale restic repository locks'
    def unlock
      if remote_command_mode?
        exec_remote(%w[kamal-backup unlock])
      else
        print(direct_app.unlock)
      end
    end

    desc 'prune', 'Apply the configured restic retention policy and prune unneeded data'
    def prune
      if remote_command_mode?
        exec_remote(%w[kamal-backup prune])
      else
        print_prune_result(direct_app.prune)
      end
    end

    desc 'evidence', 'Print redacted backup, check, and restore-drill evidence as JSON'
    def evidence
      if remote_command_mode?
        exec_remote(%w[kamal-backup evidence])
      else
        puts(direct_app.evidence)
      end
    end

    desc 'validate', 'Validate backup configuration without running a backup'
    def validate
      if remote_command_mode?
        validate_deploy_config
      else
        direct_app.validate
      end

      puts('ok')
    end

    desc 'init', 'Create config and print the scheduled backup accessory snippet'
    def init
      write_init_file(shared_config_path, shared_config_template)

      puts
      puts 'Add this accessory block to your Kamal deploy config:'
      puts
      puts deploy_snippet
      puts
      puts 'The accessory runs scheduled database and configured file backups with backup.schedule.'
      puts 'File backups run only for paths explicitly configured in config/kamal-backup.yml.'
      puts 'Rails local restores infer the development database and tmp state directory, but never file paths.'
      puts 'Local restore and drill also require the restic binary on your machine.'
      puts 'When production paths are configured, set their local targets in config/kamal-backup.local.yml.'
    end

    desc 'schedule', 'Run the foreground scheduler loop'
    def schedule
      if deployment_mode?
        exec_remote(%w[kamal-backup schedule])
      else
        direct_app.schedule
      end
    end

    desc 'version', 'Print the running kamal-backup version'
    def version
      if remote_command_mode?
        print_remote_version_status
      else
        puts(VERSION)
      end
    end
  end
end
