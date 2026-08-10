# frozen_string_literal: true

require 'uri'
require_relative 'errors'
require_relative 'config_file'
require_relative 'databases/base'
require_relative 'rails_app'

module KamalBackup
  class Config
    DEFAULT_RETENTION = {
      'RESTIC_KEEP_LAST' => '7',
      'RESTIC_KEEP_DAILY' => '7',
      'RESTIC_KEEP_WEEKLY' => '4',
      'RESTIC_KEEP_MONTHLY' => '6',
      'RESTIC_KEEP_YEARLY' => '2'
    }.freeze

    SUSPICIOUS_BACKUP_PATHS = %w[/ /var /etc /root /usr /bin /sbin /boot /dev /proc /sys /run].freeze
    SHARED_CONFIG_PATH = 'config/kamal-backup.yml'
    LOCAL_CONFIG_PATH = 'config/kamal-backup.local.yml'
    DEFAULT_CONFIG_PATHS = [SHARED_CONFIG_PATH, LOCAL_CONFIG_PATH].freeze

    class DatabaseSource
      CONNECTION_KEYS = %w[
        DATABASE_URL
        SQLITE_DATABASE_PATH
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
        MYSQL_HOST
        MYSQL_PORT
        MYSQL_USER
        MYSQL_PWD
        MYSQL_PASSWORD
        MYSQL_DATABASE
        MARIADB_HOST
        MARIADB_PORT
        MARIADB_USER
        MARIADB_PASSWORD
        MARIADB_DATABASE
      ].freeze

      attr_reader :missing_secrets, :name, :parent

      def initialize(parent:, name:, adapter:, env:, structured:, missing_secrets: [])
        @parent = parent
        @name = name.to_s
        @adapter = adapter
        @env = env.transform_keys(&:to_s)
        @structured = structured
        @missing_secrets = Array(missing_secrets)
      end

      def app_name
        parent.app_name
      end

      def database_name
        name.empty? ? 'app' : name
      end

      def database_adapter
        @adapter
      end

      def value(key)
        raw =
          if @env.key?(key)
            @env[key]
          elsif @structured && CONNECTION_KEYS.include?(key)
            nil
          else
            parent.value(key)
          end

        stripped = raw.to_s.strip
        stripped.empty? ? nil : stripped
      end

      def required_value(key)
        value(key) || raise(ConfigurationError, "#{key} is required for database #{database_name}")
      end

      def validate_database_restore_target(target)
        parent.validate_database_restore_target(target)
      end

      def validate_local_database_restore_target(target)
        parent.validate_local_database_restore_target(target)
      end
    end

    attr_reader :env

    def initialize(env: ENV, cwd: Dir.pwd, defaults: {}, config_paths: nil, load_project_defaults: true)
      raw_env = env.to_h
      base = load_project_defaults ? project_defaults(cwd: cwd) : {}
      config_data = load_config_files(raw_env, cwd: cwd, paths: config_paths)
      @database_definitions = config_data.database_definitions
      @path_definitions = config_data.path_definitions
      @restore_from_definitions = config_data.restore_from_definitions
      @env = base.merge(defaults.to_h).merge(config_data.env).merge(raw_env)
    end

    def app_name
      value('APP_NAME')
    end

    def required_app_name
      required_value('APP_NAME')
    end

    def accessory_name
      value('KAMAL_BACKUP_ACCESSORY')
    end

    def restic_repository
      value('RESTIC_REPOSITORY')
    end

    def restic_repository_file
      value('RESTIC_REPOSITORY_FILE')
    end

    def restic_password
      value('RESTIC_PASSWORD')
    end

    def restic_password_file
      value('RESTIC_PASSWORD_FILE')
    end

    def restic_password_command
      value('RESTIC_PASSWORD_COMMAND')
    end

    def restic_init_if_missing?
      truthy?('RESTIC_INIT_IF_MISSING')
    end

    def check_after_backup?
      truthy?('RESTIC_CHECK_AFTER_BACKUP')
    end

    def forget_after_backup?
      !falsey?('RESTIC_FORGET_AFTER_BACKUP')
    end

    def check_read_data_subset
      value('RESTIC_CHECK_READ_DATA_SUBSET')
    end

    def allow_in_place_file_restore?
      truthy?('KAMAL_BACKUP_ALLOW_IN_PLACE_FILE_RESTORE')
    end

    def allow_suspicious_backup_paths?
      truthy?('KAMAL_BACKUP_ALLOW_SUSPICIOUS_PATHS')
    end

    def backup_enabled?
      !falsey?('BACKUP_ENABLED')
    end

    def backup_schedule_seconds
      integer('BACKUP_SCHEDULE_SECONDS', 86_400, minimum: 1)
    end

    def backup_start_delay_seconds
      integer('BACKUP_START_DELAY_SECONDS', 0, minimum: 0)
    end

    def state_dir
      value('KAMAL_BACKUP_STATE_DIR') || '/var/lib/kamal-backup'
    end

    def last_check_path
      File.join(state_dir, 'last_check.json')
    end

    def last_backup_path
      File.join(state_dir, 'last_backup.json')
    end

    def last_restore_drill_path
      File.join(state_dir, 'last_restore_drill.json')
    end

    def backup_paths
      if path_definitions?
        @path_definitions.map(&:path)
      else
        legacy_backup_paths
      end
    end

    def backup_path_excludes(paths = backup_paths)
      paths = Array(paths).compact.map(&:to_s).reject(&:empty?)

      configured_backup_path_excludes(paths) + sqlite_backup_path_excludes(paths)
    end

    def local_restore_source_paths
      @restore_from_definitions || legacy_local_restore_source_paths || backup_paths
    end

    def local_restore_path_pairs
      source_paths = local_restore_source_paths
      target_paths = backup_paths

      unless source_paths.size == target_paths.size
        raise ConfigurationError,
              'local file paths must be explicitly configured and match the number of production restore source paths'
      end

      source_paths.zip(target_paths)
    end

    def backup_path_label(path)
      label = path.to_s.sub(%r{\A/+}, '').gsub(/[^A-Za-z0-9_.-]+/, '-')
      label.empty? ? 'root' : label
    end

    def database_adapter
      if database_definitions?
        databases.first&.database_adapter
      else
        legacy_database_adapter
      end
    end

    def databases
      @databases ||= if database_definitions?
                       @database_definitions.map do |definition|
                         DatabaseSource.new(
                           parent: self,
                           name: definition.fetch(:name),
                           adapter: definition.fetch(:adapter),
                           env: definition.fetch(:env),
                           structured: true,
                           missing_secrets: definition.fetch(:missing_secrets, [])
                         )
                       end
                     elsif legacy_database_adapter
                       [
                         DatabaseSource.new(
                           parent: self,
                           name: 'app',
                           adapter: legacy_database_adapter,
                           env: {},
                           structured: false
                         )
                       ]
                     else
                       []
                     end
    end

    def retention
      DEFAULT_RETENTION.each_with_object({}) do |(key, default), result|
        result[key] = value(key) || default
      end
    end

    def retention_args
      retention.each_with_object([]) do |(key, raw), args|
        next if raw.to_s.empty?

        number = Integer(raw)
        next if number <= 0

        flag = "--#{key.sub('RESTIC_KEEP_', 'keep-').downcase.tr('_', '-')}"
        args.concat([flag, number.to_s])
      rescue ArgumentError
        raise ConfigurationError, "#{key} must be an integer"
      end
    end

    def validate_restic(check_files: true)
      required_app_name
      validate_restic_repository(check_files: check_files)
      validate_restic_password(check_files: check_files)
    end

    def validate_backup(check_files: true)
      validate_restic(check_files: check_files)
      validate_database_backup(check_files: check_files)
      validate_backup_paths(check_files: check_files)
    end

    def validate_local_machine_restore
      validate_local_machine_environment
      validate_local_machine_paths
    end

    def validate_database_backup(check_files: true)
      raise ConfigurationError, 'databases must contain at least one database' if databases.empty?

      databases.each do |database|
        unless database.missing_secrets.empty?
          raise ConfigurationError,
                "database #{database.database_name} requires missing secret #{database.missing_secrets.join(', ')}"
        end

        case database.database_adapter
        when 'postgres'
          unless database.value('DATABASE_URL') || database.value('PGDATABASE')
            raise ConfigurationError,
                  "PostgreSQL database #{database.database_name} requires url or PGDATABASE/libpq environment"
          end
        when 'mysql'
          unless database.value('DATABASE_URL') || database.value('MYSQL_DATABASE') || database.value('MARIADB_DATABASE')
            raise ConfigurationError,
                  "MySQL database #{database.database_name} requires url or MYSQL_DATABASE/MARIADB_DATABASE"
          end
        when 'sqlite'
          path = database.required_value('SQLITE_DATABASE_PATH')
          if check_files && !File.file?(path)
            raise ConfigurationError,
                  "SQLite database #{database.database_name} does not exist: #{path}"
          end
        else
          raise ConfigurationError,
                "database #{database.database_name} adapter is required and must be postgres, mysql, or sqlite"
        end
      end
    end

    def validate_backup_paths(check_files: true)
      backup_paths.each do |path|
        expanded = File.expand_path(path)
        if SUSPICIOUS_BACKUP_PATHS.include?(expanded) && !allow_suspicious_backup_paths?
          raise ConfigurationError,
                "refusing suspicious backup path #{expanded}; set KAMAL_BACKUP_ALLOW_SUSPICIOUS_PATHS=true to override"
        end
        raise ConfigurationError, "backup path does not exist: #{path}" if check_files && !File.exist?(path)
      end
    end

    def validate_local_database_restore_target(target)
      raise ConfigurationError, 'local restore database target is required' if target.to_s.strip.empty?

      return unless production_named_target?(target)

      raise ConfigurationError,
            "refusing production-looking local restore target #{target}; use restore production for production restores"
    end

    def validate_file_restore_target(target)
      raise ConfigurationError, 'restore target cannot be empty' if target.to_s.strip.empty?

      expanded_target = File.expand_path(target)
      raise ConfigurationError, 'refusing to restore files to /' if expanded_target == '/'

      if in_place_file_restore?(expanded_target) && !allow_in_place_file_restore?
        raise ConfigurationError,
              "refusing in-place file restore to #{expanded_target}; set KAMAL_BACKUP_ALLOW_IN_PLACE_FILE_RESTORE=true to override"
      end

      expanded_target
    end

    def validate_database_restore_target(target)
      raise ConfigurationError, 'restore database target is required' if target.to_s.strip.empty?

      return unless production_like_target?(target)

      raise ConfigurationError,
            "refusing production-looking restore target #{target}; choose a scratch target that does not look like production"
    end

    def production_like_target?(target)
      target = target.to_s

      source_database_targets.include?(target) || production_named_target?(target.downcase)
    end

    def value(key)
      raw = env[key]
      return nil if raw.nil?

      stripped = raw.to_s.strip
      stripped.empty? ? nil : stripped
    end

    def required_value(key)
      value(key) || raise(ConfigurationError, "#{key} is required")
    end

    def truthy?(key)
      %w[1 true yes y on].include?(value(key).to_s.downcase)
    end

    def falsey?(key)
      %w[0 false no n off].include?(value(key).to_s.downcase)
    end

    private

    def project_defaults(cwd:)
      RailsApp.new(cwd: cwd).defaults
    end

    def load_config_files(raw_env, cwd:, paths:)
      config_paths(raw_env, cwd: cwd, paths: paths).each_with_object(ConfigData.empty) do |path, merged|
        next unless File.file?(path)

        data = ConfigFile.new(path, env: raw_env).data
        merged.env.merge!(data.env)
        merged.database_definitions = data.database_definitions if data.database_definitions
        merged.path_definitions = data.path_definitions if data.path_definitions
        merged.restore_from_definitions = data.restore_from_definitions if data.restore_from_definitions
      end
    end

    def config_paths(raw_env, cwd:, paths:)
      if paths
        Array(paths).map { |path| File.expand_path(path, cwd) }
      elsif (explicit = raw_env['KAMAL_BACKUP_CONFIG'])
        [File.expand_path(explicit, cwd)]
      else
        DEFAULT_CONFIG_PATHS.map { |relative| File.expand_path(relative, cwd) }
      end
    end

    def integer(key, default, minimum:)
      raw = value(key)
      number = raw ? Integer(raw) : default
      raise ConfigurationError, "#{key} must be >= #{minimum}" if number < minimum

      number
    rescue ArgumentError
      raise ConfigurationError, "#{key} must be an integer"
    end

    def legacy_backup_paths
      split_paths(value('BACKUP_PATHS'))
    end

    def legacy_local_restore_source_paths
      if (raw = value('LOCAL_RESTORE_SOURCE_PATHS'))
        split_paths(raw)
      end
    end

    def split_paths(raw)
      raw.to_s.split(/[\n:]+/).map(&:strip).reject(&:empty?)
    end

    def path_definitions?
      !@path_definitions.nil?
    end

    def backup_path_definitions
      if path_definitions?
        @path_definitions
      else
        legacy_backup_paths.map { |path| PathDefinition.new(path: path, exclude: []) }
      end
    end

    def configured_backup_path_excludes(paths)
      backup_path_definitions.each_with_object([]) do |definition, excludes|
        excludes.concat(definition.exclude) if paths.include?(definition.path)
      end
    end

    def sqlite_backup_path_excludes(paths)
      databases.select { |database| database.database_adapter == 'sqlite' }.flat_map do |database|
        sqlite_database_path = database.value('SQLITE_DATABASE_PATH')
        next [] if sqlite_database_path.to_s.empty?
        next [] unless paths.any? { |path| path_contains?(path, sqlite_database_path) }

        [sqlite_database_path, "#{sqlite_database_path}-wal", "#{sqlite_database_path}-shm"]
      end.uniq
    end

    def path_contains?(parent, child)
      expanded_parent = File.expand_path(parent)
      expanded_child = File.expand_path(child)
      expanded_child == expanded_parent || expanded_child.start_with?("#{expanded_parent}/")
    end

    def database_definitions?
      !@database_definitions.nil?
    end

    def legacy_database_adapter
      if (explicit = value('DATABASE_ADAPTER'))
        Databases.normalize_adapter(explicit)
      elsif (adapter = adapter_from_database_url)
        adapter
      elsif value('SQLITE_DATABASE_PATH')
        'sqlite'
      end
    end

    def adapter_from_database_url
      if (url = value('DATABASE_URL'))
        Databases.normalize_adapter(URI.parse(url).scheme)
      end
    rescue URI::InvalidURIError
      nil
    end

    def validate_restic_repository(check_files:)
      return if restic_repository

      if (path = restic_repository_file)
        raise ConfigurationError, "RESTIC_REPOSITORY_FILE does not exist: #{path}" if check_files && !File.file?(path)

        return
      end

      raise ConfigurationError, 'RESTIC_REPOSITORY or RESTIC_REPOSITORY_FILE is required'
    end

    def validate_restic_password(check_files:)
      return if restic_password || restic_password_command

      if (path = restic_password_file)
        raise ConfigurationError, "RESTIC_PASSWORD_FILE does not exist: #{path}" if check_files && !File.file?(path)

        return
      end

      raise ConfigurationError, 'RESTIC_PASSWORD, RESTIC_PASSWORD_FILE, or RESTIC_PASSWORD_COMMAND is required'
    end

    def validate_local_machine_environment
      if (environment = local_restore_environment)
        key, value = environment

        if production_environment?(value)
          raise ConfigurationError,
                "restore local refuses to run with #{key}=#{value}; unset #{key} or use restore production"
        end
      end
    end

    def local_restore_environment
      %w[RAILS_ENV RACK_ENV APP_ENV KAMAL_ENVIRONMENT].each do |key|
        return [key, value(key)] if value(key)
      end
    end

    def production_environment?(value)
      %w[production prod live].include?(value.to_s.downcase)
    end

    def validate_local_machine_paths
      path_pairs = local_restore_path_pairs

      path_pairs.each do |path_pair|
        target_path = path_pair.last
        expanded = File.expand_path(target_path)
        if SUSPICIOUS_BACKUP_PATHS.include?(expanded) && !allow_suspicious_backup_paths?
          raise ConfigurationError,
                "refusing suspicious local restore path #{expanded}; set KAMAL_BACKUP_ALLOW_SUSPICIOUS_PATHS=true to override"
        end
      end
    end

    def in_place_file_restore?(expanded_target)
      backup_paths.any? do |path|
        expanded_path = File.expand_path(path)
        expanded_target == expanded_path || expanded_path.start_with?("#{expanded_target}/") || expanded_target.start_with?("#{expanded_path}/")
      end
    end

    def source_database_targets
      databases.flat_map do |database|
        [
          database.value('DATABASE_URL'),
          database.value('SQLITE_DATABASE_PATH'),
          database.value('PGDATABASE'),
          database.value('MYSQL_DATABASE'),
          database.value('MARIADB_DATABASE')
        ]
      end.compact
    end

    def production_named_target?(target)
      target.include?('production') ||
        target.match?(%r{(^|[/_.:-])prod([/_.:-]|$)}) ||
        target.match?(%r{(^|[/_.:-])live([/_.:-]|$)})
    end
  end
end
