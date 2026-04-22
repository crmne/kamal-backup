require "fileutils"
require "pathname"
require "time"
require "uri"
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

    attr_reader :env

    def initialize(env: ENV)
      @env = env.to_h
    end

    def app_name
      value("APP_NAME")
    end

    def app_name!
      required!("APP_NAME")
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

    def check_read_data_subset
      value("RESTIC_CHECK_READ_DATA_SUBSET")
    end

    def allow_restore?
      truthy?("KAMAL_BACKUP_ALLOW_RESTORE")
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

    def backup_paths
      raw = value("BACKUP_PATHS").to_s
      raw.split(/[\n:]+/).map(&:strip).reject(&:empty?)
    end

    def backup_path_label(path)
      label = path.to_s.sub(%r{\A/+}, "").gsub(%r{[^A-Za-z0-9_.-]+}, "-")
      label.empty? ? "root" : label
    end

    def database_adapter
      explicit = value("DATABASE_ADAPTER")
      return normalize_adapter(explicit) if explicit

      url = value("DATABASE_URL")
      if url
        scheme = URI.parse(url).scheme rescue nil
        detected = normalize_adapter(scheme)
        return detected if detected
      end

      return "sqlite" if value("SQLITE_DATABASE_PATH")

      nil
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

    def validate_for_restic!
      app_name!
      required!("RESTIC_REPOSITORY")
      required!("RESTIC_PASSWORD")
    end

    def validate_for_backup!
      validate_for_restic!
      validate_database_backup!
      validate_backup_paths!
    end

    def validate_database_backup!
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
        path = required!("SQLITE_DATABASE_PATH")
        raise ConfigurationError, "SQLITE_DATABASE_PATH does not exist: #{path}" unless File.file?(path)
      else
        raise ConfigurationError, "DATABASE_ADAPTER is required or must be detectable from DATABASE_URL/SQLITE_DATABASE_PATH"
      end
    end

    def validate_backup_paths!
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

    def validate_restore_allowed!
      return if allow_restore?

      raise ConfigurationError, "restore commands require KAMAL_BACKUP_ALLOW_RESTORE=true"
    end

    def validate_file_restore_target!(target)
      raise ConfigurationError, "restore target cannot be empty" if target.to_s.strip.empty?

      expanded_target = File.expand_path(target)
      raise ConfigurationError, "refusing to restore files to /" if expanded_target == "/"

      in_place = backup_paths.any? do |path|
        expanded_path = File.expand_path(path)
        expanded_target == expanded_path || expanded_path.start_with?(expanded_target + "/") || expanded_target.start_with?(expanded_path + "/")
      end

      if in_place && !allow_in_place_file_restore?
        raise ConfigurationError, "refusing in-place file restore to #{expanded_target}; set KAMAL_BACKUP_ALLOW_IN_PLACE_FILE_RESTORE=true to override"
      end

      expanded_target
    end

    def validate_database_restore_target!(target)
      raise ConfigurationError, "restore database target is required" if target.to_s.strip.empty?

      if production_like_target?(target) && !allow_production_restore?
        raise ConfigurationError, "refusing production-looking restore target #{target}; set KAMAL_BACKUP_ALLOW_PRODUCTION_RESTORE=true to override"
      end
    end

    def production_like_target?(target)
      target = target.to_s
      source_targets = [
        value("DATABASE_URL"),
        value("SQLITE_DATABASE_PATH"),
        value("PGDATABASE"),
        value("MYSQL_DATABASE"),
        value("MARIADB_DATABASE")
      ].compact

      return true if source_targets.include?(target)

      lowered = target.downcase
      lowered.include?("production") ||
        lowered.match?(%r{(^|[/_.:-])prod([/_.:-]|$)}) ||
        lowered.match?(%r{(^|[/_.:-])live([/_.:-]|$)})
    end

    def value(key)
      raw = env[key]
      return nil if raw.nil?

      stripped = raw.to_s.strip
      stripped.empty? ? nil : stripped
    end

    def required!(key)
      value(key) || raise(ConfigurationError, "#{key} is required")
    end

    def truthy?(key)
      %w[1 true yes y on].include?(value(key).to_s.downcase)
    end

    private

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
  end
end
