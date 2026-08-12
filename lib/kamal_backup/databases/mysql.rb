# frozen_string_literal: true

require 'uri'
require_relative 'base'

module KamalBackup
  module Databases
    class Mysql < Base
      def adapter_name
        'mysql'
      end

      def dump_extension
        'sql'
      end

      def dump_command
        connection = current_connection
        argv = [
          dump_binary,
          '--single-transaction',
          '--quick',
          '--skip-comments',
          '--no-tablespaces',
          '--routines',
          '--triggers',
          '--events'
        ] + connection_args(connection)
        argv << connection.fetch(:database)
        CommandSpec.new(argv: argv, env: password_env(connection))
      end

      def restore_to_current(restic, snapshot, filename)
        reset_database(current_connection)
        super
      end

      def restore_to_scratch(restic, snapshot, filename, target:)
        validate_scratch_restore_target(target)
        reset_database(current_connection.merge(database: target))
        restic.pipe_dump_to_command(snapshot, filename, scratch_restore_command(target))
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

      def current_target_identifier
        connection = current_connection
        [connection[:host], connection[:database]].compact.join('/')
      end

      def scratch_target_identifier(target)
        [current_connection[:host], target].compact.join('/')
      end

      private

      DATABASE_OBJECTS_SQL = <<~SQL
        SELECT 'VIEW', HEX(TABLE_NAME)
          FROM information_schema.VIEWS
         WHERE TABLE_SCHEMA = DATABASE()
        UNION ALL
        SELECT CASE WHEN TABLE_TYPE = 'SEQUENCE' THEN 'SEQUENCE' ELSE 'TABLE' END, HEX(TABLE_NAME)
          FROM information_schema.TABLES
         WHERE TABLE_SCHEMA = DATABASE() AND TABLE_TYPE <> 'VIEW'
        UNION ALL
        SELECT ROUTINE_TYPE, HEX(ROUTINE_NAME)
          FROM information_schema.ROUTINES
         WHERE ROUTINE_SCHEMA = DATABASE()
        UNION ALL
        SELECT 'EVENT', HEX(EVENT_NAME)
          FROM information_schema.EVENTS
         WHERE EVENT_SCHEMA = DATABASE()
      SQL
      private_constant :DATABASE_OBJECTS_SQL

      def reset_database(connection)
        objects = database_objects(connection)
        statements = ['SET FOREIGN_KEY_CHECKS=0;']
        %w[VIEW TABLE SEQUENCE PROCEDURE FUNCTION EVENT].each do |type|
          objects.fetch(type, []).each do |name|
            statements << "DROP #{type} IF EXISTS #{quote_identifier(name)};"
          end
        end

        Command.capture(
          CommandSpec.new(argv: client_argv(connection), env: password_env(connection)),
          redactor: redactor,
          input: statements.join("\n")
        )
      rescue CommandError => e
        raise CommandError.new(
          "failed to reset the MySQL database before restoring: #{e.message}",
          command: e.command,
          stderr: e.stderr
        )
      end

      def database_objects(connection)
        command = CommandSpec.new(
          argv: client_argv(
            connection,
            options: ['--batch', '--skip-column-names', '--raw', '--execute', DATABASE_OBJECTS_SQL]
          ),
          env: password_env(connection)
        )
        output = Command.capture(command, redactor: redactor, log_output: false).stdout
        output.lines.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |line, objects|
          type, hex_name = line.chomp.split("\t", 2)
          next if type.to_s.empty? || hex_name.to_s.empty?

          objects[type] << [hex_name].pack('H*')
        end
      end

      def quote_identifier(value)
        "`#{value.to_s.gsub('`', '``')}`"
      end

      def validate_scratch_restore_target(target)
        raise ConfigurationError, 'scratch database must differ from the current MySQL database' if current_connection.fetch(:database) == target

        super
      end

      def dump_binary
        value('MYSQL_DUMP_BIN') || (executable_available?('mariadb-dump') ? 'mariadb-dump' : 'mysqldump')
      end

      def client_binary
        value('MYSQL_CLIENT_BIN') || (executable_available?('mariadb') ? 'mariadb' : 'mysql')
      end

      def current_connection
        if value('DATABASE_URL')
          parse_url(value('DATABASE_URL')).tap do |connection|
            connection[:password] ||= value('MYSQL_PWD') || value('MYSQL_PASSWORD') || value('MARIADB_PASSWORD')
          end
        else
          connection_from_env('')
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
        supported_schemes = %w[mysql mysql2 mariadb]
        raise ConfigurationError, 'DATABASE_URL must use mysql://, mysql2://, or mariadb://' unless supported_schemes.include?(uri.scheme)

        database = uri.path.to_s.sub(%r{\A/}, '')
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
        args.concat(['--host', connection[:host]]) if connection[:host]
        args.concat(['--port', connection[:port].to_s]) if connection[:port]
        args.concat(['--user', connection[:user]]) if connection[:user]
        args
      end

      def client_argv(connection, options: [])
        [client_binary] + connection_args(connection) + options + [connection.fetch(:database)]
      end

      def password_env(connection)
        connection[:password] ? { 'MYSQL_PWD' => connection[:password] } : {}
      end
    end
  end
end
