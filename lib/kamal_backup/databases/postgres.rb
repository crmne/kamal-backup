# frozen_string_literal: true

require 'uri'
require_relative 'base'

module KamalBackup
  module Databases
    class Postgres < Base
      SOURCE_ENV_KEYS = %w[
        PGHOST
        PGPORT
        PGUSER
        PGPASSWORD
        PGDATABASE
        PGSSLMODE
        PGSSLROOTCERT
        PGSSLCERT
        PGSSLKEY
        PGCONNECT_TIMEOUT
        PGSERVICE
        PGPASSFILE
      ].freeze

      def adapter_name
        'postgres'
      end

      def dump_extension
        'pgdump'
      end

      def dump_command
        connection = current_connection
        argv = [postgres_binary('pg_dump', connection)] + %w[--format=custom --no-owner --no-privileges]
        CommandSpec.new(argv: argv, env: connection)
      end

      # Replace the target's user schemas before restoring.
      #
      # pg_restore --clean emits DROP TABLE for each object in the dump, but
      # PostgreSQL refuses to drop a table another table still references, and
      # the dump's ordering cannot account for constraints that only exist in
      # the target. Restoring over a schema Rails already created — which is
      # every restore onto a freshly deployed host, since Kamal runs db:prepare
      # on boot — leaves the drops failing, the CREATEs failing as "already
      # exists", the COPYs never running, and the foreign keys rejected because
      # the tables they point at are still empty.
      #
      # Dropping every non-system schema first sidesteps the ordering problem
      # entirely and removes target-only custom schemas as well as public.
      # Current and scratch restores both promise that the target represents
      # the selected snapshot, so both paths reset their target schema.
      def restore_to_current(restic, snapshot, filename)
        reset_schema(current_connection)
        result = super
        ensure_restore_reported_no_errors(result)
        result
      end

      def restore_to_scratch(restic, snapshot, filename, target:)
        validate_scratch_restore_target(target)
        reset_schema(current_connection.merge('PGDATABASE' => target))
        result = restic.pipe_dump_to_command(snapshot, filename, scratch_restore_command(target))
        ensure_restore_reported_no_errors(result)
        result
      end

      def current_restore_command
        connection = current_connection
        database = connection.fetch('PGDATABASE')

        argv = [postgres_binary('pg_restore', connection)] +
               %w[--clean --if-exists --no-owner --no-privileges --exit-on-error --dbname]
        argv << database
        CommandSpec.new(argv: argv, env: connection)
      end

      def scratch_restore_command(target)
        connection = current_connection.merge('PGDATABASE' => target)

        argv = [postgres_binary('pg_restore', connection)] +
               %w[--clean --if-exists --no-owner --no-privileges --exit-on-error --dbname]
        argv << target
        CommandSpec.new(argv: argv, env: connection)
      end

      def current_target_identifier
        value('DATABASE_URL') || value('PGDATABASE')
      end

      def scratch_target_identifier(target)
        [current_connection['PGHOST'], target].compact.join('/')
      end

      private

      # pg_restore exits 0 even when individual objects fail, reporting only
      # "errors ignored on restore: N" on stderr. A restore that half-applied
      # and claimed success is worse than one that failed, because the damage
      # is only discovered later, from the data.
      def ensure_restore_reported_no_errors(result)
        stderr = result.respond_to?(:stderr) ? result.stderr.to_s : ''
        match = stderr.match(/errors ignored on restore:\s*(\d+)/i)
        return if match.nil? || match[1].to_i.zero?

        raise CommandError.new(
          "pg_restore reported #{match[1]} ignored error(s); the database is only partially restored. " \
          'Inspect the output above, resolve the cause, and restore again.',
          command: current_restore_command,
          stderr: stderr
        )
      end

      def reset_schema(connection)
        argv = [postgres_binary('psql', connection), '--quiet', '--no-psqlrc', '--set', 'ON_ERROR_STOP=1',
                '--command', RESET_SCHEMAS_SQL]
        Command.capture(CommandSpec.new(argv: argv, env: connection), redactor: redactor)
      rescue CommandError => e
        raise CommandError.new(
          "failed to reset PostgreSQL schemas before restoring: #{e.message}",
          command: e.command,
          stderr: e.stderr
        )
      end

      RESET_SCHEMAS_SQL = <<~SQL
        DO $$
        DECLARE
          schema_name text;
        BEGIN
          FOR schema_name IN
            SELECT nspname
              FROM pg_namespace
             WHERE nspname !~ '^pg_'
               AND nspname <> 'information_schema'
          LOOP
            EXECUTE format('DROP SCHEMA %I CASCADE', schema_name);
          END LOOP;
        END
        $$;
        CREATE SCHEMA public;
      SQL
      private_constant :RESET_SCHEMAS_SQL

      def postgres_binary(name, connection)
        root = value('KAMAL_BACKUP_POSTGRES_CLIENT_ROOT')
        return name if root.to_s.empty?

        major = postgres_server_major(connection)
        binary = File.join(root, major.to_s, 'bin', name)
        return binary if File.executable?(binary)

        supported = Dir[File.join(root, '*', 'bin', name)].filter_map do |path|
          path.split(File::SEPARATOR)[-3] if File.executable?(path)
        end.sort
        raise ConfigurationError,
              "PostgreSQL #{major} is not supported by this accessory image; available client versions: #{supported.join(', ')}"
      end

      def postgres_server_major(connection)
        @postgres_server_majors ||= {}
        key = connection.values_at('PGHOST', 'PGPORT', 'PGUSER', 'PGDATABASE', 'PGSERVICE')
        @postgres_server_majors[key] ||= begin
          probe = value('KAMAL_BACKUP_POSTGRES_PROBE_BIN') || 'psql'
          result = Command.capture(
            CommandSpec.new(
              argv: [probe, '--no-psqlrc', '--tuples-only', '--no-align', '--command', 'SHOW server_version_num'],
              env: connection
            ),
            redactor: redactor,
            log: false
          )
          version_number = Integer(result.stdout.strip, 10)
          version_number / 10_000
        rescue ArgumentError
          raise ConfigurationError, 'could not determine the PostgreSQL server version'
        end
      end

      def validate_scratch_restore_target(target)
        raise ConfigurationError, 'scratch database must differ from the current PostgreSQL database' if current_connection.fetch('PGDATABASE') == target

        super
      end

      def current_connection
        if value('DATABASE_URL')
          connection = connection_from_url(value('DATABASE_URL'), 'DATABASE_URL')
          connection['PGPASSWORD'] ||= value('PGPASSWORD')
          connection.compact
        else
          connection = prefixed_env('', SOURCE_ENV_KEYS)
          unless connection['PGDATABASE']
            raise ConfigurationError,
                  'DATABASE_URL or PGDATABASE is required for PostgreSQL restore'
          end

          connection
        end
      end

      def prefixed_env(prefix, keys)
        keys.each_with_object({}) do |key, env|
          env[key] = value("#{prefix}#{key}") if value("#{prefix}#{key}")
        end
      end

      def connection_from_url(url, name)
        uri = URI.parse(url)
        raise ConfigurationError, "#{name} must use postgres:// or postgresql://" unless %w[postgres postgresql].include?(uri.scheme)

        database = URI.decode_www_form_component(uri.path.to_s.sub(%r{\A/}, ''))
        raise ConfigurationError, "database name is missing in #{name}" if database.empty?

        env = {
          'PGHOST' => uri.host,
          'PGPORT' => uri.port&.to_s,
          'PGUSER' => uri.user ? URI.decode_www_form_component(uri.user) : nil,
          'PGPASSWORD' => uri.password ? URI.decode_www_form_component(uri.password) : nil,
          'PGDATABASE' => database
        }.compact

        query = URI.decode_www_form(uri.query.to_s).to_h
        {
          'sslmode' => 'PGSSLMODE',
          'sslrootcert' => 'PGSSLROOTCERT',
          'sslcert' => 'PGSSLCERT',
          'sslkey' => 'PGSSLKEY',
          'connect_timeout' => 'PGCONNECT_TIMEOUT'
        }.each do |source, target|
          env[target] = query[source] if query[source]
        end

        env
      rescue URI::InvalidURIError => e
        raise ConfigurationError, "invalid #{name}: #{e.message}"
      end
    end
  end
end
