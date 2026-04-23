require "uri"
require_relative "base"

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
        "postgres"
      end

      def dump_extension
        "pgdump"
      end

      def dump_command
        argv = %w[pg_dump --format=custom --no-owner --no-privileges]
        CommandSpec.new(argv: argv, env: current_connection)
      end

      def current_restore_command
        connection = current_connection
        database = connection.fetch("PGDATABASE")

        argv = %w[pg_restore --clean --if-exists --no-owner --no-privileges --dbname]
        argv << database
        CommandSpec.new(argv: argv, env: connection)
      end

      def scratch_restore_command(target)
        connection = current_connection.merge("PGDATABASE" => target)

        argv = %w[pg_restore --clean --if-exists --no-owner --no-privileges --dbname]
        argv << target
        CommandSpec.new(argv: argv, env: connection)
      end

      def current_target_identifier
        value("DATABASE_URL") || value("PGDATABASE")
      end

      def scratch_target_identifier(target)
        [current_connection["PGHOST"], target].compact.join("/")
      end

      private
        def validate_scratch_restore_target(target)
          if current_connection.fetch("PGDATABASE") == target
            raise ConfigurationError, "scratch database must differ from the current PostgreSQL database"
          end

          super
        end

        def current_connection
          if value("DATABASE_URL")
            connection_from_url(value("DATABASE_URL"), "DATABASE_URL")
          else
            connection = prefixed_env("", SOURCE_ENV_KEYS)
            raise ConfigurationError, "DATABASE_URL or PGDATABASE is required for PostgreSQL restore" unless connection["PGDATABASE"]

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
          unless %w[postgres postgresql].include?(uri.scheme)
            raise ConfigurationError, "#{name} must use postgres:// or postgresql://"
          end

          database = URI.decode_www_form_component(uri.path.to_s.sub(%r{\A/}, ""))
          raise ConfigurationError, "database name is missing in #{name}" if database.empty?

          env = {
            "PGHOST" => uri.host,
            "PGPORT" => uri.port&.to_s,
            "PGUSER" => uri.user ? URI.decode_www_form_component(uri.user) : nil,
            "PGPASSWORD" => uri.password ? URI.decode_www_form_component(uri.password) : nil,
            "PGDATABASE" => database
          }.compact

          query = URI.decode_www_form(uri.query.to_s).to_h
          {
            "sslmode" => "PGSSLMODE",
            "sslrootcert" => "PGSSLROOTCERT",
            "sslcert" => "PGSSLCERT",
            "sslkey" => "PGSSLKEY",
            "connect_timeout" => "PGCONNECT_TIMEOUT"
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
