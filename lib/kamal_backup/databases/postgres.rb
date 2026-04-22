require_relative "base"

module KamalBackup
  module Databases
    class Postgres < Base
      RESTORE_ENV_MAP = {
        "RESTORE_PGHOST" => "PGHOST",
        "RESTORE_PGPORT" => "PGPORT",
        "RESTORE_PGUSER" => "PGUSER",
        "RESTORE_PGPASSWORD" => "PGPASSWORD",
        "RESTORE_PGDATABASE" => "PGDATABASE",
        "RESTORE_PGSSLMODE" => "PGSSLMODE"
      }.freeze

      def adapter_name
        "postgres"
      end

      def dump_extension
        "pgdump"
      end

      def dump_command
        argv = %w[pg_dump --format=custom --no-owner --no-privileges]
        argv << value("DATABASE_URL") if value("DATABASE_URL")
        CommandSpec.new(argv: argv)
      end

      def restore_command
        target = value("RESTORE_DATABASE_URL") || value("RESTORE_PGDATABASE")
        raise ConfigurationError, "RESTORE_DATABASE_URL or RESTORE_PGDATABASE is required for PostgreSQL restore" unless target

        argv = %w[pg_restore --clean --if-exists --no-owner --no-privileges --dbname]
        argv << target
        CommandSpec.new(argv: argv, env: restore_env)
      end

      def restore_target_identifier
        value("RESTORE_DATABASE_URL") || value("RESTORE_PGDATABASE")
      end

      private

      def restore_env
        RESTORE_ENV_MAP.each_with_object({}) do |(source, target), env|
          env[target] = value(source) if value(source)
        end
      end
    end
  end
end
