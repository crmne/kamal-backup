require "shellwords"
require "yaml"
require_relative "command"

module KamalBackup
  class KamalBridge
    DEFAULT_CONFIG_FILE = "config/deploy.yml"
    VERSION_LINE_PATTERN = /\A\d+(?:\.\d+)+(?:[-.][A-Za-z0-9]+)*\z/

    def initialize(redactor:, config_file: nil, destination: nil, env: ENV, cwd: Dir.pwd, stdout: $stdout, stderr: $stderr)
      @redactor = redactor
      @config_file = config_file
      @destination = destination
      @env = env
      @cwd = cwd
      @stdout = stdout
      @stderr = stderr
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

    def accessory_environment(accessory_name:)
      accessory_secret_placeholders(accessory_name).merge(accessory_clear_env(accessory_name))
    end

    def execute_on_accessory(accessory_name:, command:, stream: false)
      capture_kamal(kamal_exec_argv(accessory_name, command), stream: stream)
    end

    def remote_version(accessory_name:)
      result = execute_on_accessory(accessory_name: accessory_name, command: "kamal-backup version")
      version = parse_version_line(result.stdout)

      if version.empty?
        raise ConfigurationError, "could not determine remote kamal-backup version from accessory #{accessory_name}"
      else
        version
      end
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
        normalize_env(fetch(accessory_env(accessory_name), :clear) || {})
      end

      def accessory_secret_placeholders(accessory_name)
        normalize_secret_env(fetch(accessory_env(accessory_name), :secret))
      end

      def accessory_env(accessory_name)
        fetch(accessory(accessory_name), :env) || {}
      end

      def accessory(accessory_name)
        accessories.fetch(accessory_name) do
          accessories.fetch(accessory_name.to_sym) do
            raise ConfigurationError, "accessory #{accessory_name.inspect} is not defined in #{config_file || DEFAULT_CONFIG_FILE}"
          end
        end
      end

      def normalize_env(values)
        values.each_with_object({}) do |(key, value), env|
          env[key.to_s] = value.to_s
        end
      end

      def normalize_secret_env(values)
        case values
        when Hash
          values.each_with_object({}) do |(key, secret_key), env|
            add_resolved_secret(env, target: key, source: secret_key)
          end
        when Array
          values.each_with_object({}) do |entry, env|
            target, source = parse_secret_entry(entry)
            add_resolved_secret(env, target: target, source: source)
          end
        when String, Symbol
          {}.tap do |env|
            target, source = parse_secret_entry(values)
            add_resolved_secret(env, target: target, source: source)
          end
        else
          {}
        end
      end

      def parse_secret_entry(entry)
        target, source = entry.to_s.split(":", 2)
        [ target, source || target ]
      end

      def add_resolved_secret(env, target:, source:)
        if value = resolved_secret(source)
          env[target.to_s] = value
        end
      end

      def resolved_secret(key)
        raw = resolved_secrets[key.to_s] || @env[key.to_s]
        value = raw.to_s.strip
        value.empty? ? nil : value
      end

      def resolved_secrets
        @resolved_secrets ||= parse_secret_output(capture_kamal(kamal_secrets_print_argv).stdout)
      end

      def parse_secret_output(output)
        output.to_s.lines.each_with_object({}) do |line, secrets|
          tokens = Shellwords.split(line.chomp)
          tokens.shift if tokens.first == "export"

          tokens.each do |assignment|
            key, value = assignment.split("=", 2)
            next if key.to_s.empty? || value.nil?

            secrets[key] = value.to_s
          end
        end
      end

      def fetch(hash, key)
        hash[key] || hash[key.to_s] || hash[key.to_sym]
      end

      def kamal_config_argv
        [
          *kamal_command,
          "config",
          *kamal_option_argv,
          "--version",
          "latest"
        ]
      end

      def kamal_exec_argv(accessory_name, command)
        [
          *kamal_command,
          "accessory",
          "exec",
          *kamal_option_argv,
          "--reuse",
          accessory_name,
          command
        ]
      end

      def kamal_secrets_print_argv
        [
          *kamal_command,
          "secrets",
          "print",
          *kamal_option_argv
        ]
      end

      def kamal_command
        if File.executable?(File.join(@cwd, "bin", "kamal"))
          [ "bin/kamal" ]
        elsif File.file?(File.join(@cwd, "Gemfile"))
          [ "bundle", "exec", "kamal" ]
        else
          [ "kamal" ]
        end
      end

      def kamal_option_argv
        argv = []
        argv.concat(["-c", @config_file]) if @config_file
        argv.concat(["-d", @destination]) if @destination
        argv
      end

      def capture_kamal(argv, stream: false)
        spec = CommandSpec.new(argv: argv)
        options = {
          redactor: @redactor,
          log: false,
          log_output: false,
          tee_stdout: stream ? @stdout : nil,
          tee_stderr: stream ? @stderr : nil
        }

        if defined?(Bundler)
          Bundler.with_unbundled_env { Command.capture(spec, **options) }
        else
          Command.capture(spec, **options)
        end
      end

      def parse_version_line(output)
        output.to_s.lines.map(&:strip).reverse.find { |line| line.match?(VERSION_LINE_PATTERN) }.to_s
      end
  end
end
