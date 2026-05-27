require "uri"
require "yaml"
require_relative "errors"
require_relative "rails_app"

module KamalBackup
  class Config
    DEFAULT_RETENTION = {
      "RESTIC_KEEP_LAST" => "7",
      "RESTIC_KEEP_DAILY" => "7",
      "RESTIC_KEEP_WEEKLY" => "4",
      "RESTIC_KEEP_MONTHLY" => "6",
      "RESTIC_KEEP_YEARLY" => "2"
    }.freeze

    SUSPICIOUS_BACKUP_PATHS = %w[/ /var /etc /root /usr /bin /sbin /boot /dev /proc /sys /run].freeze
    SHARED_CONFIG_PATH = "config/kamal-backup.yml"
    LOCAL_CONFIG_PATH = "config/kamal-backup.local.yml"
    DEFAULT_CONFIG_PATHS = [SHARED_CONFIG_PATH, LOCAL_CONFIG_PATH].freeze
    TOP_LEVEL_YAML_KEYS = %w[app accessory databases paths restore_from restic backup state].freeze
    LEGACY_YAML_KEYS = %w[
      app_name
      database_adapter
      database_url
      sqlite_database_path
      backup_paths
      local_restore_source_paths
      restic_repository
      restic_repository_file
      restic_password
      restic_password_file
      restic_password_command
      restic_init_if_missing
      restic_check_after_backup
      restic_check_read_data_subset
      restic_forget_after_backup
      restic_keep_last
      restic_keep_daily
      restic_keep_weekly
      restic_keep_monthly
      restic_keep_yearly
      backup_schedule_seconds
      backup_start_delay_seconds
      state_dir
      allow_suspicious_paths
      pgpassword
      mysql_pwd
    ].freeze
    ConfigData = Struct.new(:env, :database_definitions, :path_definitions, :restore_from_definitions, keyword_init: true) do
      def self.empty
        new(env: {}, database_definitions: nil, path_definitions: nil, restore_from_definitions: nil)
      end
    end

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
        name.empty? ? "app" : name
      end

      def database_adapter
        @adapter || parent.send(:legacy_database_adapter)
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
      value("APP_NAME")
    end

    def required_app_name
      required_value("APP_NAME")
    end

    def accessory_name
      value("KAMAL_BACKUP_ACCESSORY")
    end

    def restic_repository
      value("RESTIC_REPOSITORY")
    end

    def restic_repository_file
      value("RESTIC_REPOSITORY_FILE")
    end

    def restic_password
      value("RESTIC_PASSWORD")
    end

    def restic_password_file
      value("RESTIC_PASSWORD_FILE")
    end

    def restic_password_command
      value("RESTIC_PASSWORD_COMMAND")
    end

    def restic_init_if_missing?
      truthy?("RESTIC_INIT_IF_MISSING")
    end

    def check_after_backup?
      truthy?("RESTIC_CHECK_AFTER_BACKUP")
    end

    def forget_after_backup?
      !falsey?("RESTIC_FORGET_AFTER_BACKUP")
    end

    def check_read_data_subset
      value("RESTIC_CHECK_READ_DATA_SUBSET")
    end

    def allow_in_place_file_restore?
      truthy?("KAMAL_BACKUP_ALLOW_IN_PLACE_FILE_RESTORE")
    end

    def allow_suspicious_backup_paths?
      truthy?("KAMAL_BACKUP_ALLOW_SUSPICIOUS_PATHS")
    end

    def backup_schedule_seconds
      integer("BACKUP_SCHEDULE_SECONDS", 86_400, minimum: 1)
    end

    def backup_start_delay_seconds
      integer("BACKUP_START_DELAY_SECONDS", 0, minimum: 0)
    end

    def state_dir
      value("KAMAL_BACKUP_STATE_DIR") || "/var/lib/kamal-backup"
    end

    def last_check_path
      File.join(state_dir, "last_check.json")
    end

    def last_restore_drill_path
      File.join(state_dir, "last_restore_drill.json")
    end

    def backup_paths
      if path_definitions?
        @path_definitions
      else
        legacy_backup_paths
      end
    end

    def local_restore_source_paths
      if path_definitions?
        @restore_from_definitions || legacy_local_restore_source_paths || backup_paths
      else
        legacy_local_restore_source_paths || backup_paths
      end
    end

    def local_restore_path_pairs
      source_paths = local_restore_source_paths
      target_paths = backup_paths

      if source_paths.size == target_paths.size
        source_paths.zip(target_paths)
      else
        raise ConfigurationError, "local restore source paths must contain the same number of paths as file paths"
      end
    end

    def backup_path_label(path)
      label = path.to_s.sub(%r{\A/+}, "").gsub(%r{[^A-Za-z0-9_.-]+}, "-")
      label.empty? ? "root" : label
    end

    def database_adapter
      if database_definitions?
        databases.first&.database_adapter
      else
        legacy_database_adapter
      end
    end

    def database_name
      "app"
    end

    def databases
      @databases ||= begin
        if database_definitions?
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
              name: database_name,
              adapter: legacy_database_adapter,
              env: {},
              structured: false
            )
          ]
        else
          []
        end
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

        flag = "--#{key.sub("RESTIC_KEEP_", "keep-").downcase.tr("_", "-")}"
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
      raise ConfigurationError, "databases must contain at least one database" if databases.empty?

      databases.each do |database|
        unless database.missing_secrets.empty?
          raise ConfigurationError, "database #{database.database_name} requires missing secret #{database.missing_secrets.join(", ")}"
        end

        case database.database_adapter
        when "postgres"
          unless database.value("DATABASE_URL") || database.value("PGDATABASE")
            raise ConfigurationError, "PostgreSQL database #{database.database_name} requires url or PGDATABASE/libpq environment"
          end
        when "mysql"
          unless database.value("DATABASE_URL") || database.value("MYSQL_DATABASE") || database.value("MARIADB_DATABASE")
            raise ConfigurationError, "MySQL database #{database.database_name} requires url or MYSQL_DATABASE/MARIADB_DATABASE"
          end
        when "sqlite"
          path = database.required_value("SQLITE_DATABASE_PATH")
          raise ConfigurationError, "SQLite database #{database.database_name} does not exist: #{path}" if check_files && !File.file?(path)
        else
          raise ConfigurationError, "database #{database.database_name} adapter is required and must be postgres, mysql, or sqlite"
        end
      end
    end

    def validate_backup_paths(check_files: true)
      backup_paths.each do |path|
        expanded = File.expand_path(path)
        if SUSPICIOUS_BACKUP_PATHS.include?(expanded) && !allow_suspicious_backup_paths?
          raise ConfigurationError, "refusing suspicious backup path #{expanded}; set KAMAL_BACKUP_ALLOW_SUSPICIOUS_PATHS=true to override"
        end
        raise ConfigurationError, "backup path does not exist: #{path}" if check_files && !File.exist?(path)
      end
    end

    def validate_local_database_restore_target(target)
      raise ConfigurationError, "local restore database target is required" if target.to_s.strip.empty?

      if production_named_target?(target)
        raise ConfigurationError, "refusing production-looking local restore target #{target}; use restore production for production restores"
      end
    end

    def validate_file_restore_target(target)
      raise ConfigurationError, "restore target cannot be empty" if target.to_s.strip.empty?

      expanded_target = File.expand_path(target)
      raise ConfigurationError, "refusing to restore files to /" if expanded_target == "/"

      if in_place_file_restore?(expanded_target) && !allow_in_place_file_restore?
        raise ConfigurationError, "refusing in-place file restore to #{expanded_target}; set KAMAL_BACKUP_ALLOW_IN_PLACE_FILE_RESTORE=true to override"
      end

      expanded_target
    end

    def validate_database_restore_target(target)
      raise ConfigurationError, "restore database target is required" if target.to_s.strip.empty?

      if production_like_target?(target)
        raise ConfigurationError, "refusing production-looking restore target #{target}; choose a scratch target that does not look like production"
      end
    end

    def production_like_target?(target)
      target = target.to_s

      if source_database_targets.include?(target)
        true
      else
        production_named_target?(target.downcase)
      end
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

          data = normalize_config_file(path, raw_env: raw_env)
          merged.env.merge!(data.env)
          merged.database_definitions = data.database_definitions if data.database_definitions
          merged.path_definitions = data.path_definitions if data.path_definitions
          merged.restore_from_definitions = data.restore_from_definitions if data.restore_from_definitions
        end
      end

      def config_paths(raw_env, cwd:, paths:)
        if paths
          Array(paths).map { |path| File.expand_path(path, cwd) }
        elsif explicit = raw_env["KAMAL_BACKUP_CONFIG"]
          [File.expand_path(explicit, cwd)]
        else
          DEFAULT_CONFIG_PATHS.map { |relative| File.expand_path(relative, cwd) }
        end
      end

      def validate_restic_repository(check_files:)
        return if restic_repository

        if path = restic_repository_file
          raise ConfigurationError, "RESTIC_REPOSITORY_FILE does not exist: #{path}" if check_files && !File.file?(path)

          return
        end

        raise ConfigurationError, "RESTIC_REPOSITORY or RESTIC_REPOSITORY_FILE is required"
      end

      def validate_restic_password(check_files:)
        return if restic_password || restic_password_command

        if path = restic_password_file
          raise ConfigurationError, "RESTIC_PASSWORD_FILE does not exist: #{path}" if check_files && !File.file?(path)

          return
        end

        raise ConfigurationError, "RESTIC_PASSWORD, RESTIC_PASSWORD_FILE, or RESTIC_PASSWORD_COMMAND is required"
      end

      def normalize_config_file(path, raw_env:)
        data = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
        return ConfigData.empty if data.nil?

        unless data.is_a?(Hash)
          raise ConfigurationError, "#{path} must contain a YAML mapping"
        end

        result = ConfigData.empty
        data.each do |raw_key, raw_value|
          key = raw_key.to_s
          validate_top_level_yaml_key!(path, key)

          case key
          when "app"
            result.env["APP_NAME"] = normalize_yaml_value(raw_value)
          when "accessory"
            result.env["KAMAL_BACKUP_ACCESSORY"] = normalize_yaml_value(raw_value)
          when "databases"
            result.database_definitions = normalize_yaml_databases(raw_value, raw_env: raw_env, path: path)
          when "paths"
            result.path_definitions = normalize_yaml_paths(raw_value, "#{path} paths")
          when "restore_from"
            result.restore_from_definitions = normalize_yaml_paths(raw_value, "#{path} restore_from")
          when "restic"
            result.env.merge!(normalize_yaml_restic(raw_value, raw_env: raw_env, path: path))
          when "backup"
            result.env.merge!(normalize_yaml_backup(raw_value, path: path))
          when "state"
            result.env.merge!(normalize_yaml_state(raw_value, path: path))
          end
        end
        result
      rescue Psych::SyntaxError => e
        raise ConfigurationError, "invalid YAML in #{path}: #{e.message}"
      end

      def validate_top_level_yaml_key!(path, key)
        if LEGACY_YAML_KEYS.include?(key)
          raise ConfigurationError, "#{path} uses legacy key #{key}; use databases, paths, restic, and backup instead. See the upgrading guide for the 0.3 config migration."
        end

        return if TOP_LEVEL_YAML_KEYS.include?(key)

        raise ConfigurationError, "#{path} contains unknown key #{key.inspect}; expected #{TOP_LEVEL_YAML_KEYS.join(", ")}"
      end

      def normalize_yaml_value(raw_value)
        case raw_value
        when Array
          raw_value.map(&:to_s).join("\n")
        when NilClass
          nil
        else
          raw_value.to_s
        end
      end

      def normalize_yaml_databases(raw_value, raw_env:, path:)
        entries = require_array(raw_value, "#{path} databases")
        entries.map.with_index(1) do |entry, index|
          hash = require_mapping(entry, "#{path} databases[#{index}]")
          name = required_yaml_scalar(hash, "name", "#{path} databases[#{index}]")
          adapter = normalize_adapter(required_yaml_scalar(hash, "adapter", "#{path} databases[#{index}]"))
          raise ConfigurationError, "#{path} databases[#{index}] adapter must be postgres, mysql, or sqlite" unless adapter

          env = {}
          missing_secrets = []
          case adapter
          when "postgres"
            if hash.key?("url")
              env["DATABASE_URL"] = resolve_yaml_value(hash["url"], raw_env: raw_env, context: "#{path} databases[#{index}].url")
              missing_secrets.concat(missing_yaml_secrets(hash["url"], raw_env: raw_env))
            end
            if hash.key?("password")
              env["PGPASSWORD"] = resolve_yaml_value(hash["password"], raw_env: raw_env, context: "#{path} databases[#{index}].password")
              missing_secrets.concat(missing_yaml_secrets(hash["password"], raw_env: raw_env))
            end
          when "mysql"
            if hash.key?("url")
              env["DATABASE_URL"] = resolve_yaml_value(hash["url"], raw_env: raw_env, context: "#{path} databases[#{index}].url")
              missing_secrets.concat(missing_yaml_secrets(hash["url"], raw_env: raw_env))
            end
            if hash.key?("password")
              env["MYSQL_PWD"] = resolve_yaml_value(hash["password"], raw_env: raw_env, context: "#{path} databases[#{index}].password")
              missing_secrets.concat(missing_yaml_secrets(hash["password"], raw_env: raw_env))
            end
          when "sqlite"
            sqlite_path = hash.key?("path") ? hash["path"] : hash["database"]
            if sqlite_path
              env["SQLITE_DATABASE_PATH"] = resolve_yaml_value(sqlite_path, raw_env: raw_env, context: "#{path} databases[#{index}].path")
              missing_secrets.concat(missing_yaml_secrets(sqlite_path, raw_env: raw_env))
            end
          end

          {
            name: name,
            adapter: adapter,
            env: env.compact,
            missing_secrets: missing_secrets
          }
        end
      end

      def normalize_yaml_restic(raw_value, raw_env:, path:)
        hash = require_mapping(raw_value, "#{path} restic")
        env = {}

        env["RESTIC_REPOSITORY"] = resolve_yaml_value(hash["repository"], raw_env: raw_env, context: "#{path} restic.repository") if hash.key?("repository")
        env["RESTIC_REPOSITORY_FILE"] = normalize_yaml_value(hash["repository_file"]) if hash.key?("repository_file")

        if hash.key?("password")
          normalize_yaml_restic_password(hash["password"], raw_env: raw_env, path: path).each do |key, value|
            env[key] = value
          end
        end

        env.merge!(normalize_yaml_restic_rest(hash["rest"], raw_env: raw_env, path: path)) if hash.key?("rest")

        {
          "init_if_missing" => "RESTIC_INIT_IF_MISSING",
          "check_after_backup" => "RESTIC_CHECK_AFTER_BACKUP",
          "check_read_data_subset" => "RESTIC_CHECK_READ_DATA_SUBSET",
          "forget_after_backup" => "RESTIC_FORGET_AFTER_BACKUP"
        }.each do |source, target|
          env[target] = normalize_yaml_value(hash[source]) if hash.key?(source)
        end

        if hash.key?("retention")
          retention = require_mapping(hash["retention"], "#{path} restic.retention")
          {
            "keep_last" => "RESTIC_KEEP_LAST",
            "keep_daily" => "RESTIC_KEEP_DAILY",
            "keep_weekly" => "RESTIC_KEEP_WEEKLY",
            "keep_monthly" => "RESTIC_KEEP_MONTHLY",
            "keep_yearly" => "RESTIC_KEEP_YEARLY"
          }.each do |source, target|
            env[target] = normalize_yaml_value(retention[source]) if retention.key?(source)
          end
        end

        env.compact
      end

      def normalize_yaml_restic_password(raw_value, raw_env:, path:)
        case raw_value
        when Hash
          hash = stringify_keys(raw_value)
          if hash.key?("secret")
            { "RESTIC_PASSWORD" => resolve_yaml_value(hash, raw_env: raw_env, context: "#{path} restic.password") }
          elsif hash.key?("file")
            { "RESTIC_PASSWORD_FILE" => normalize_yaml_value(hash["file"]) }
          elsif hash.key?("command")
            { "RESTIC_PASSWORD_COMMAND" => normalize_yaml_value(hash["command"]) }
          else
            raise ConfigurationError, "#{path} restic.password must use secret, file, or command"
          end
        else
          { "RESTIC_PASSWORD" => normalize_yaml_value(raw_value) }
        end
      end

      def normalize_yaml_restic_rest(raw_value, raw_env:, path:)
        hash = require_mapping(raw_value, "#{path} restic.rest")
        env = {}
        username = hash.key?("username") ? hash["username"] : hash["user"]

        env["RESTIC_REST_USERNAME"] = resolve_yaml_value(username, raw_env: raw_env, context: "#{path} restic.rest.username") if username
        env["RESTIC_REST_PASSWORD"] = resolve_yaml_value(hash["password"], raw_env: raw_env, context: "#{path} restic.rest.password") if hash.key?("password")
        env.compact
      end

      def normalize_yaml_backup(raw_value, path:)
        hash = require_mapping(raw_value, "#{path} backup")
        env = {}
        env["BACKUP_SCHEDULE_SECONDS"] = normalize_duration(hash["schedule"], "#{path} backup.schedule") if hash.key?("schedule")
        env.compact
      end

      def normalize_yaml_state(raw_value, path:)
        hash = require_mapping(raw_value, "#{path} state")
        env = {}
        env["KAMAL_BACKUP_STATE_DIR"] = normalize_yaml_value(hash["path"]) if hash.key?("path")
        env.compact
      end

      def normalize_yaml_paths(raw_value, context)
        case raw_value
        when Array
          raw_value.map { |path| normalize_yaml_path(path, context) }.reject(&:empty?)
        when NilClass
          []
        else
          [normalize_yaml_path(raw_value, context)].reject(&:empty?)
        end
      end

      def normalize_yaml_path(raw_value, context)
        if raw_value.is_a?(Hash) || raw_value.is_a?(Array)
          raise ConfigurationError, "#{context} entries must be path strings"
        end

        normalize_yaml_value(raw_value)
      end

      def resolve_yaml_value(raw_value, raw_env:, context:)
        case raw_value
        when Hash
          hash = stringify_keys(raw_value)
          unless hash.keys == ["secret"]
            raise ConfigurationError, "#{context} must be a scalar value or { secret: NAME }"
          end

          secret_name = normalize_yaml_value(hash.fetch("secret"))
          raw_env[secret_name]
        else
          normalize_yaml_value(raw_value)
        end
      end

      def missing_yaml_secrets(raw_value, raw_env:)
        return [] unless raw_value.is_a?(Hash)

        hash = stringify_keys(raw_value)
        return [] unless hash.key?("secret")

        secret_name = normalize_yaml_value(hash.fetch("secret"))
        raw_env[secret_name].to_s.strip.empty? ? [secret_name] : []
      end

      def normalize_duration(raw_value, context)
        value = normalize_yaml_value(raw_value)
        raise ConfigurationError, "#{context} is required" if value.to_s.empty?

        return value if value.match?(/\A\d+\z/)

        match = value.match(/\A(\d+)\s*([smhdw])\z/i)
        unless match
          raise ConfigurationError, "#{context} must be seconds or a duration like 30m, 6h, or 1d"
        end

        amount = match[1].to_i
        multiplier = {
          "s" => 1,
          "m" => 60,
          "h" => 3600,
          "d" => 86_400,
          "w" => 604_800
        }.fetch(match[2].downcase)
        (amount * multiplier).to_s
      end

      def require_array(value, context)
        return value if value.is_a?(Array)

        raise ConfigurationError, "#{context} must be a YAML sequence"
      end

      def require_mapping(value, context)
        raise ConfigurationError, "#{context} must be a YAML mapping" unless value.is_a?(Hash)

        stringify_keys(value)
      end

      def required_yaml_scalar(hash, key, context)
        value = normalize_yaml_value(hash[key])
        raise ConfigurationError, "#{context} #{key} is required" if value.to_s.empty?

        value
      end

      def stringify_keys(hash)
        hash.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
      end

      def validate_local_machine_environment
        if environment = local_restore_environment
          key, value = environment

          if production_environment?(value)
            raise ConfigurationError, "restore local refuses to run with #{key}=#{value}; unset #{key} or use restore production"
          end
        end
      end

      def validate_local_machine_paths
        path_pairs = local_restore_path_pairs

        path_pairs.each do |_source_path, target_path|
          expanded = File.expand_path(target_path)
          if SUSPICIOUS_BACKUP_PATHS.include?(expanded) && !allow_suspicious_backup_paths?
            raise ConfigurationError, "refusing suspicious local restore path #{expanded}; set KAMAL_BACKUP_ALLOW_SUSPICIOUS_PATHS=true to override"
          end
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

      def normalize_adapter(value)
        case value.to_s.downcase
        when "postgres", "postgresql"
          "postgres"
        when "mysql", "mysql2", "mariadb"
          "mysql"
        when "sqlite", "sqlite3"
          "sqlite"
        else
          nil
        end
      end

      def database_definitions?
        !@database_definitions.nil?
      end

      def path_definitions?
        !@path_definitions.nil?
      end

      def legacy_database_adapter
        if explicit = value("DATABASE_ADAPTER")
          normalize_adapter(explicit)
        elsif adapter = adapter_from_database_url
          adapter
        elsif value("SQLITE_DATABASE_PATH")
          "sqlite"
        end
      end

      def adapter_from_database_url
        if url = value("DATABASE_URL")
          normalize_adapter(URI.parse(url).scheme)
        end
      rescue URI::InvalidURIError
        nil
      end

      def in_place_file_restore?(expanded_target)
        backup_paths.any? do |path|
          expanded_path = File.expand_path(path)
          expanded_target == expanded_path || expanded_path.start_with?(expanded_target + "/") || expanded_target.start_with?(expanded_path + "/")
        end
      end

      def source_database_targets
        databases.flat_map do |database|
          [
            database.value("DATABASE_URL"),
            database.value("SQLITE_DATABASE_PATH"),
            database.value("PGDATABASE"),
            database.value("MYSQL_DATABASE"),
            database.value("MARIADB_DATABASE")
          ]
        end.compact
      end

      def legacy_backup_paths
        split_paths(value("BACKUP_PATHS"))
      end

      def legacy_local_restore_source_paths
        if raw = value("LOCAL_RESTORE_SOURCE_PATHS")
          split_paths(raw)
        end
      end

      def split_paths(raw)
        raw.to_s.split(/[\n:]+/).map(&:strip).reject(&:empty?)
      end

      def local_restore_environment
        %w[RAILS_ENV RACK_ENV APP_ENV KAMAL_ENVIRONMENT].each do |key|
          if value(key)
            return [key, value(key)]
          end
        end
      end

      def production_environment?(value)
        %w[production prod live].include?(value.to_s.downcase)
      end

      def production_named_target?(target)
        target.include?("production") ||
          target.match?(%r{(^|[/_.:-])prod([/_.:-]|$)}) ||
          target.match?(%r{(^|[/_.:-])live([/_.:-]|$)})
      end
  end
end
