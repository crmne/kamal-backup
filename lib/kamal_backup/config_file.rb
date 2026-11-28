# frozen_string_literal: true

require 'yaml'
require_relative 'errors'
require_relative 'databases/base'

module KamalBackup
  ConfigData = Struct.new(:env, :database_definitions, :path_definitions, :restore_from_definitions,
                          :copy_definitions, :missing_secrets, keyword_init: true) do
    def self.empty
      new(env: {}, database_definitions: nil, path_definitions: nil, restore_from_definitions: nil,
          copy_definitions: nil, missing_secrets: { 'restic' => [], 'rclone' => [] })
    end
  end

  PathDefinition = Struct.new(:path, :exclude, keyword_init: true)
  CopyDefinition = Struct.new(:source, :destination, :missing_secrets, keyword_init: true)

  # Parses one config/kamal-backup.yml into ConfigData. Parsed values resolve
  # to the same env keys the backup accessory receives, so process ENV always
  # wins over file config through a single merge in Config.
  class ConfigFile
    TOP_LEVEL_KEYS = %w[app accessory databases paths restore_from copies rclone restic backup state].freeze
    LEGACY_KEYS = %w[
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

    VARIABLE_PATTERN = /\$\{([A-Za-z_][A-Za-z0-9_]*)\}/

    def initialize(path, env:)
      @path = path
      @env = env
      @missing_variables = []
    end

    def data
      raw = YAML.safe_load(File.read(@path), permitted_classes: [], aliases: false)
      return ConfigData.empty if raw.nil?

      raise ConfigurationError, "#{@path} must contain a YAML mapping" unless raw.is_a?(Hash)

      result = raw.each_with_object(ConfigData.empty) do |(raw_key, raw_value), data|
        key = raw_key.to_s
        validate_top_level_key!(key)
        apply(data, key, raw_value)
      end
      record_missing_variables(result)
    rescue Psych::SyntaxError => e
      raise ConfigurationError, "invalid YAML in #{@path}: #{e.message}"
    end

    private

    def apply(result, key, raw_value)
      case key
      when 'app'
        result.env['APP_NAME'] = resolve_value(raw_value, context: "#{@path} app")
      when 'accessory'
        result.env['KAMAL_BACKUP_ACCESSORY'] = normalize_value(raw_value)
      when 'databases'
        result.database_definitions = databases(raw_value)
      when 'paths'
        result.path_definitions = backup_path_definitions(raw_value, "#{@path} paths")
      when 'restore_from'
        result.restore_from_definitions = path_list(raw_value, "#{@path} restore_from")
      when 'copies'
        result.copy_definitions = copy_definitions(raw_value)
      when 'rclone'
        result.env.merge!(rclone_env(raw_value, result.missing_secrets.fetch('rclone')))
      when 'restic'
        result.env.merge!(restic_env(raw_value, result.missing_secrets.fetch('restic')))
      when 'backup'
        result.env.merge!(backup_env(raw_value))
      when 'state'
        result.env.merge!(state_env(raw_value))
      end
    end

    def validate_top_level_key!(key)
      if LEGACY_KEYS.include?(key)
        raise ConfigurationError,
              "#{@path} uses legacy key #{key}; use databases, paths, restic, and backup instead. See the upgrading guide for the 0.3 config migration."
      end

      return if TOP_LEVEL_KEYS.include?(key)

      raise ConfigurationError,
            "#{@path} contains unknown key #{key.inspect}; expected #{TOP_LEVEL_KEYS.join(', ')}"
    end

    def databases(raw_value)
      entries = require_array(raw_value, "#{@path} databases")
      entries.map.with_index(1) do |entry, index|
        context = "#{@path} databases[#{index}]"
        hash = require_mapping(entry, context)
        name = required_scalar(hash, 'name', context)
        adapter = Databases.normalize_adapter(required_scalar(hash, 'adapter', context))
        raise ConfigurationError, "#{context} adapter must be postgres, mysql, or sqlite" unless adapter

        env = {}
        missing_secrets = []
        database_connection_sources(hash, adapter, context).each do |env_key, raw, value_context|
          env[env_key] = resolve_value(raw, context: value_context)
          missing_secrets.concat(missing_secrets_for(raw))
        end

        {
          name: name,
          adapter: adapter,
          env: env.compact,
          missing_secrets: missing_secrets
        }
      end
    end

    def database_connection_sources(hash, adapter, context)
      case adapter
      when 'postgres', 'mysql'
        password_key = adapter == 'postgres' ? 'PGPASSWORD' : 'MYSQL_PWD'
        [].tap do |sources|
          sources << ['DATABASE_URL', hash['url'], "#{context}.url"] if hash.key?('url')
          sources << [password_key, hash['password'], "#{context}.password"] if hash.key?('password')
        end
      when 'sqlite'
        sqlite_path = hash.key?('path') ? hash['path'] : hash['database']
        sqlite_path ? [['SQLITE_DATABASE_PATH', sqlite_path, "#{context}.path"]] : []
      end
    end

    def backup_path_definitions(raw_value, context)
      definitions =
        case raw_value
        when Array
          raw_value.map.with_index(1) { |entry, index| backup_path_definition(entry, "#{context}[#{index}]") }
        when NilClass
          []
        else
          [backup_path_definition(raw_value, "#{context}[1]")]
        end

      definitions.reject { |definition| definition.path.to_s.empty? }
    end

    def backup_path_definition(raw_value, context)
      case raw_value
      when Hash
        hash = require_mapping(raw_value, context)
        unknown_keys = hash.keys - %w[path exclude]
        unless unknown_keys.empty?
          raise ConfigurationError,
                "#{context} contains unknown key #{unknown_keys.first.inspect}; expected path and exclude"
        end

        path = required_string(hash, 'path', context)
        exclude = hash.key?('exclude') ? exclude_patterns(hash['exclude'], "#{context}.exclude") : []
        PathDefinition.new(path: path, exclude: exclude)
      when Array
        raise ConfigurationError, "#{context} must be a path string or a mapping with path and optional exclude"
      else
        PathDefinition.new(path: normalize_value(raw_value), exclude: [])
      end
    end

    def exclude_patterns(raw_value, context)
      entries = require_array(raw_value, context)
      entries.map.with_index(1) do |entry, index|
        pattern = optional_string(entry, "#{context}[#{index}]")
        raise ConfigurationError, "#{context}[#{index}] must not be empty" if pattern.to_s.strip.empty?

        pattern
      end
    end

    def copy_definitions(raw_value)
      return [] if raw_value.nil?

      entries = require_array(raw_value, "#{@path} copies")
      entries.map.with_index(1) do |entry, index|
        context = "#{@path} copies[#{index}]"
        hash = require_mapping(entry, context)
        unknown_keys = hash.keys - %w[source destination]
        unless unknown_keys.empty?
          raise ConfigurationError,
                "#{context} contains unknown key #{unknown_keys.first.inspect}; expected source and destination"
        end

        missing_secrets = []
        values = %w[source destination].to_h do |key|
          raise ConfigurationError, "#{context} #{key} is required" unless hash.key?(key)

          missing_secrets.concat(missing_secrets_for(hash[key]))
          [key, resolve_value(hash[key], context: "#{context}.#{key}")]
        end

        CopyDefinition.new(source: values['source'], destination: values['destination'],
                           missing_secrets: missing_secrets)
      end
    end

    def path_list(raw_value, context)
      case raw_value
      when Array
        raw_value.map { |path| path_string(path, context) }.reject(&:empty?)
      when NilClass
        []
      else
        [path_string(raw_value, context)].reject(&:empty?)
      end
    end

    def path_string(raw_value, context)
      raise ConfigurationError, "#{context} entries must be path strings" if raw_value.is_a?(Hash) || raw_value.is_a?(Array)

      normalize_value(raw_value)
    end

    def restic_env(raw_value, missing_secrets)
      hash = require_mapping(raw_value, "#{@path} restic")
      env = {}

      env['RESTIC_REPOSITORY'] = resolve_value(hash['repository'], context: "#{@path} restic.repository") if hash.key?('repository')
      env['RESTIC_REPOSITORY_FILE'] = normalize_value(hash['repository_file']) if hash.key?('repository_file')
      env.merge!(restic_password_env(hash['password'])) if hash.key?('password')
      env.merge!(restic_rest_env(hash['rest'])) if hash.key?('rest')
      env.merge!(restic_s3_env(hash['s3'], missing_secrets)) if hash.key?('s3')

      {
        'init_if_missing' => 'RESTIC_INIT_IF_MISSING',
        'check_after_backup' => 'RESTIC_CHECK_AFTER_BACKUP',
        'check_read_data_subset' => 'RESTIC_CHECK_READ_DATA_SUBSET',
        'forget_after_backup' => 'RESTIC_FORGET_AFTER_BACKUP'
      }.each do |source, target|
        env[target] = normalize_value(hash[source]) if hash.key?(source)
      end

      env.merge!(retention_env(hash['retention'])) if hash.key?('retention')
      env.compact
    end

    def restic_password_env(raw_value)
      case raw_value
      when Hash
        hash = stringify_keys(raw_value)
        if hash.key?('secret')
          { 'RESTIC_PASSWORD' => resolve_value(hash, context: "#{@path} restic.password") }
        elsif hash.key?('file')
          { 'RESTIC_PASSWORD_FILE' => normalize_value(hash['file']) }
        elsif hash.key?('command')
          { 'RESTIC_PASSWORD_COMMAND' => normalize_value(hash['command']) }
        else
          raise ConfigurationError, "#{@path} restic.password must use secret, file, or command"
        end
      else
        { 'RESTIC_PASSWORD' => normalize_value(raw_value) }
      end
    end

    def restic_rest_env(raw_value)
      hash = require_mapping(raw_value, "#{@path} restic.rest")
      env = {}
      username = hash.key?('username') ? hash['username'] : hash['user']

      env['RESTIC_REST_USERNAME'] = resolve_value(username, context: "#{@path} restic.rest.username") if username
      env['RESTIC_REST_PASSWORD'] = resolve_value(hash['password'], context: "#{@path} restic.rest.password") if hash.key?('password')
      env.compact
    end

    RESTIC_S3_KEYS = {
      'access_key_id' => 'AWS_ACCESS_KEY_ID',
      'secret_access_key' => 'AWS_SECRET_ACCESS_KEY',
      'region' => 'AWS_DEFAULT_REGION'
    }.freeze

    # S3 credentials for an s3: restic repository, so they can be named in YAML
    # instead of passing AWS_* variables to the accessory.
    def restic_s3_env(raw_value, missing_secrets)
      context = "#{@path} restic.s3"
      hash = require_mapping(raw_value, context)
      unknown_keys = hash.keys - RESTIC_S3_KEYS.keys
      unless unknown_keys.empty?
        raise ConfigurationError,
              "#{context} contains unknown key #{unknown_keys.first.inspect}; expected #{RESTIC_S3_KEYS.keys.join(', ')}"
      end

      hash.each_with_object({}) do |(key, value), env|
        missing_secrets.concat(missing_secrets_for(value).map { |name| "#{name} (restic.s3.#{key})" })
        env[RESTIC_S3_KEYS.fetch(key)] = resolve_value(value, context: "#{context}.#{key}")
      end.compact
    end

    # rclone remotes used by copies, as RCLONE_CONFIG_<REMOTE>_<OPTION> variables.
    def rclone_env(raw_value, missing_secrets)
      remotes = require_mapping(raw_value, "#{@path} rclone")
      remotes.each_with_object({}) do |(name, options), env|
        context = "#{@path} rclone.#{name}"
        raise ConfigurationError, "#{context} remote name must contain only letters, digits, and _" unless name.match?(/\A[A-Za-z0-9_]+\z/)

        options = require_mapping(options, context)
        raise ConfigurationError, "#{context} type is required" if normalize_value(options['type']).to_s.empty?

        options.each do |option, value|
          raise ConfigurationError, "#{context} option #{option.inspect} must contain only letters, digits, and _" unless option.match?(/\A[A-Za-z0-9_]+\z/)

          missing_secrets.concat(missing_secrets_for(value).map { |secret| "#{secret} (rclone.#{name}.#{option})" })
          resolved = resolve_value(value, context: "#{context}.#{option}")
          env["RCLONE_CONFIG_#{name.upcase}_#{option.upcase}"] = resolved unless resolved.nil?
        end
      end
    end

    def retention_env(raw_value)
      retention = require_mapping(raw_value, "#{@path} restic.retention")

      {
        'keep_last' => 'RESTIC_KEEP_LAST',
        'keep_daily' => 'RESTIC_KEEP_DAILY',
        'keep_weekly' => 'RESTIC_KEEP_WEEKLY',
        'keep_monthly' => 'RESTIC_KEEP_MONTHLY',
        'keep_yearly' => 'RESTIC_KEEP_YEARLY'
      }.each_with_object({}) do |(source, target), env|
        env[target] = normalize_value(retention[source]) if retention.key?(source)
      end
    end

    def backup_env(raw_value)
      hash = require_mapping(raw_value, "#{@path} backup")
      env = {}
      env['BACKUP_SCHEDULE_SECONDS'] = normalize_duration(hash['schedule'], "#{@path} backup.schedule") if hash.key?('schedule')
      env['BACKUP_ENABLED'] = normalize_value(hash['enabled']) if hash.key?('enabled')
      env.compact
    end

    def normalize_duration(raw_value, context)
      value = normalize_value(raw_value)
      raise ConfigurationError, "#{context} is required" if value.to_s.empty?

      return value if value.match?(/\A\d+\z/)

      match = value.match(/\A(\d+)\s*([smhdw])\z/i)
      raise ConfigurationError, "#{context} must be seconds or a duration like 30m, 6h, or 1d" unless match

      amount = match[1].to_i
      multiplier = {
        's' => 1,
        'm' => 60,
        'h' => 3600,
        'd' => 86_400,
        'w' => 604_800
      }.fetch(match[2].downcase)
      (amount * multiplier).to_s
    end

    def state_env(raw_value)
      hash = require_mapping(raw_value, "#{@path} state")
      env = {}
      env['KAMAL_BACKUP_STATE_DIR'] = normalize_value(hash['path']) if hash.key?('path')
      env.compact
    end

    def resolve_value(raw_value, context:)
      case raw_value
      when Hash
        hash = stringify_keys(raw_value)
        raise ConfigurationError, "#{context} must be a scalar value or { secret: NAME }" unless hash.keys == ['secret']

        secret_name = normalize_value(hash.fetch('secret'))
        @env[secret_name]
      else
        interpolate(normalize_value(raw_value), context: context)
      end
    end

    # Replaces ${NAME} in scalar values with the environment variable NAME.
    # A missing variable becomes empty and is reported by validation, so
    # commands that do not need that value keep working.
    def interpolate(value, context:)
      return value unless value.is_a?(String) && value.include?('${')

      value.gsub(VARIABLE_PATTERN) do
        name = ::Regexp.last_match(1)
        resolved = @env[name].to_s
        @missing_variables << [name, context] if resolved.strip.empty?
        resolved
      end
    end

    def record_missing_variables(result)
      @missing_variables.each do |name, context|
        label = context.delete_prefix("#{@path} ")
        group = label.start_with?('rclone', 'copies') ? 'rclone' : 'restic'
        result.missing_secrets.fetch(group) << "${#{name}} (#{label})"
      end
      result
    end

    def missing_secrets_for(raw_value)
      return [] unless raw_value.is_a?(Hash)

      hash = stringify_keys(raw_value)
      return [] unless hash.key?('secret')

      secret_name = normalize_value(hash.fetch('secret'))
      @env[secret_name].to_s.strip.empty? ? [secret_name] : []
    end

    def normalize_value(raw_value)
      case raw_value
      when Array
        raw_value.map(&:to_s).join("\n")
      when NilClass
        nil
      else
        raw_value.to_s
      end
    end

    def require_array(value, context)
      return value if value.is_a?(Array)

      raise ConfigurationError, "#{context} must be a YAML sequence"
    end

    def require_mapping(value, context)
      raise ConfigurationError, "#{context} must be a YAML mapping" unless value.is_a?(Hash)

      stringify_keys(value)
    end

    def optional_string(value, context)
      raise ConfigurationError, "#{context} must be a string" if value.is_a?(Hash) || value.is_a?(Array)

      normalize_value(value)
    end

    def required_string(hash, key, context)
      raise ConfigurationError, "#{context} #{key} is required" unless hash.key?(key)

      value = optional_string(hash[key], "#{context}.#{key}")
      raise ConfigurationError, "#{context} #{key} is required" if value.to_s.strip.empty?

      value
    end

    def required_scalar(hash, key, context)
      value = normalize_value(hash[key])
      raise ConfigurationError, "#{context} #{key} is required" if value.to_s.empty?

      value
    end

    def stringify_keys(hash)
      hash.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
    end
  end
end
