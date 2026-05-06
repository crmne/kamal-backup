require "fileutils"
require "tempfile"
require "uri"
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
          backup_to_file(source, tempfile.path)
          restic.backup_file(
            tempfile.path,
            filename: database_filename(timestamp),
            tags: backup_tags(timestamp)
          )
        end
      end

      def restore_to_current(restic, snapshot, filename)
        restic.write_dump_to_path(snapshot, filename, sqlite_source)
      end

      def restore_to_scratch(restic, snapshot, filename, target:)
        validate_scratch_restore_target(target)
        restic.write_dump_to_path(snapshot, filename, target)
      end

      def dump_command
        raise NotImplementedError, "SQLite backup uses .backup into a temporary file"
      end

      def current_target_identifier
        sqlite_source
      end

      def scratch_target_identifier(target)
        target
      end

      private
        def sqlite_source
          config.required_value("SQLITE_DATABASE_PATH")
        end

        def backup_to_file(source, target)
          run_backup(source, target)
        rescue CommandError => e
          raise unless immutable_retry_safe?(source, e)

          # Immutable mode skips WAL change detection, so only use it when no WAL sidecar exists.
          run_backup(sqlite_immutable_uri(source), target)
        end

        def run_backup(source, target)
          Command.capture(
            CommandSpec.new(argv: ["sqlite3", source, ".backup #{sqlite_literal(target)}"]),
            redactor: redactor
          )
        end

        def immutable_retry_safe?(source, error)
          readonly_database_error?(error) &&
            !File.exist?("#{source}-wal") &&
            !File.exist?("#{source}-shm")
        end

        def readonly_database_error?(error)
          error.stderr.include?("readonly database") || error.message.include?("readonly database")
        end

        def sqlite_immutable_uri(source)
          path = File.expand_path(source).split("/").map do |part|
            URI.encode_www_form_component(part).gsub("+", "%20")
          end.join("/")

          "file:#{path}?immutable=1"
        end

        def validate_scratch_restore_target(target)
          if File.expand_path(sqlite_source) == File.expand_path(target)
            raise ConfigurationError, "scratch SQLite path must differ from SQLITE_DATABASE_PATH"
          end

          super
        end

        def sqlite_literal(value)
          "'#{value.to_s.gsub("'", "''")}'"
        end
    end
  end
end
