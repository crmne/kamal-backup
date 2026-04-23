require_relative "../command"
require_relative "../errors"

module KamalBackup
  module Databases
    class Base
      def self.build(config, redactor:)
        case config.database_adapter
        when "postgres"
          Postgres.new(config, redactor: redactor)
        when "mysql"
          Mysql.new(config, redactor: redactor)
        when "sqlite"
          Sqlite.new(config, redactor: redactor)
        else
          raise ConfigurationError, "unsupported DATABASE_ADAPTER: #{config.database_adapter.inspect}"
        end
      end

      attr_reader :config, :redactor

      def initialize(config, redactor:)
        @config = config
        @redactor = redactor
      end

      def backup(restic, timestamp)
        restic.backup_stream(
          dump_command,
          filename: database_filename(timestamp),
          tags: backup_tags(timestamp)
        )
      end

      def restore_to_current(restic, snapshot, filename)
        restic.pipe_dump_to_command(snapshot, filename, current_restore_command)
      end

      def restore_to_scratch(restic, snapshot, filename, target:)
        validate_scratch_restore_target(target)
        restic.pipe_dump_to_command(snapshot, filename, scratch_restore_command(target))
      end

      def database_filename(timestamp)
        app = config.app_name.gsub(/[^A-Za-z0-9_.-]+/, "-")
        "databases-#{app}-#{adapter_name}-#{timestamp}.#{dump_extension}"
      end

      def backup_tags(timestamp)
        ["type:database", "adapter:#{adapter_name}", "run:#{timestamp}"]
      end

      def adapter_name
        raise NotImplementedError
      end

      def dump_extension
        raise NotImplementedError
      end

      def dump_command
        raise NotImplementedError
      end

      def current_restore_command
        raise NotImplementedError
      end

      def scratch_restore_command(target)
        raise NotImplementedError
      end

      def validate_scratch_restore_target(target)
        config.validate_database_restore_target(scratch_target_identifier(target))
      end

      def current_target_identifier
        raise NotImplementedError
      end

      def scratch_target_identifier(target)
        raise NotImplementedError
      end

      private
        def value(key)
          config.value(key)
        end

        def executable_available?(name)
          ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
            path = File.join(dir, name)
            File.executable?(path) && !File.directory?(path)
          end
        end
    end
  end
end
