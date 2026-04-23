require "json"
require "thor"
require_relative "app"
require_relative "redactor"
require_relative "version"

module KamalBackup
  class CLI < Thor
    class CommandBase < Thor
      class_option :yes, aliases: "-y", type: :boolean, default: false, desc: "Skip confirmation prompt"
      remove_command :tree

      def initialize(args = [], local_options = {}, config = {})
        super
        @app = App.new(env: CLI.command_env || ENV)
      end

      no_commands do
        def app
          @app
        end

        def confirm!(message)
          return if options[:yes]

          unless $stdin.tty?
            raise ConfigurationError, "confirmation required; rerun with --yes"
          end

          unless yes?("#{message} [y/N]")
            raise ConfigurationError, "aborted"
          end
        end

        def prompt_required(label)
          unless $stdin.tty?
            raise ConfigurationError, "#{label.downcase} is required; pass it on the command line"
          end

          value = ask("#{label}:").to_s.strip
          if value.empty?
            raise ConfigurationError, "#{label.downcase} is required"
          else
            value
          end
        end
      end
    end

    class RestoreCLI < CommandBase
      def self.basename
        CLI.basename
      end

      desc "local [SNAPSHOT]", "Restore the backup into the local database and local files"
      def local(snapshot = "latest")
        confirm!("Restore #{snapshot} into the local database and local files? This will overwrite local data.")
        puts(JSON.pretty_generate(app.restore_to_local_machine(snapshot)))
      end

      desc "production [SNAPSHOT]", "Restore the backup into the production database and production files"
      def production(snapshot = "latest")
        confirm!("Restore #{snapshot} into the production database and production files? This will overwrite production data.")
        puts(JSON.pretty_generate(app.restore_to_production(snapshot)))
      end
    end

    class DrillCLI < CommandBase
      def self.basename
        CLI.basename
      end

      method_option :check, type: :string, desc: "Run a verification command after the restore"
      desc "local [SNAPSHOT]", "Run a restore drill on the local machine"
      def local(snapshot = "latest")
        confirm!("Run a local restore drill for #{snapshot}? This will overwrite local data.")
        result = app.drill_on_local_machine(snapshot, check_command: options[:check])
        puts(JSON.pretty_generate(result))
        exit(1) if app.drill_failed?(result)
      end

      method_option :database, type: :string, desc: "Scratch database name for PostgreSQL or MySQL"
      method_option :"sqlite-path", type: :string, desc: "Scratch SQLite path for production-side drills"
      method_option :files, type: :string, default: "/restore/files", desc: "Scratch files target for the drill"
      method_option :check, type: :string, desc: "Run a verification command after the restore"
      desc "production [SNAPSHOT]", "Run a restore drill on production infrastructure using scratch targets"
      def production(snapshot = "latest")
        confirm!("Run a production-side restore drill for #{snapshot}? This will restore into scratch targets on production infrastructure.")

        result = app.drill_on_production(
          snapshot,
          database_name: production_database_name,
          sqlite_path: options[:"sqlite-path"],
          file_target: options[:files],
          check_command: options[:check]
        )
        puts(JSON.pretty_generate(result))
        exit(1) if app.drill_failed?(result)
      end

      no_commands do
        def production_database_name
          if app.config.database_adapter == "sqlite"
            nil
          else
            options[:database] || prompt_required("Scratch database name")
          end
        end
      end
    end

    class << self
      attr_accessor :command_env
    end

    package_name "kamal-backup"
    map %w[-v --version] => :version
    remove_command :tree
    desc "restore SUBCOMMAND ...ARGS", "Restore a backup onto the local machine or into production"
    subcommand "restore", RestoreCLI
    desc "drill SUBCOMMAND ...ARGS", "Run a restore drill on the local machine or on production infrastructure"
    subcommand "drill", DrillCLI

    def self.basename
      "kamal-backup"
    end

    def self.start(argv = ARGV, env: ENV)
      self.command_env = env
      super(argv)
    rescue Error => e
      warn("kamal-backup: #{Redactor.new(env: env).redact_string(e.message)}")
      exit(1)
    rescue Interrupt
      warn("kamal-backup: interrupted")
      exit(130)
    ensure
      self.command_env = nil
    end

    def initialize(args = [], local_options = {}, config = {})
      super
      @app = App.new(env: self.class.command_env || ENV)
    end

    desc "backup", "Run one backup immediately"
    def backup
      app.backup
    end

    desc "list", "List matching restic snapshots"
    def list
      puts(app.snapshots)
    end

    desc "check", "Run restic check and record the latest result"
    def check
      puts(app.check)
    end

    desc "evidence", "Print redacted operational evidence as JSON"
    def evidence
      puts(app.evidence)
    end

    desc "schedule", "Run the foreground scheduler loop"
    def schedule
      app.schedule
    end

    desc "version", "Print the running kamal-backup version"
    def version
      puts(VERSION)
    end

    private
      attr_reader :app
  end
end
