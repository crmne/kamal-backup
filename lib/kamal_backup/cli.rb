require "fileutils"
require "json"
require "shellwords"
require "thor"
require_relative "app"
require_relative "config"
require_relative "kamal_bridge"
require_relative "redactor"
require_relative "version"

module KamalBackup
  class CLI < Thor
    module Helpers
      def command_env
        CLI.command_env || ENV
      end

      def redactor
        @redactor ||= Redactor.new(env: command_env)
      end

      def direct_app
        @direct_app ||= App.new(config: Config.new(env: command_env), redactor: redactor)
      end

      def local_app
        @local_app ||= App.new(config: local_command_config, redactor: redactor)
      end

      def local_preferences
        @local_preferences ||= Config.new(env: command_env)
      end

      def local_command_config
        @local_command_config ||= begin
          defaults = deployment_mode? ? bridge.local_restore_defaults(accessory_name: accessory_name) : {}
          Config.new(env: command_env, defaults: defaults)
        end
      end

      def bridge
        @bridge ||= KamalBridge.new(
          redactor: redactor,
          config_file: options[:config_file],
          destination: options[:destination]
        )
      end

      def deployment_mode?
        !options[:destination].to_s.strip.empty? || !options[:config_file].to_s.strip.empty?
      end

      def accessory_name
        @accessory_name ||= bridge.accessory_name(preferred: local_preferences.accessory_name)
      end

      def exec_remote(argv)
        result = bridge.execute_on_accessory(
          accessory_name: accessory_name,
          command: Shellwords.join(argv)
        )
        print(result.stdout)
        result
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

      def init_config_root
        config_file = options[:config_file] || KamalBridge::DEFAULT_CONFIG_FILE
        File.dirname(File.expand_path(config_file))
      end

      def shared_config_path
        File.join(init_config_root, "kamal-backup.yml")
      end

      def write_init_file(path, contents)
        if File.exist?(path)
          say "Exists: #{path}", :yellow
        else
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, contents)
          say "Created: #{path}", :green
        end
      end

      def shared_config_template
        <<~YAML
          # Shared defaults for kamal-backup in this app.
          # Set this when your accessory is not named "backup".
          accessory: backup
        YAML
      end

      def deploy_snippet
        <<~YAML
          accessories:
            backup:
              image: ghcr.io/crmne/kamal-backup:#{VERSION}
              host: your-server.example.com
              env:
                clear:
                  APP_NAME: your-app
                  DATABASE_ADAPTER: postgres
                  DATABASE_URL: postgres://your-app@your-db:5432/your_app_production
                  BACKUP_PATHS: /data/storage
                  RESTIC_REPOSITORY: s3:https://s3.example.com/your-app-backups
                  RESTIC_INIT_IF_MISSING: "true"
                  BACKUP_SCHEDULE_SECONDS: "86400"
                secret:
                  - PGPASSWORD
                  - RESTIC_PASSWORD
                  - AWS_ACCESS_KEY_ID
                  - AWS_SECRET_ACCESS_KEY
              volumes:
                - "your_app_storage:/data/storage:ro"
        YAML
      end
    end

    class CommandBase < Thor
      include Helpers

      class_option :yes, aliases: "-y", type: :boolean, default: false, desc: "Skip confirmation prompt"
      class_option :config_file, aliases: "-c", type: :string, desc: "Path to Kamal deploy config file"
      class_option :destination, aliases: "-d", type: :string, desc: "Kamal destination to use"
      remove_command :tree
    end

    class RestoreCLI < CommandBase
      def self.basename
        CLI.basename
      end

      desc "local [SNAPSHOT]", "Restore the backup into the local database and local files"
      def local(snapshot = "latest")
        confirm!("Restore #{snapshot} into the local database and local files? This will overwrite local data.")
        puts(JSON.pretty_generate(local_app.restore_to_local_machine(snapshot)))
      end

      desc "production [SNAPSHOT]", "Restore the backup into the production database and production files"
      def production(snapshot = "latest")
        confirm!("Restore #{snapshot} into the production database and production files? This will overwrite production data.")

        if deployment_mode?
          exec_remote(["kamal-backup", "restore", "production", snapshot, "--yes"])
        else
          puts(JSON.pretty_generate(direct_app.restore_to_production(snapshot)))
        end
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
        result = local_app.drill_on_local_machine(snapshot, check_command: options[:check])
        puts(JSON.pretty_generate(result))
        exit(1) if local_app.drill_failed?(result)
      end

      method_option :database, type: :string, desc: "Scratch database name for PostgreSQL or MySQL"
      method_option :"sqlite-path", type: :string, desc: "Scratch SQLite path for production-side drills"
      method_option :files, type: :string, default: "/restore/files", desc: "Scratch files target for the drill"
      method_option :check, type: :string, desc: "Run a verification command after the restore"
      desc "production [SNAPSHOT]", "Run a restore drill on production infrastructure using scratch targets"
      def production(snapshot = "latest")
        confirm!("Run a production-side restore drill for #{snapshot}? This will restore into scratch targets on production infrastructure.")

        if deployment_mode?
          argv = ["kamal-backup", "drill", "production", snapshot, "--files", options[:files], "--yes"]
          argv.concat(["--database", production_database_name]) if production_database_name
          argv.concat(["--sqlite-path", options[:"sqlite-path"]]) if options[:"sqlite-path"]
          argv.concat(["--check", options[:check]]) if options[:check]
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
          exit(1) if direct_app.drill_failed?(result)
        end
      end

      no_commands do
        def production_database_name
          if local_command_config.database_adapter == "sqlite"
            nil
          else
            options[:database] || prompt_required("Scratch database name")
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
          when "-d", "--destination", "-c", "--config-file"
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

    package_name "kamal-backup"
    map %w[-v --version] => :version
    class_option :config_file, aliases: "-c", type: :string, desc: "Path to Kamal deploy config file"
    class_option :destination, aliases: "-d", type: :string, desc: "Kamal destination to use"
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
      super(normalize_global_options(argv))
    rescue Error => e
      warn("kamal-backup: #{Redactor.new(env: env).redact_string(e.message)}")
      exit(1)
    rescue Interrupt
      warn("kamal-backup: interrupted")
      exit(130)
    ensure
      self.command_env = nil
    end

    include Helpers

    desc "backup", "Run one backup immediately"
    def backup
      if deployment_mode?
        exec_remote(["kamal-backup", "backup"])
      else
        direct_app.backup
      end
    end

    desc "list", "List matching restic snapshots"
    def list
      if deployment_mode?
        exec_remote(["kamal-backup", "list"])
      else
        puts(direct_app.snapshots)
      end
    end

    desc "check", "Run restic check and record the latest result"
    def check
      if deployment_mode?
        exec_remote(["kamal-backup", "check"])
      else
        puts(direct_app.check)
      end
    end

    desc "evidence", "Print redacted operational evidence as JSON"
    def evidence
      if deployment_mode?
        exec_remote(["kamal-backup", "evidence"])
      else
        puts(direct_app.evidence)
      end
    end

    desc "init", "Create kamal-backup config stubs for local restore and drill commands"
    def init
      write_init_file(shared_config_path, shared_config_template)

      puts
      puts "Add this accessory block to your Kamal deploy config:"
      puts
      puts deploy_snippet
      puts
      puts "For most Rails apps, restore local and drill local can infer the development database, storage path, and tmp state directory."
      puts "Local restore and drill also require the restic binary on your machine."
      puts "Create config/kamal-backup.local.yml only if you need to override those local defaults."
    end

    desc "schedule", "Run the foreground scheduler loop"
    def schedule
      if deployment_mode?
        exec_remote(["kamal-backup", "schedule"])
      else
        direct_app.schedule
      end
    end

    desc "version", "Print the running kamal-backup version"
    def version
      if deployment_mode?
        exec_remote(["kamal-backup", "version"])
      else
        puts(VERSION)
      end
    end

  end
end
