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
          if deployment_mode?
            Config.new(
              env: command_env,
              defaults: production_source_defaults,
              config_paths: [Config::LOCAL_CONFIG_PATH]
            )
          else
            Config.new(env: command_env)
          end
        end
      end

      def production_source_defaults
        shared_config_source_defaults.merge(bridge.local_restore_defaults(accessory_name: accessory_name))
      end

      def shared_config_source_defaults
        config = Config.new(env: {}, config_paths: [Config::SHARED_CONFIG_PATH], load_project_defaults: false)

        {}.tap do |defaults|
          defaults["APP_NAME"] = config.app_name if config.app_name
          defaults["DATABASE_ADAPTER"] = config.database_adapter if config.database_adapter
          defaults["RESTIC_REPOSITORY"] = config.restic_repository if config.restic_repository
          defaults["LOCAL_RESTORE_SOURCE_PATHS"] = config.backup_paths.join("\n") if config.backup_paths.any?
        end
      end

      def bridge
        @bridge ||= KamalBridge.new(
          redactor: redactor,
          config_file: options[:config_file],
          destination: options[:destination],
          env: command_env
        )
      end

      def deployment_mode?
        !options[:destination].to_s.strip.empty? || !options[:config_file].to_s.strip.empty?
      end

      def default_deploy_config?
        File.file?(File.expand_path(KamalBridge::DEFAULT_CONFIG_FILE))
      end

      def remote_command_mode?
        deployment_mode? || default_deploy_config?
      end

      def accessory_name
        @accessory_name ||= bridge.accessory_name(preferred: local_preferences.accessory_name)
      end

      def remote_version
        @remote_version ||= bridge.remote_version(accessory_name: accessory_name)
      end

      def exec_remote(argv, require_version_match: true)
        ensure_remote_version_match! if require_version_match

        result = bridge.execute_on_accessory(
          accessory_name: accessory_name,
          command: Shellwords.join(argv)
        )
        print(result.stdout)
        result
      end

      def ensure_remote_version_match!
        return if remote_version == VERSION

        raise ConfigurationError, <<~MESSAGE.strip
          local gem version #{VERSION} does not match remote accessory version #{remote_version}.
          Reboot the backup accessory to pick up the latest image:
          #{accessory_reboot_command}
        MESSAGE
      end

      def accessory_reboot_command
        argv = ["bin/kamal", "accessory", "reboot", accessory_name]
        argv.concat(["-c", options[:config_file]]) if options[:config_file]
        argv.concat(["-d", options[:destination]]) if options[:destination]
        Shellwords.join(argv)
      end

      def print_remote_version_status
        status = remote_version == VERSION ? "in sync" : "out of sync"

        puts("local: #{VERSION}")
        puts("remote: #{remote_version}")
        puts("status: #{status}")
        puts("fix: #{accessory_reboot_command}") if status == "out of sync"
      end

      def validate_deploy_config
        config = Config.new(
          env: bridge.accessory_environment(accessory_name: accessory_name),
          config_paths: [Config::SHARED_CONFIG_PATH],
          load_project_defaults: false
        )
        config.validate_backup(check_files: false)
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

      def confirm_production_restore!(snapshot)
        return if options[:"confirm-production-restore"]

        if options[:yes]
          raise ConfigurationError, "--yes does not bypass restore production; use --confirm-production-restore only for deliberate automation"
        end

        unless $stdin.tty?
          raise ConfigurationError, "production restore confirmation required; rerun interactively or pass --confirm-production-restore only for deliberate automation"
        end

        app_name = production_restore_confirmation_config.required_app_name
        say "This will overwrite the production database and file paths for #{app_name} from backup #{snapshot}.", :red
        require_typed_confirmation("Type the app name to continue", app_name)
        require_typed_confirmation("Type RESTORE PRODUCTION to continue", "RESTORE PRODUCTION")
        confirm!("Restore #{snapshot} into production now? This will overwrite production data.")
      end

      def require_typed_confirmation(prompt, expected)
        answer = ask("#{prompt}:").to_s.strip
        return if answer == expected

        raise ConfigurationError, "aborted"
      end

      def production_restore_confirmation_config
        if deployment_mode?
          Config.new(
            env: bridge.accessory_environment(accessory_name: accessory_name),
            config_paths: [Config::SHARED_CONFIG_PATH],
            load_project_defaults: false
          )
        else
          direct_app.config
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
          app: your-app
          accessory: backup
          databases:
            - name: app
              adapter: postgres
              url: postgres://your-app@your-db:5432/your_app_production
              password:
                secret: DATABASE_PASSWORD
          paths:
            - /data/storage
          restic:
            repository: s3:https://s3.example.com/your-app-backups
            password:
              secret: RESTIC_PASSWORD
            init_if_missing: true
          backup:
            schedule: 1d
        YAML
      end

      def deploy_snippet
        <<~YAML
          accessories:
            backup:
              image: ghcr.io/crmne/kamal-backup:#{VERSION}
              host: your-server.example.com
              files:
                - config/kamal-backup.yml:/app/config/kamal-backup.yml:ro
              env:
                secret:
                  - DATABASE_PASSWORD
                  - RESTIC_PASSWORD
                  - AWS_ACCESS_KEY_ID
                  - AWS_SECRET_ACCESS_KEY
              volumes:
                - "your_app_storage:/data/storage:ro"
                - "your_app_backup_state:/var/lib/kamal-backup"
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

      desc "local [SNAPSHOT]", "Restore the backup into the local database and Active Storage path"
      def local(snapshot = "latest")
        confirm!("Restore #{snapshot} into the local database and Active Storage path? This will overwrite local data.")
        puts(JSON.pretty_generate(local_app.restore_to_local_machine(snapshot)))
      end

      method_option :"confirm-production-restore", type: :boolean, default: false, desc: "Confirm production restore without interactive prompts"
      desc "production [SNAPSHOT]", "Restore the backup into the production database and Active Storage path"
      def production(snapshot = "latest")
        confirm_production_restore!(snapshot)

        if deployment_mode?
          exec_remote(["kamal-backup", "restore", "production", snapshot, "--confirm-production-restore"])
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
      method_option :files, type: :string, default: "/restore/files", desc: "Scratch Active Storage target for the drill"
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
    desc "restore SUBCOMMAND ...ARGS", "Restore a database and Active Storage backup locally or into production"
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

    desc "backup", "Run one database and Active Storage backup immediately"
    def backup
      if remote_command_mode?
        exec_remote(["kamal-backup", "backup"])
      else
        direct_app.backup
      end
    end

    desc "list", "List matching restic snapshots"
    def list
      if remote_command_mode?
        exec_remote(["kamal-backup", "list"])
      else
        puts(direct_app.snapshots)
      end
    end

    desc "check", "Run restic check and record the latest result"
    def check
      if remote_command_mode?
        exec_remote(["kamal-backup", "check"])
      else
        puts(direct_app.check)
      end
    end

    desc "evidence", "Print redacted backup, check, and restore-drill evidence as JSON"
    def evidence
      if remote_command_mode?
        exec_remote(["kamal-backup", "evidence"])
      else
        puts(direct_app.evidence)
      end
    end

    desc "validate", "Validate backup configuration without running a backup"
    def validate
      if remote_command_mode?
        validate_deploy_config
      else
        direct_app.validate
      end

      puts("ok")
    end

    desc "init", "Create config and print the scheduled backup accessory snippet"
    def init
      write_init_file(shared_config_path, shared_config_template)

      puts
      puts "Add this accessory block to your Kamal deploy config:"
      puts
      puts deploy_snippet
      puts
      puts "The accessory runs scheduled database and file backups with backup.schedule."
      puts "For most Rails apps, restore local and drill local can infer the development database, Active Storage path, and tmp state directory."
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
      if remote_command_mode?
        print_remote_version_status
      else
        puts(VERSION)
      end
    end

  end
end
