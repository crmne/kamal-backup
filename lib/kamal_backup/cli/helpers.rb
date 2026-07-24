# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'shellwords'
require 'thor'
require_relative '../app'
require_relative '../command_output'
require_relative '../config'
require_relative '../kamal_bridge'
require_relative '../redactor'
require_relative '../version'

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
        @direct_app ||= App.new(
          config: Config.new(env: command_env),
          redactor: redactor
        )
      end

      def local_restore_app
        @local_restore_app ||= App.new(
          config: local_command_config,
          redactor: redactor
        )
      end

      def local_preferences
        @local_preferences ||= Config.new(env: command_env)
      end

      def local_command_config
        @local_command_config ||= if deployment_mode?
                                    Config.new(
                                      env: command_env,
                                      defaults: production_source_defaults,
                                      config_paths: [Config::LOCAL_CONFIG_PATH]
                                    )
                                  else
                                    Config.new(env: command_env)
                                  end
      end

      def production_source_defaults
        shared_config_source_defaults.merge(bridge.local_restore_defaults(accessory_name: accessory_name))
      end

      def shared_config_source_defaults
        config = Config.new(env: {}, config_paths: [Config::SHARED_CONFIG_PATH], load_project_defaults: false)

        {}.tap do |defaults|
          defaults['APP_NAME'] = config.app_name if config.app_name
          defaults['DATABASE_ADAPTER'] = config.database_adapter if config.database_adapter
          defaults['RESTIC_REPOSITORY'] = config.restic_repository if config.restic_repository
          defaults['LOCAL_RESTORE_SOURCE_PATHS'] = config.backup_paths.join("\n") if config.backup_paths.any?
        end
      end

      def bridge
        @bridge ||= KamalBridge.new(
          redactor: redactor,
          config_file: options[:config_file],
          destination: options[:destination],
          env: command_env,
          stdout: $stdout,
          stderr: $stderr
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
          command: argv,
          stream: true
        )
        print(result.stdout) unless result.streamed
        $stderr.print(result.stderr) if !result.streamed && !result.stderr.empty?
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
        argv = ['bin/kamal', 'accessory', 'reboot', accessory_name]
        argv.concat(['-c', options[:config_file]]) if options[:config_file]
        argv.concat(['-d', options[:destination]]) if options[:destination]
        Shellwords.join(argv)
      end

      def print_remote_version_status
        status = remote_version == VERSION ? 'in sync' : 'out of sync'
        status_color = status == 'in sync' ? :green : :red
        status_output = CommandOutput.new(io: $stdout, env: command_env)

        puts("local: #{VERSION}")
        puts("remote: #{remote_version}")
        puts("status: #{status_output.decorate(status, status_color, :bold)}")
        puts("fix: #{status_output.decorate(accessory_reboot_command, :yellow, :bold)}") if status == 'out of sync'
      end

      def print_backup_result(result)
        if result[:status] == 'skipped'
          puts("No backup due. Last backup finished at #{result.fetch(:last_backup_at)}.")
          puts("Next backup is due at #{result.fetch(:next_backup_at)}.")
          puts("Run `#{result.fetch(:force_command)}` to force a backup now.")
          return
        end

        puts("Backup completed at #{result.fetch(:finished_at)}")
        result.fetch(:databases).each do |database|
          puts("database #{database.fetch(:database)}: #{database.fetch(:snapshot)} at #{database.fetch(:time)}")
        end

        if (files = result[:files])
          puts("files: #{files.fetch(:snapshot)} at #{files.fetch(:time)}")
        end
      end

      def print_prune_result(results)
        output = Array(results).map(&:stdout).join

        if output.empty?
          puts('Prune completed')
        else
          print(output)
          puts unless output.end_with?("\n")
        end
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

        raise ConfigurationError, 'confirmation required; rerun with --yes' unless $stdin.tty?

        raise ConfigurationError, 'aborted' unless yes?("#{message} [y/N]")
      end

      def confirm_production_restore!(snapshot)
        return if options[:"confirm-production-restore"]

        if options[:yes]
          raise ConfigurationError,
                '--yes does not bypass restore production; use --confirm-production-restore only for deliberate automation'
        end

        unless $stdin.tty?
          raise ConfigurationError,
                'production restore confirmation required; rerun interactively or pass --confirm-production-restore only for deliberate automation'
        end

        app_name = production_restore_confirmation_config.required_app_name
        say "This will overwrite the production database and file paths for #{app_name} from backup #{snapshot}.", :red
        require_typed_confirmation('Type the app name to continue', app_name)
        require_typed_confirmation('Type RESTORE PRODUCTION to continue', 'RESTORE PRODUCTION')
        confirm!("Restore #{snapshot} into production now? This will overwrite production data.")
      end

      def require_typed_confirmation(prompt, expected)
        answer = ask("#{prompt}:").to_s.strip
        return if answer == expected

        raise ConfigurationError, 'aborted'
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
        raise ConfigurationError, "#{label.downcase} is required; pass it on the command line" unless $stdin.tty?

        value = ask("#{label}:").to_s.strip
        raise ConfigurationError, "#{label.downcase} is required" if value.empty?

        value
      end

      def init_config_root
        config_file = options[:config_file] || KamalBridge::DEFAULT_CONFIG_FILE
        File.dirname(File.expand_path(config_file))
      end

      def shared_config_path
        File.join(init_config_root, 'kamal-backup.yml')
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
                - "your_app_storage:/data/storage"
                - "your_app_backup_state:/var/lib/kamal-backup"
        YAML
      end
    end
  end
end
