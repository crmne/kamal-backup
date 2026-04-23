require "uri"
require_relative "base"

module KamalBackup
  module Databases
    class Mysql < Base
      def adapter_name
        "mysql"
      end

      def dump_extension
        "sql"
      end

      def dump_command
        connection = current_connection
        argv = [
          dump_binary,
          "--single-transaction",
          "--quick",
          "--routines",
          "--triggers",
          "--events"
        ] + connection_args(connection)
        argv << connection.fetch(:database)
        CommandSpec.new(argv: argv, env: password_env(connection))
      end

      def restore_command
        connection = restore_connection
        argv = [client_binary] + connection_args(connection)
        argv << connection.fetch(:database)
        CommandSpec.new(argv: argv, env: password_env(connection))
      end

      def current_restore_command
        connection = current_connection
        argv = [client_binary] + connection_args(connection)
        argv << connection.fetch(:database)
        CommandSpec.new(argv: argv, env: password_env(connection))
      end

      def scratch_restore_command(target)
        connection = current_connection.merge(database: target)
        argv = [client_binary] + connection_args(connection)
        argv << target
        CommandSpec.new(argv: argv, env: password_env(connection))
      end

      def restore_target_identifier
        connection = restore_connection
        [connection[:host], connection[:database]].compact.join("/")
      end

      def current_target_identifier
        connection = current_connection
        [connection[:host], connection[:database]].compact.join("/")
      end

      def scratch_target_identifier(target)
        [current_connection[:host], target].compact.join("/")
      end

      private
        def validate_scratch_restore_target(target)
          if current_connection.fetch(:database) == target
            raise ConfigurationError, "scratch database must differ from the current MySQL database"
          end

          super
        end

        def dump_binary
          value("MYSQL_DUMP_BIN") || (executable_available?("mariadb-dump") ? "mariadb-dump" : "mysqldump")
        end

        def client_binary
          value("MYSQL_CLIENT_BIN") || (executable_available?("mariadb") ? "mariadb" : "mysql")
        end

        def current_connection
          if value("DATABASE_URL")
            parse_url(value("DATABASE_URL"))
          else
            connection_from_env("")
          end
        end

        def restore_connection
          if value("RESTORE_DATABASE_URL")
            parse_url(value("RESTORE_DATABASE_URL"))
          else
            connection_from_env("RESTORE_")
          end
        end

        def connection_from_env(prefix)
          database = value("#{prefix}MYSQL_DATABASE") || value("#{prefix}MARIADB_DATABASE")
          raise ConfigurationError, "#{prefix}MYSQL_DATABASE or #{prefix}MARIADB_DATABASE is required" unless database

          {
            host: value("#{prefix}MYSQL_HOST") || value("#{prefix}MARIADB_HOST"),
            port: value("#{prefix}MYSQL_PORT") || value("#{prefix}MARIADB_PORT"),
            user: value("#{prefix}MYSQL_USER") || value("#{prefix}MARIADB_USER"),
            password: value("#{prefix}MYSQL_PWD") || value("#{prefix}MYSQL_PASSWORD") || value("#{prefix}MARIADB_PASSWORD"),
            database: database
          }
        end

        def parse_url(url)
          uri = URI.parse(url)
          database = uri.path.to_s.sub(%r{\A/}, "")
          raise ConfigurationError, "database name is missing in #{uri.scheme} DATABASE_URL" if database.empty?

          {
            host: uri.host,
            port: uri.port,
            user: uri.user ? URI.decode_www_form_component(uri.user) : nil,
            password: uri.password ? URI.decode_www_form_component(uri.password) : nil,
            database: URI.decode_www_form_component(database)
          }
        rescue URI::InvalidURIError => e
          raise ConfigurationError, "invalid database URL: #{e.message}"
        end

        def connection_args(connection)
          args = []
          args.concat(["--host", connection[:host]]) if connection[:host]
          args.concat(["--port", connection[:port].to_s]) if connection[:port]
          args.concat(["--user", connection[:user]]) if connection[:user]
          args
        end

        def password_env(connection)
          connection[:password] ? { "MYSQL_PWD" => connection[:password] } : {}
        end
    end
  end
end
