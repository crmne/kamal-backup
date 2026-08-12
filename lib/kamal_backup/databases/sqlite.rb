# frozen_string_literal: true

require 'fileutils'
require 'tempfile'
require_relative 'base'

module KamalBackup
  module Databases
    class Sqlite < Base
      def adapter_name
        'sqlite'
      end

      def dump_extension
        'sqlite3'
      end

      def backup(restic)
        source = sqlite_source
        Tempfile.create(['kamal-backup-', '.sqlite3']) do |tempfile|
          tempfile.close
          Command.capture(
            CommandSpec.new(argv: ['sqlite3', source, ".backup #{sqlite_literal(tempfile.path)}"]),
            redactor: redactor
          )
          restic.backup_file(
            tempfile.path,
            filename: database_filename,
            tags: backup_tags
          )
        end
      end

      def restore_to_current(restic, snapshot, filename)
        restore_database(restic, snapshot, filename, target: sqlite_source)
      end

      def restore_to_scratch(restic, snapshot, filename, target:)
        validate_scratch_restore_target(target)
        restore_database(restic, snapshot, filename, target: target)
      end

      def dump_command
        raise NotImplementedError, 'SQLite backup uses .backup into a temporary file'
      end

      def current_target_identifier
        sqlite_source
      end

      def scratch_target_identifier(target)
        target
      end

      private

      def sqlite_source
        config.required_value('SQLITE_DATABASE_PATH')
      end

      def validate_scratch_restore_target(target)
        raise ConfigurationError, 'scratch SQLite path must differ from SQLITE_DATABASE_PATH' if File.expand_path(sqlite_source) == File.expand_path(target)

        super
      end

      def sqlite_literal(value)
        "'#{value.to_s.gsub("'", "''")}'"
      end

      def restore_database(restic, snapshot, filename, target:)
        Tempfile.create(['kamal-backup-restore-', '.sqlite3']) do |tempfile|
          tempfile.close
          restic.write_dump_to_path(snapshot, filename, tempfile.path)
          validate_database_file(tempfile.path)
          FileUtils.mkdir_p(File.dirname(File.expand_path(target)))
          Command.capture(
            CommandSpec.new(argv: ['sqlite3', '-bail', target, ".restore #{sqlite_literal(tempfile.path)}"]),
            redactor: redactor
          )
          validate_database_file(target)
        end
      end

      def validate_database_file(path)
        result = Command.capture(
          CommandSpec.new(argv: ['sqlite3', '-bail', path, 'PRAGMA quick_check;']),
          redactor: redactor,
          log_output: false
        )
        return if result.stdout.strip == 'ok'

        raise ConfigurationError, "SQLite integrity check failed for #{path}"
      end
    end
  end
end
