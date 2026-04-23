require "uri"
require "yaml"
require_relative "errors"

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
    DEFAULT_CONFIG_PATHS = %w[config/kamal-backup.yml config/kamal-backup.local.yml].freeze
    YAML_KEY_ALIASES = {
      "app_name" => "APP_NAME",
      "database_adapter" => "DATABASE_ADAPTER",
      "database_url" => "DATABASE_URL",
      "sqlite_database_path" => "SQLITE_DATABASE_PATH",
      "backup_paths" => "BACKUP_PATHS",
      "local_restore_source_paths" => "LOCAL_RESTORE_SOURCE_PATHS",
      "accessory" => "KAMAL_BACKUP_ACCESSORY",
      "restic_repository" => "RESTIC_REPOSITORY",
      "restic_password" => "RESTIC_PASSWORD",
      "restic_init_if_missing" => "RESTIC_INIT_IF_MISSING",
      "restic_check_after_backup" => "RESTIC_CHECK_AFTER_BACKUP",
      "restic_check_read_data_subset" => "RESTIC_CHECK_READ_DATA_SUBSET",
      "restic_forget_after_backup" => "RESTIC_FORGET_AFTER_BACKUP",
      "restic_keep_last" => "RESTIC_KEEP_LAST",
      "restic_keep_daily" => "RESTIC_KEEP_DAILY",
      "restic_keep_weekly" => "RESTIC_KEEP_WEEKLY",
      "restic_keep_monthly" => "RESTIC_KEEP_MONTHLY",
      "restic_keep_yearly" => "RESTIC_KEEP_YEARLY",
      "backup_schedule_seconds" => "BACKUP_SCHEDULE_SECONDS",
      "backup_start_delay_seconds" => "BACKUP_START_DELAY_SECONDS",
      "state_dir" => "KAMAL_BACKUP_STATE_DIR",
      "allow_production_restore" => "KAMAL_BACKUP_ALLOW_PRODUCTION_RESTORE",
      "allow_suspicious_paths" => "KAMAL_BACKUP_ALLOW_SUSPICIOUS_PATHS",
      "pgpassword" => "PGPASSWORD",
      "mysql_pwd" => "MYSQL_PWD"
    }.freeze

    attr_reader :env

    def initialize(env: ENV, cwd: Dir.pwd, defaults: {})
      raw_env = env.to_h
      @env = defaults.to_h.merge(load_config_files(raw_env, cwd: cwd)).merge(raw_env)
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

    def restic_password
      value("RESTIC_PASSWORD")
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

    def allow_production_restore?
      truthy?("KAMAL_BACKUP_ALLOW_PRODUCTION_RESTORE")
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
      split_paths(value("BACKUP_PATHS"))
    end

    def local_restore_source_paths
      if raw = value("LOCAL_RESTORE_SOURCE_PATHS")
        split_paths(raw)
      else
        backup_paths
      end
    end

    def local_restore_path_pairs
      source_paths = local_restore_source_paths
      target_paths = backup_paths

      if source_paths.size == target_paths.size
        source_paths.zip(target_paths)
      else
        raise ConfigurationError, "LOCAL_RESTORE_SOURCE_PATHS must contain the same number of paths as BACKUP_PATHS"
      end
    end

    def backup_path_label(path)
      label = path.to_s.sub(%r{\A/+}, "").gsub(%r{[^A-Za-z0-9_.-]+}, "-")
      label.empty? ? "root" : label
    end

    def database_adapter
      if explicit = value("DATABASE_ADAPTER")
        normalize_adapter(explicit)
      elsif adapter = adapter_from_database_url
        adapter
      elsif value("SQLITE_DATABASE_PATH")
        "sqlite"
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

    def validate_restic
      required_app_name
      required_value("RESTIC_REPOSITORY")
      required_value("RESTIC_PASSWORD")
    end

    def validate_backup
      validate_restic
      validate_database_backup
      validate_backup_paths
    end

    def validate_local_machine_restore
      validate_local_machine_environment
      validate_local_machine_paths
    end

    def validate_database_backup
      case database_adapter
      when "postgres"
        unless value("DATABASE_URL") || value("PGDATABASE")
          raise ConfigurationError, "PostgreSQL backup requires DATABASE_URL or PGDATABASE/libpq environment"
        end
      when "mysql"
        unless value("DATABASE_URL") || value("MYSQL_DATABASE") || value("MARIADB_DATABASE")
          raise ConfigurationError, "MySQL backup requires DATABASE_URL or MYSQL_DATABASE/MARIADB_DATABASE"
        end
      when "sqlite"
        path = required_value("SQLITE_DATABASE_PATH")
        raise ConfigurationError, "SQLITE_DATABASE_PATH does not exist: #{path}" unless File.file?(path)
      else
        raise ConfigurationError, "DATABASE_ADAPTER is required or must be detectable from DATABASE_URL/SQLITE_DATABASE_PATH"
      end
    end

    def validate_backup_paths
      paths = backup_paths
      raise ConfigurationError, "BACKUP_PATHS must contain at least one path" if paths.empty?

      paths.each do |path|
        expanded = File.expand_path(path)
        if SUSPICIOUS_BACKUP_PATHS.include?(expanded) && !allow_suspicious_backup_paths?
          raise ConfigurationError, "refusing suspicious backup path #{expanded}; set KAMAL_BACKUP_ALLOW_SUSPICIOUS_PATHS=true to override"
        end
        raise ConfigurationError, "backup path does not exist: #{path}" unless File.exist?(path)
      end
    end

    def validate_local_database_restore_target(target)
      raise ConfigurationError, "local restore database target is required" if target.to_s.strip.empty?

      if production_named_target?(target) && !allow_production_restore?
        raise ConfigurationError, "refusing production-looking local restore target #{target}; set KAMAL_BACKUP_ALLOW_PRODUCTION_RESTORE=true to override"
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

      if production_like_target?(target) && !allow_production_restore?
        raise ConfigurationError, "refusing production-looking restore target #{target}; set KAMAL_BACKUP_ALLOW_PRODUCTION_RESTORE=true to override"
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
      def load_config_files(raw_env, cwd:)
        config_paths(raw_env, cwd: cwd).each_with_object({}) do |path, merged|
          next unless File.file?(path)

          merged.merge!(normalize_config_file(path))
        end
      end

      def config_paths(raw_env, cwd:)
        if explicit = raw_env["KAMAL_BACKUP_CONFIG"]
          [File.expand_path(explicit, cwd)]
        else
          DEFAULT_CONFIG_PATHS.map { |relative| File.expand_path(relative, cwd) }
        end
      end

      def normalize_config_file(path)
        data = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
        return {} if data.nil?

        unless data.is_a?(Hash)
          raise ConfigurationError, "#{path} must contain a YAML mapping"
        end

        data.each_with_object({}) do |(raw_key, raw_value), result|
          key = normalize_yaml_key(raw_key)
          result[key] = normalize_yaml_value(raw_value)
        end
      rescue Psych::SyntaxError => e
        raise ConfigurationError, "invalid YAML in #{path}: #{e.message}"
      end

      def normalize_yaml_key(raw_key)
        key = raw_key.to_s
        YAML_KEY_ALIASES[key] || key.upcase
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

      def validate_local_machine_environment
        if environment = local_restore_environment
          key, value = environment

          if production_environment?(value) && !allow_production_restore?
            raise ConfigurationError, "restore local refuses to run with #{key}=#{value}; set KAMAL_BACKUP_ALLOW_PRODUCTION_RESTORE=true to override"
          end
        end
      end

      def validate_local_machine_paths
        path_pairs = local_restore_path_pairs
        raise ConfigurationError, "BACKUP_PATHS must contain at least one path" if path_pairs.empty?

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
        [
          value("DATABASE_URL"),
          value("SQLITE_DATABASE_PATH"),
          value("PGDATABASE"),
          value("MYSQL_DATABASE"),
          value("MARIADB_DATABASE")
        ].compact
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
