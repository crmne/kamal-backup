require_relative "../command"
require_relative "../errors"

module KamalBackup
  module Databases
    class Base
      attr_reader :config, :redactor

      def initialize(config, redactor:)
        @config = config
        @redactor = redactor
      end

      def backup(restic, timestamp)
        restic.backup_command_output(
          dump_command,
          filename: database_filename(timestamp),
          tags: backup_tags(timestamp)
        )
      end

      def restore(restic, snapshot, filename)
        validate_restore_target!
        restic.dump_file_to_command(snapshot, filename, restore_command)
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

      def restore_command
        raise NotImplementedError
      end

      def validate_restore_target!
        config.validate_database_restore_target!(restore_target_identifier)
      end

      def restore_target_identifier
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
