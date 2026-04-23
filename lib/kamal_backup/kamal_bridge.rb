require "yaml"
require_relative "command"

module KamalBackup
  class KamalBridge
    DEFAULT_CONFIG_FILE = "config/deploy.yml"

    def initialize(redactor:, config_file: nil, destination: nil)
      @redactor = redactor
      @config_file = config_file
      @destination = destination
    end

    def accessory_name(preferred: nil)
      if preferred && !preferred.to_s.strip.empty?
        accessory_clear_env(preferred)
        return preferred.to_s
      end

      matching = accessories.select do |_name, accessory|
        fetch(accessory, :image).to_s.include?("kamal-backup")
      end

      if matching.size == 1
        matching.keys.first.to_s
      elsif accessories.key?("backup") || accessories.key?(:backup)
        "backup"
      else
        names = accessories.keys.map(&:to_s).sort
        raise ConfigurationError, "could not infer the backup accessory from #{names.join(', ')}; set accessory in config/kamal-backup.yml"
      end
    end

    def local_restore_defaults(accessory_name:)
      clear_env = accessory_clear_env(accessory_name)

      {}.tap do |defaults|
        defaults["APP_NAME"] = clear_env["APP_NAME"] if clear_env["APP_NAME"]
        defaults["DATABASE_ADAPTER"] = clear_env["DATABASE_ADAPTER"] if clear_env["DATABASE_ADAPTER"]
        defaults["RESTIC_REPOSITORY"] = clear_env["RESTIC_REPOSITORY"] if clear_env["RESTIC_REPOSITORY"]
        defaults["LOCAL_RESTORE_SOURCE_PATHS"] = clear_env["BACKUP_PATHS"] if clear_env["BACKUP_PATHS"]
      end
    end

    def execute_on_accessory(accessory_name:, command:)
      capture_kamal(kamal_exec_argv(accessory_name, command))
    end

    private
      def config
        @config ||= begin
          result = capture_kamal(kamal_config_argv)
          load_method = YAML.respond_to?(:unsafe_load) ? :unsafe_load : :load
          YAML.public_send(load_method, result.stdout)
        end
      end

      def accessories
        fetch(config, :accessories) || {}
      end

      def accessory_clear_env(accessory_name)
        accessory = accessories.fetch(accessory_name) do
          accessories.fetch(accessory_name.to_sym) do
            raise ConfigurationError, "accessory #{accessory_name.inspect} is not defined in #{config_file || DEFAULT_CONFIG_FILE}"
          end
        end

        normalize_env(fetch(fetch(accessory, :env) || {}, :clear) || {})
      end

      def normalize_env(values)
        values.each_with_object({}) do |(key, value), env|
          env[key.to_s] = value.to_s
        end
      end

      def fetch(hash, key)
        hash[key] || hash[key.to_s] || hash[key.to_sym]
      end

      def kamal_config_argv
        [
          "kamal",
          "config",
          *kamal_option_argv,
          "--version",
          "latest"
        ]
      end

      def kamal_exec_argv(accessory_name, command)
        [
          "kamal",
          "accessory",
          "exec",
          accessory_name,
          command,
          *kamal_option_argv
        ]
      end

      def kamal_option_argv
        argv = []
        argv.concat(["-c", @config_file]) if @config_file
        argv.concat(["-d", @destination]) if @destination
        argv
      end

      def capture_kamal(argv)
        spec = CommandSpec.new(argv: argv)

        if defined?(Bundler)
          Bundler.with_unbundled_env { Command.capture(spec, redactor: @redactor) }
        else
          Command.capture(spec, redactor: @redactor)
        end
      end
  end
end
