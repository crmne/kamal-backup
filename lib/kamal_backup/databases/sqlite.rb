require "fileutils"
require "tempfile"
require_relative "base"

module KamalBackup
  module Databases
    class Sqlite < Base
      def adapter_name
        "sqlite"
      end

      def dump_extension
        "sqlite3"
      end

      def backup(restic, timestamp)
        source = sqlite_source
        Tempfile.create(["kamal-backup-", ".sqlite3"]) do |tempfile|
          tempfile.close
          Command.capture(
            CommandSpec.new(argv: ["sqlite3", source, ".backup #{tempfile.path}"]),
            redactor: redactor
          )
          restic.backup_file_content(
            tempfile.path,
            filename: database_filename(timestamp),
            tags: backup_tags(timestamp)
          )
        end
      end

      def restore(restic, snapshot, filename)
        validate_restore_target!
        restic.dump_file_to_path(snapshot, filename, restore_target)
      end

      def dump_command
        raise NotImplementedError, "SQLite backup uses .backup into a temporary file"
      end

      def restore_command
        raise NotImplementedError, "SQLite restore writes the database file directly"
      end

      def restore_target_identifier
        restore_target
      end

      private

      def sqlite_source
        config.required!("SQLITE_DATABASE_PATH")
      end

      def restore_target
        config.required!("RESTORE_SQLITE_DATABASE_PATH")
      end

      def validate_restore_target!
        source = File.expand_path(sqlite_source)
        target = File.expand_path(restore_target)
        if source == target && !config.allow_in_place_file_restore?
          raise ConfigurationError, "refusing in-place SQLite restore to #{target}; set KAMAL_BACKUP_ALLOW_IN_PLACE_FILE_RESTORE=true to override"
        end
        super
      end
    end
  end
end
