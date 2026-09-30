# frozen_string_literal: true

require 'open3'
require 'shellwords'
require 'tempfile'
require 'yaml'
require_relative 'command'
require_relative 'yaml_access'

module KamalBackup
  class KamalBridge
    include YamlAccess

    DEFAULT_CONFIG_FILE = 'config/deploy.yml'
    VERSION_LINE_PATTERN = /\A\d+(?:\.\d+)+(?:[-.][A-Za-z0-9]+)*\z/

    class FilteringIO
      def initialize(io, &reject)
        @io = io
        @reject = reject
      end

      def print(output)
        @io.print(output) unless @reject.call(output.to_s)
      end

      def flush
        @io.flush if @io.respond_to?(:flush)
      end
    end

    def initialize(redactor:, config_file: nil, destination: nil, env: ENV, cwd: Dir.pwd, stdout: $stdout,
                   stderr: $stderr)
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
        fetch(accessory, :image).to_s.include?('kamal-backup')
      end

      if matching.size == 1
        matching.keys.first.to_s
      elsif accessories.key?('backup') || accessories.key?(:backup)
        'backup'
      else
        names = accessories.keys.map(&:to_s).sort
        raise ConfigurationError,
              "could not infer the backup accessory from #{names.join(', ')}; set accessory in config/kamal-backup.yml"
      end
    end

    def local_restore_defaults(accessory_name:)
      clear_env = accessory_clear_env(accessory_name)

      {}.tap do |defaults|
        defaults['APP_NAME'] = clear_env['APP_NAME'] if clear_env['APP_NAME']
        defaults['DATABASE_ADAPTER'] = clear_env['DATABASE_ADAPTER'] if clear_env['DATABASE_ADAPTER']
        defaults['RESTIC_REPOSITORY'] = clear_env['RESTIC_REPOSITORY'] if clear_env['RESTIC_REPOSITORY']
        defaults['LOCAL_RESTORE_SOURCE_PATHS'] = clear_env['BACKUP_PATHS'] if clear_env['BACKUP_PATHS']
      end
    end

    def accessory_environment(accessory_name:)
      accessory_secret_placeholders(accessory_name).merge(accessory_clear_env(accessory_name))
    end

    def execute_on_accessory(accessory_name:, command:, stream: false)
      command_argv = remote_command_argv(command)

      if stream && (target = live_accessory_target(accessory_name))
        execute_on_accessory_live(accessory_name: accessory_name, command_argv: command_argv, target: target)
      else
        capture_kamal(kamal_exec_argv(accessory_name, command_argv), stream: stream)
      end
    end

    # Run restic on the live accessory over SSH + docker exec without Kamal's
    # log wrapper. Kamal accessory exec mixes INFO lines into stdout.
    def capture_restic_command(accessory_name:, argv:, repository: nil, repository_file: nil)
      stdout = +''
      run_restic_on_accessory(
        accessory_name: accessory_name,
        repository: repository,
        repository_file: repository_file,
        argv: argv
      ) do |stream|
        stdout << stream.read
      end
      stdout
    end

    # Stream a restic dump over SSH + docker exec without Kamal's log wrapper.
    # Kamal accessory exec mixes INFO lines into stdout, which corrupts binary dumps.
    def stream_restic_dump(accessory_name:, snapshot:, filename:, io:, repository: nil, repository_file: nil)
      run_restic_on_accessory(
        accessory_name: accessory_name,
        repository: repository,
        repository_file: repository_file,
        argv: ['dump', snapshot.to_s, filename.to_s],
        snapshot: snapshot,
        filename: filename
      ) do |stdout|
        IO.copy_stream(stdout, io)
      end

      true
    end

    def remote_version(accessory_name:)
      result = execute_on_accessory(accessory_name: accessory_name, command: %w[kamal-backup version])
      version = parse_version_line(result.stdout)

      raise ConfigurationError, "could not determine remote kamal-backup version from accessory #{accessory_name}" if version.empty?

      version
    end

    private

    def run_restic_on_accessory(accessory_name:, argv:, snapshot: nil, filename: nil, repository: nil,
                                repository_file: nil)
      config
      target = live_accessory_target(accessory_name)
      unless target
        raise ConfigurationError,
              "could not find a live backup accessory #{accessory_name.inspect} to dump from"
      end

      docker_argv = [
        'docker', 'exec',
        '-e', restic_docker_env_assignment(repository: repository, repository_file: repository_file),
        target.fetch(:service_name),
        'restic', *Array(argv).map(&:to_s)
      ]
      remote = docker_argv.shelljoin

      with_ssh_identity_files do |identity_files, config_file|
        spec = CommandSpec.new(
          argv: ssh_argv(target.fetch(:host), remote, identity_files: identity_files, config_file: config_file)
        )
        Open3.popen3(*spec.argv) do |stdin, stdout, stderr, wait_thread|
          stdin.close
          err_reader = Thread.new { stderr.read }
          yield stdout
          err = err_reader.value
          status = wait_thread.value
          unless status.success?
            raise_restic_accessory_error(
              spec,
              status.exitstatus,
              err,
              snapshot: snapshot || argv[1],
              filename: filename || argv[2],
              docker_argv: docker_argv
            )
          end
        end
      end
    end

    def restic_docker_env_assignment(repository:, repository_file:)
      if repository && !repository.to_s.empty?
        "RESTIC_REPOSITORY=#{repository}"
      elsif repository_file && !repository_file.to_s.empty?
        "RESTIC_REPOSITORY_FILE=#{repository_file}"
      else
        raise ConfigurationError,
              'RESTIC_REPOSITORY or RESTIC_REPOSITORY_FILE is required to dump from the backup accessory'
      end
    end

    def raise_restic_accessory_error(spec, status, stderr, snapshot:, filename:, docker_argv: nil)
      redacted = @redactor.redact_string(stderr.to_s)
      message =
        if stderr.to_s.match?(/no matching ID found|failed to find snapshot|no snapshot found/i)
          "backup not found for snapshot #{snapshot.inspect}"
        elsif filename && stderr.to_s.match?(/path .+ not found|does not exist|no such file/i)
          "backup file #{filename.inspect} not found in snapshot #{snapshot.inspect}"
        else
          "command failed (#{status}): #{redacted_restic_command(spec, docker_argv)}\n#{redacted}"
        end

      raise CommandError.new(
        message,
        command: spec,
        status: status,
        stderr: redacted
      )
    end

    # Shell-escaping the live command hides query credentials from the redactor.
    # Redact the docker arguments first, then escape that copy for the error text.
    def redacted_restic_command(spec, docker_argv)
      return spec.display(@redactor) unless docker_argv

      prefix = spec.argv[0..-2].shelljoin
      remote = docker_argv.map { |arg| @redactor.redact_string(arg) }.shelljoin
      "#{prefix} #{remote}"
    end

    # Match Kamal's SSH defaults: user root, port 22, plus ssh.user, port, proxy,
    # keys, and config from the rendered deploy config.
    def ssh_argv(host, remote_command, identity_files:, config_file:)
      options = ssh_options
      argv = ['ssh', '-p', options.fetch(:port), '-l', options.fetch(:user)]
      argv.concat(ssh_proxy_args(options[:proxy]))
      Array(options[:keys]).each { |key| argv.concat(['-i', key]) }
      identity_files.each { |path| argv.concat(['-i', path]) }
      argv.concat(['-o', 'IdentitiesOnly=yes']) if options[:keys_only]
      argv.concat(['-F', '/dev/null']) if options[:config] == false
      argv.concat(['-F', config_file]) if config_file
      case options[:forward_agent]
      when true
        argv.concat(['-o', 'ForwardAgent=yes'])
      when false
        argv.concat(['-o', 'ForwardAgent=no'])
      end
      argv << host
      argv << remote_command
      argv
    end

    def ssh_options
      raw = fetch(config, :ssh_options) || {}
      {
        user: (ssh_config_value(raw, :user) || 'root').to_s,
        port: (ssh_config_value(raw, :port) || 22).to_s,
        proxy: ssh_config_value(raw, :proxy),
        keys: Array(ssh_config_value(raw, :keys)).map { |key| File.expand_path(key.to_s) },
        keys_only: ssh_config_value(raw, :keys_only),
        config: ssh_config_value(raw, :config),
        forward_agent: ssh_config_value(raw, :forward_agent),
        key_data: Array(ssh_config_value(raw, :key_data)).map(&:to_s).reject(&:empty?)
      }
    end

    def ssh_config_value(raw, key)
      [key, key.to_s, key.to_sym].each do |candidate|
        return raw[candidate] if raw.key?(candidate)
      end
      nil
    end

    def ssh_proxy_args(proxy)
      return [] if proxy.nil? || proxy == false

      if (jump = ssh_jump_target(proxy))
        jump = "root@#{jump}" unless jump.include?('@') || jump.include?(',')
        return ['-J', jump]
      end

      command = ssh_proxy_command(proxy)
      return [] if command.nil? || command.empty?

      ['-o', "ProxyCommand=#{command}"]
    end

    def ssh_jump_target(proxy)
      raw = if proxy.is_a?(String)
              proxy
            elsif proxy.respond_to?(:jump_proxies)
              proxy.jump_proxies
            elsif proxy.is_a?(Hash)
              fetch(proxy, :jump_proxies)
            end
      value = raw.to_s.strip
      return if value.empty? || value.include?(' ')

      value
    end

    def ssh_proxy_command(proxy)
      raw = if proxy.is_a?(String)
              proxy
            elsif proxy.respond_to?(:command_line_template) && !proxy.respond_to?(:jump_proxies)
              proxy.command_line_template
            elsif proxy.is_a?(Hash)
              fetch(proxy, :command_line_template) || fetch(proxy, :command)
            end
      value = raw.to_s.strip
      return if value.empty? || !value.include?(' ')

      value
    end

    def with_ssh_identity_files
      identity_files = []
      config_file = ssh_config_file
      ssh_options.fetch(:key_data).each do |data|
        file = Tempfile.new(['kamal-backup-ssh-', '.key'])
        file.chmod(0o600)
        file.write(data)
        file.close
        identity_files << file
      end
      yield identity_files.map(&:path), config_file&.path
    ensure
      (Array(identity_files) + [config_file]).compact.each do |file|
        file.close! if file.respond_to?(:close!)
      rescue StandardError
        nil
      end
    end

    def ssh_config_file
      paths = case ssh_options[:config]
              when String
                [ssh_options[:config]]
              when Array
                ssh_options[:config].map(&:to_s)
              else
                []
              end
      paths = paths.map { |path| File.expand_path(path) }.reject(&:empty?)
      return if paths.empty?

      file = Tempfile.new(['kamal-backup-ssh-config-', '.conf'])
      file.chmod(0o600)
      file.write(paths.map { |path| %(Include "#{path.gsub(/["\\]/) { |char| "\\#{char}" }}") }.join("\n"))
      file.write("\n")
      file.close
      file
    end

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
          raise ConfigurationError,
                "accessory #{accessory_name.inspect} is not defined in #{@config_file || DEFAULT_CONFIG_FILE}"
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
      target, source = entry.to_s.split(':', 2)
      [target, source || target]
    end

    def add_resolved_secret(env, target:, source:)
      if (value = resolved_secret(source))
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
        tokens.shift if tokens.first == 'export'

        tokens.each do |assignment|
          key, value = assignment.split('=', 2)
          next if key.to_s.empty? || value.nil?

          secrets[key] = value.to_s
        end
      end
    end

    def kamal_config_argv
      [
        *kamal_command,
        'config',
        *kamal_option_argv,
        '--version',
        'latest'
      ]
    end

    def kamal_exec_argv(accessory_name, command, interactive: false)
      [
        *kamal_command,
        'accessory',
        'exec',
        *kamal_option_argv,
        *(['--interactive'] if interactive),
        '--reuse',
        accessory_name,
        *kamal_remote_command_argv(command)
      ]
    end

    def kamal_secrets_print_argv
      [
        *kamal_command,
        'secrets',
        'print',
        *kamal_option_argv
      ]
    end

    def kamal_command
      if File.executable?(File.join(@cwd, 'bin', 'kamal'))
        ['bin/kamal']
      elsif File.file?(File.join(@cwd, 'Gemfile'))
        %w[bundle exec kamal]
      else
        ['kamal']
      end
    end

    def kamal_option_argv
      argv = []
      argv.concat(['-c', @config_file]) if @config_file
      argv.concat(['-d', @destination]) if @destination
      argv
    end

    def capture_kamal(argv, stream: false, log: !stream, stdout: @stdout, stderr: @stderr, pty: false)
      spec = CommandSpec.new(argv: argv, env: kamal_stream_env(stream))
      options = {
        redactor: @redactor,
        log: log,
        log_output: false,
        tee_stdout: stream ? stdout : nil,
        tee_stderr: stream ? stderr : nil
      }

      if defined?(Bundler)
        Bundler.with_unbundled_env { capture_command(spec, options, pty: pty) }
      else
        capture_command(spec, options, pty: pty)
      end
    end

    def capture_command(spec, options, pty:)
      if pty
        Command.capture_pty(spec, redactor: options.fetch(:redactor), tee_stdout: options[:tee_stdout])
      else
        Command.capture(spec, **options)
      end
    end

    def execute_on_accessory_live(accessory_name:, command_argv:, target:)
      @stdout.puts('Launching command from existing container...')

      spec = CommandSpec.new(
        argv: ['docker', 'exec', target.fetch(:service_name), *command_argv],
        host: target.fetch(:host)
      )
      context = Command.output&.command_start(spec, redactor: @redactor)

      result = capture_kamal(
        kamal_exec_argv(accessory_name, command_argv, interactive: true),
        stream: true,
        log: false,
        stdout: filtered_interactive_stdout,
        pty: true
      )
      Command.output&.command_exit(context, result.status) if context
      result
    rescue CommandError => e
      Command.output&.command_exit(context, e.status || 1) if context
      raise
    end

    def filtered_interactive_stdout
      FilteringIO.new(@stdout) do |output|
        stripped = output.to_s.gsub(/\e\[[0-9;]*m/, '').delete("\r").strip
        stripped == 'Launching interactive command via SSH from existing container...' ||
          stripped.match?(/\AConnection to .+ closed\.\z/)
      end
    end

    def live_accessory_target(accessory_name)
      accessory_config = accessory(accessory_name)
      host = single_accessory_host(accessory_config)
      service_name = fetch(accessory_config, :service) || default_accessory_service_name(accessory_name)

      { host: host, service_name: service_name } if host && service_name
    rescue ConfigurationError, KeyError, NoMethodError, TypeError
      nil
    end

    def single_accessory_host(accessory_config)
      hosts = if (host = fetch(accessory_config, :host))
                normalized_hosts(host)
              else
                normalized_hosts(fetch(accessory_config, :hosts))
              end

      return hosts.first if hosts.size == 1
      return if hosts.any?

      all_hosts = normalized_hosts(fetch(config, :hosts))
      all_hosts.first if all_hosts.size == 1
    end

    def normalized_hosts(value)
      case value
      when nil
        []
      when Array
        value.map(&:to_s).reject(&:empty?)
      else
        [value.to_s].reject(&:empty?)
      end
    end

    def default_accessory_service_name(accessory_name)
      service = fetch(config, :service).to_s
      service = service_from_rendered_config if service.empty?
      "#{service}-#{accessory_name}" unless service.empty?
    end

    def service_from_rendered_config
      service_with_version = fetch(config, :service_with_version).to_s
      version = fetch(config, :version).to_s
      suffix = "-#{version}"

      return unless !service_with_version.empty? && !version.empty? && service_with_version.end_with?(suffix)

      service_with_version.delete_suffix(suffix)
    end

    def kamal_stream_env(stream)
      return {} unless stream

      if @env['SSHKIT_COLOR'].to_s.empty?
        stream_color? ? { 'SSHKIT_COLOR' => '1' } : {}
      else
        { 'SSHKIT_COLOR' => @env['SSHKIT_COLOR'] }
      end
    end

    def stream_color?
      [@stdout, @stderr].any? { |io| io.respond_to?(:tty?) && io.tty? }
    end

    def remote_command_argv(command)
      argv = command.is_a?(String) ? Shellwords.split(command) : Array(command).compact.map(&:to_s)
      raise ArgumentError, 'remote command cannot be empty' if argv.empty?

      argv
    end

    def kamal_remote_command_argv(command)
      remote_command_argv(command).map { |arg| Shellwords.escape(arg) }
    end

    def parse_version_line(output)
      output.to_s.lines.map(&:strip).reverse.find { |line| line.match?(VERSION_LINE_PATTERN) }.to_s
    end
  end
end
