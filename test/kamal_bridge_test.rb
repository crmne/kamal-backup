# frozen_string_literal: true

require_relative 'test_helper'
require 'stringio'

class KamalBridgeTest < Minitest::Test
  TTYStringIO = Class.new(StringIO) do
    def tty?
      true
    end
  end

  def stub_command_capture(result)
    original = KamalBackup::Command.method(:capture)
    specs = []

    KamalBackup::Command.define_singleton_method(:capture) do |spec, **_kwargs|
      specs << spec
      result.respond_to?(:call) ? result.call(spec) : result
    end

    yield(specs)
  ensure
    KamalBackup::Command.define_singleton_method(:capture) { |*args, **kwargs, &block| original.call(*args, **kwargs, &block) }
  end

  def test_remote_version_uses_the_version_line_from_kamal_output
    output = <<~OUT
      Launching command from new container...
        INFO [50d63bd8] Running docker run ghcr.io/crmne/kamal-backup:latest kamal-backup version on example.com
      App Host: example.com
      0.1.2
    OUT
    Dir.mktmpdir do |dir|
      bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}), cwd: dir)

      stub_command_capture(KamalBackup::CommandResult.new(stdout: output, stderr: '', status: 0)) do |specs|
        assert_equal '0.1.2', bridge.remote_version(accessory_name: 'backup')
        assert_equal ['kamal', 'accessory', 'exec', '--reuse', 'backup', 'kamal-backup', 'version'], specs.first.argv
      end
    end
  end

  def test_accessory_exec_places_kamal_options_before_remote_command
    output = <<~OUT
      App Host: example.com
      0.2.5
    OUT
    Dir.mktmpdir do |dir|
      bridge = KamalBackup::KamalBridge.new(
        redactor: KamalBackup::Redactor.new(env: {}),
        config_file: 'config/deploy.yml',
        destination: 'production',
        cwd: dir
      )

      stub_command_capture(KamalBackup::CommandResult.new(stdout: output, stderr: '', status: 0)) do |specs|
        assert_equal '0.2.5', bridge.remote_version(accessory_name: 'backup')
        assert_equal [
          'kamal',
          'accessory',
          'exec',
          '-c',
          'config/deploy.yml',
          '-d',
          'production',
          '--reuse',
          'backup',
          'kamal-backup',
          'version'
        ], specs.first.argv
      end
    end
  end

  def test_remote_version_logs_kamal_probe_commands
    original = KamalBackup::Command.method(:capture)
    calls = []

    KamalBackup::Command.define_singleton_method(:capture) do |spec, **kwargs|
      calls << { spec: spec, kwargs: kwargs }
      KamalBackup::CommandResult.new(stdout: "0.2.5\n", stderr: '', status: 0)
    end

    Dir.mktmpdir do |dir|
      bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}), cwd: dir)

      assert_equal '0.2.5', bridge.remote_version(accessory_name: 'backup')
      assert_equal ['kamal', 'accessory', 'exec', '--reuse', 'backup', 'kamal-backup', 'version'],
                   calls.first.fetch(:spec).argv
      assert_equal true, calls.first.fetch(:kwargs).fetch(:log)
      assert_equal false, calls.first.fetch(:kwargs).fetch(:log_output)
    end
  ensure
    KamalBackup::Command.define_singleton_method(:capture) { |*args, **kwargs, &block| original.call(*args, **kwargs, &block) }
  end

  def test_execute_on_accessory_can_stream_kamal_output
    original = KamalBackup::Command.method(:capture)
    calls = []
    out = StringIO.new
    err = StringIO.new
    redactor = KamalBackup::Redactor.new(env: {})
    output = KamalBackup::CommandOutput.new(io: StringIO.new)

    KamalBackup::Command.define_singleton_method(:capture) do |spec, **kwargs|
      calls << { spec: spec, kwargs: kwargs }
      if kwargs[:tee_stdout]
        kwargs.fetch(:tee_stdout).print("kamal stdout\n")
        kwargs.fetch(:tee_stderr).print("kamal stderr\n")
      end
      KamalBackup::CommandResult.new(stdout: "kamal stdout\n", stderr: "kamal stderr\n", status: 0, streamed: true)
    end

    Dir.mktmpdir do |dir|
      bridge = KamalBackup::KamalBridge.new(
        redactor: redactor,
        stdout: out,
        stderr: err,
        cwd: dir
      )

      result = KamalBackup::Command.with_output(output) do
        bridge.execute_on_accessory(accessory_name: 'backup', command: 'kamal-backup backup --force', stream: true)
      end

      exec_call = calls.find { |call| call.fetch(:spec).argv.include?('exec') }

      assert result.streamed
      assert_equal "kamal stdout\n", out.string
      assert_equal "kamal stderr\n", err.string
      assert_equal ['kamal', 'accessory', 'exec', '--reuse', 'backup', 'kamal-backup', 'backup', '--force'],
                   exec_call.fetch(:spec).argv
      assert_equal false, exec_call.fetch(:kwargs).fetch(:log)
      assert_equal false, exec_call.fetch(:kwargs).fetch(:log_output)
      assert_same out, exec_call.fetch(:kwargs).fetch(:tee_stdout)
      assert_same err, exec_call.fetch(:kwargs).fetch(:tee_stderr)
    end
  ensure
    KamalBackup::Command.define_singleton_method(:capture) { |*args, **kwargs, &block| original.call(*args, **kwargs, &block) }
  end

  def test_accessory_exec_preserves_remote_arguments_with_spaces
    Dir.mktmpdir do |dir|
      bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}), cwd: dir)

      stub_command_capture(KamalBackup::CommandResult.new(stdout: "ok\n", stderr: '', status: 0)) do |specs|
        bridge.execute_on_accessory(
          accessory_name: 'backup',
          command: ['kamal-backup', 'drill', 'production', 'latest', '--check', 'printf verified']
        )

        assert_equal [
          'kamal',
          'accessory',
          'exec',
          '--reuse',
          'backup',
          'kamal-backup',
          'drill',
          'production',
          'latest',
          '--check',
          'printf\ verified'
        ], specs.first.argv
      end
    end
  end

  def test_streamed_accessory_exec_forces_sshkit_color_when_output_is_tty
    original = KamalBackup::Command.method(:capture)
    calls = []

    KamalBackup::Command.define_singleton_method(:capture) do |spec, **kwargs|
      calls << { spec: spec, kwargs: kwargs }
      KamalBackup::CommandResult.new(stdout: '', stderr: '', status: 0, streamed: true)
    end

    Dir.mktmpdir do |dir|
      bridge = KamalBackup::KamalBridge.new(
        redactor: KamalBackup::Redactor.new(env: {}),
        stdout: TTYStringIO.new,
        stderr: StringIO.new,
        cwd: dir
      )

      bridge.execute_on_accessory(accessory_name: 'backup', command: 'kamal-backup list', stream: true)

      exec_call = calls.find { |call| call.fetch(:spec).argv.include?('exec') }

      assert_equal '1', exec_call.fetch(:spec).env.fetch('SSHKIT_COLOR')
      assert_equal false, exec_call.fetch(:kwargs).fetch(:log)
    end
  ensure
    KamalBackup::Command.define_singleton_method(:capture) { |*args, **kwargs, &block| original.call(*args, **kwargs, &block) }
  end

  def test_streamed_accessory_exec_uses_live_single_host_command
    original = KamalBackup::Command.method(:capture)
    original_pty = KamalBackup::Command.method(:capture_pty)
    calls = []
    out = StringIO.new
    err = StringIO.new
    command_log = StringIO.new
    config_output = <<~YAML
      hosts:
        - example.com
      version: latest
      service_with_version: demo-latest
      accessories:
        backup:
          image: ghcr.io/crmne/kamal-backup:latest
          role: web
    YAML

    KamalBackup::Command.define_singleton_method(:capture) do |spec, **kwargs|
      calls << { spec: spec, kwargs: kwargs }

      case spec.argv
      when ['kamal', 'config', '--version', 'latest']
        KamalBackup::CommandResult.new(stdout: config_output, stderr: '', status: 0)
      else
        raise "unexpected command: #{spec.argv.inspect}"
      end
    end

    KamalBackup::Command.define_singleton_method(:capture_pty) do |spec, **kwargs|
      calls << { spec: spec, kwargs: kwargs, pty: true }
      kwargs.fetch(:tee_stdout).print("\e[0;35;49mLaunching interactive command via SSH from existing container...\e[0m\r\n")
      kwargs.fetch(:tee_stdout).print("App Host: example.com\n")
      kwargs.fetch(:tee_stdout).print("Connection to example.com closed.\r\n")
      stdout = "\e[0;35;49mLaunching interactive command via SSH from existing container...\e[0m\r\n" \
               "App Host: example.com\n" \
               "Connection to example.com closed.\r\n"
      KamalBackup::CommandResult.new(
        stdout: stdout,
        stderr: '',
        status: 0,
        streamed: true
      )
    end

    Dir.mktmpdir do |dir|
      bridge = KamalBackup::KamalBridge.new(
        redactor: KamalBackup::Redactor.new(env: {}),
        stdout: out,
        stderr: err,
        cwd: dir
      )

      assert_equal 'backup', bridge.accessory_name(preferred: 'backup')

      result = KamalBackup::Command.with_output(KamalBackup::CommandOutput.new(io: command_log)) do
        bridge.execute_on_accessory(accessory_name: 'backup', command: 'kamal-backup backup', stream: true)
      end

      assert result.streamed
      assert_equal "Launching command from existing container...\nApp Host: example.com\n", out.string
      refute_includes out.string, 'Connection to'
      assert_empty err.string
      assert_includes command_log.string, 'Running docker exec demo-backup kamal-backup backup on example.com'
      assert_includes command_log.string, 'Finished in'

      exec_call = calls.find { |call| call[:pty] }
      assert exec_call.fetch(:kwargs).fetch(:tee_stdout)
      assert_equal ['kamal', 'accessory', 'exec', '--interactive', '--reuse', 'backup', 'kamal-backup', 'backup'],
                   exec_call.fetch(:spec).argv
    end
  ensure
    KamalBackup::Command.define_singleton_method(:capture) { |*args, **kwargs, &block| original.call(*args, **kwargs, &block) }
    KamalBackup::Command.define_singleton_method(:capture_pty) { |*args, **kwargs, &block| original_pty.call(*args, **kwargs, &block) }
  end

  def test_accessory_environment_merges_clear_env_and_resolved_secrets
    config_output = <<~YAML
      accessories:
        backup:
          env:
            clear:
              APP_NAME: chatwithwork
              RESTIC_REPOSITORY_FILE: /var/lib/kamal-backup/restic-repository
            secret:
              - RESTIC_PASSWORD
              - AWS_ACCESS_KEY_ID
              - PGPASSWORD:POSTGRES_PASSWORD
    YAML
    secret_output = <<~SECRETS
      RESTIC_PASSWORD=secret
      AWS_ACCESS_KEY_ID=key
      POSTGRES_PASSWORD=postgres-secret
    SECRETS
    Dir.mktmpdir do |dir|
      bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}), cwd: dir)

      stub_command_capture(proc do |spec|
        case spec.argv
        when ['kamal', 'config', '--version', 'latest']
          KamalBackup::CommandResult.new(stdout: config_output, stderr: '', status: 0)
        when %w[kamal secrets print]
          KamalBackup::CommandResult.new(stdout: secret_output, stderr: '', status: 0)
        else
          raise "unexpected command: #{spec.argv.inspect}"
        end
      end) do
        env = bridge.accessory_environment(accessory_name: 'backup')

        assert_equal 'chatwithwork', env.fetch('APP_NAME')
        assert_equal '/var/lib/kamal-backup/restic-repository', env.fetch('RESTIC_REPOSITORY_FILE')
        assert_equal 'secret', env.fetch('RESTIC_PASSWORD')
        assert_equal 'key', env.fetch('AWS_ACCESS_KEY_ID')
        assert_equal 'postgres-secret', env.fetch('PGPASSWORD')
      end
    end
  end

  def test_accessory_environment_parses_exported_secret_output
    config_output = <<~YAML
      accessories:
        backup:
          env:
            secret:
              - RESTIC_REPOSITORY
              - RESTIC_PASSWORD
    YAML
    secret_output = <<~SECRETS
      export RESTIC_REPOSITORY=s3:https://s3.example.com/app-backups
      export RESTIC_PASSWORD='secret with spaces'
    SECRETS
    Dir.mktmpdir do |dir|
      bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}), cwd: dir)

      stub_command_capture(proc do |spec|
        case spec.argv
        when ['kamal', 'config', '--version', 'latest']
          KamalBackup::CommandResult.new(stdout: config_output, stderr: '', status: 0)
        when %w[kamal secrets print]
          KamalBackup::CommandResult.new(stdout: secret_output, stderr: '', status: 0)
        else
          raise "unexpected command: #{spec.argv.inspect}"
        end
      end) do
        env = bridge.accessory_environment(accessory_name: 'backup')

        assert_equal 's3:https://s3.example.com/app-backups', env.fetch('RESTIC_REPOSITORY')
        assert_equal 'secret with spaces', env.fetch('RESTIC_PASSWORD')
      end
    end
  end

  def test_accessory_environment_omits_empty_resolved_secrets
    config_output = <<~YAML
      accessories:
        backup:
          env:
            secret:
              - RESTIC_PASSWORD
    YAML
    secret_output = "RESTIC_PASSWORD=\n"
    Dir.mktmpdir do |dir|
      bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}), cwd: dir)

      stub_command_capture(proc do |spec|
        case spec.argv
        when ['kamal', 'config', '--version', 'latest']
          KamalBackup::CommandResult.new(stdout: config_output, stderr: '', status: 0)
        when %w[kamal secrets print]
          KamalBackup::CommandResult.new(stdout: secret_output, stderr: '', status: 0)
        else
          raise "unexpected command: #{spec.argv.inspect}"
        end
      end) do
        env = bridge.accessory_environment(accessory_name: 'backup')

        refute env.key?('RESTIC_PASSWORD')
      end
    end
  end

  def test_kamal_command_prefers_project_binstub
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'bin'))
      binstub = File.join(dir, 'bin', 'kamal')
      File.write(binstub, "#!/bin/sh\n")
      FileUtils.chmod('+x', binstub)

      bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}), cwd: dir)

      stub_command_capture(KamalBackup::CommandResult.new(stdout: "0.2.2\n", stderr: '', status: 0)) do |specs|
        assert_equal '0.2.2', bridge.remote_version(accessory_name: 'backup')
        assert_equal ['bin/kamal', 'accessory', 'exec', '--reuse', 'backup', 'kamal-backup', 'version'],
                     specs.first.argv
      end
    end
  end

  def test_kamal_command_uses_bundle_exec_when_only_gemfile_exists
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Gemfile'), "source \"https://rubygems.org\"\n")

      bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}), cwd: dir)

      stub_command_capture(KamalBackup::CommandResult.new(stdout: "0.2.2\n", stderr: '', status: 0)) do |specs|
        assert_equal '0.2.2', bridge.remote_version(accessory_name: 'backup')
        assert_equal ['bundle', 'exec', 'kamal', 'accessory', 'exec', '--reuse', 'backup', 'kamal-backup', 'version'],
                     specs.first.argv
      end
    end
  end

  def with_kamal_config(config_yaml, secrets_output: '', env: {})
    Dir.mktmpdir do |dir|
      bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}), cwd: dir, env: env)
      responder = lambda do |spec|
        stdout = spec.argv.include?('secrets') ? secrets_output : config_yaml
        KamalBackup::CommandResult.new(stdout: stdout, stderr: '', status: 0)
      end

      stub_command_capture(responder) { yield bridge }
    end
  end

  def test_accessory_name_infers_the_accessory_from_the_image
    config_yaml = <<~YAML
      accessories:
        db_backup:
          image: ghcr.io/crmne/kamal-backup:latest
        redis:
          image: redis:7
    YAML

    with_kamal_config(config_yaml) do |bridge|
      assert_equal 'db_backup', bridge.accessory_name
    end
  end

  def test_accessory_name_falls_back_to_the_backup_accessory
    config_yaml = <<~YAML
      accessories:
        backup:
          image: example/custom-image:latest
        redis:
          image: redis:7
    YAML

    with_kamal_config(config_yaml) do |bridge|
      assert_equal 'backup', bridge.accessory_name
    end
  end

  def test_accessory_name_raises_when_it_cannot_be_inferred
    config_yaml = <<~YAML
      accessories:
        redis:
          image: redis:7
        search:
          image: elastic:8
    YAML

    with_kamal_config(config_yaml) do |bridge|
      error = assert_raises(KamalBackup::ConfigurationError) { bridge.accessory_name }
      assert_includes error.message, 'redis, search'
    end
  end

  def test_accessory_name_prefers_the_requested_accessory
    config_yaml = <<~YAML
      accessories:
        custom:
          image: example/custom-image:latest
    YAML

    with_kamal_config(config_yaml) do |bridge|
      assert_equal 'custom', bridge.accessory_name(preferred: 'custom')
    end
  end

  def test_accessory_name_raises_when_the_requested_accessory_is_missing
    config_yaml = <<~YAML
      accessories:
        backup:
          image: ghcr.io/crmne/kamal-backup:latest
    YAML

    with_kamal_config(config_yaml) do |bridge|
      error = assert_raises(KamalBackup::ConfigurationError) { bridge.accessory_name(preferred: 'missing') }
      assert_includes error.message, '"missing" is not defined'
    end
  end

  def test_local_restore_defaults_come_from_the_accessory_clear_env
    config_yaml = <<~YAML
      accessories:
        backup:
          image: ghcr.io/crmne/kamal-backup:latest
          env:
            clear:
              APP_NAME: demo
              DATABASE_ADAPTER: sqlite
              RESTIC_REPOSITORY: /repo
              BACKUP_PATHS: /data/storage
    YAML

    with_kamal_config(config_yaml) do |bridge|
      assert_equal(
        {
          'APP_NAME' => 'demo',
          'DATABASE_ADAPTER' => 'sqlite',
          'RESTIC_REPOSITORY' => '/repo',
          'LOCAL_RESTORE_SOURCE_PATHS' => '/data/storage'
        },
        bridge.local_restore_defaults(accessory_name: 'backup')
      )
    end
  end

  def test_accessory_environment_resolves_secret_list_entries
    config_yaml = <<~YAML
      accessories:
        backup:
          image: ghcr.io/crmne/kamal-backup:latest
          env:
            clear:
              APP_NAME: demo
            secret:
              - RESTIC_PASSWORD
              - DB_PASSWORD:MY_DB_SECRET
    YAML

    with_kamal_config(
      config_yaml,
      secrets_output: "RESTIC_PASSWORD=from-secrets\n",
      env: { 'MY_DB_SECRET' => 'from-process-env' }
    ) do |bridge|
      environment = bridge.accessory_environment(accessory_name: 'backup')

      assert_equal 'demo', environment.fetch('APP_NAME')
      assert_equal 'from-secrets', environment.fetch('RESTIC_PASSWORD')
      assert_equal 'from-process-env', environment.fetch('DB_PASSWORD')
    end
  end

  def test_accessory_environment_resolves_secret_hash_entries
    config_yaml = <<~YAML
      accessories:
        backup:
          image: ghcr.io/crmne/kamal-backup:latest
          env:
            secret:
              RESTIC_PASSWORD: MY_RESTIC_SECRET
    YAML

    with_kamal_config(config_yaml, secrets_output: "MY_RESTIC_SECRET=resolved\n") do |bridge|
      environment = bridge.accessory_environment(accessory_name: 'backup')

      assert_equal 'resolved', environment.fetch('RESTIC_PASSWORD')
    end
  end

  def test_accessory_environment_skips_unresolvable_secrets
    config_yaml = <<~YAML
      accessories:
        backup:
          image: ghcr.io/crmne/kamal-backup:latest
          env:
            secret:
              - MISSING_SECRET
    YAML

    with_kamal_config(config_yaml) do |bridge|
      assert_empty bridge.accessory_environment(accessory_name: 'backup')
    end
  end

  def test_raise_restic_accessory_error_reports_a_missing_snapshot
    bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}))
    spec = KamalBackup::CommandSpec.new(argv: %w[ssh example.com restic])

    error = assert_raises(KamalBackup::CommandError) do
      bridge.send(
        :raise_restic_accessory_error,
        spec,
        1,
        'Fatal: failed to find snapshot: no matching ID found for prefix "does-not-exist"',
        snapshot: 'does-not-exist',
        filename: '/databases/demo/app/postgres.pgdump'
      )
    end

    assert_equal 'backup not found for snapshot "does-not-exist"', error.message
    assert_equal 1, error.status
  end

  def test_raise_restic_accessory_error_reports_a_missing_backup_file
    bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}))
    spec = KamalBackup::CommandSpec.new(argv: %w[ssh example.com restic])

    error = assert_raises(KamalBackup::CommandError) do
      bridge.send(
        :raise_restic_accessory_error,
        spec,
        1,
        'path /databases/demo/app/postgres.pgdump not found in the repository',
        snapshot: 'latest',
        filename: '/databases/demo/app/postgres.pgdump'
      )
    end

    assert_equal(
      'backup file "/databases/demo/app/postgres.pgdump" not found in snapshot "latest"',
      error.message
    )
  end

  def test_capture_restic_command_returns_stdout
    Dir.mktmpdir do |outer|
      args_file = File.join(outer, 'ssh-args')
      with_fake_ssh(<<~SCRIPT) do
        #!/bin/sh
        printf '%s\\n' "$@" > #{args_file}
        printf '[{"id":"abc"}]'
      SCRIPT
        Dir.mktmpdir do |dir|
          bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}), cwd: dir)
          bridge.instance_variable_set(
            :@config,
            {
              'service' => 'demo',
              'accessories' => {
                'backup' => {
                  'host' => 'example.com',
                  'service' => 'demo-backup'
                }
              }
            }
          )

          output = bridge.capture_restic_command(
            accessory_name: 'backup',
            repository: '/var/lib/restic-repo',
            argv: ['snapshots', '--json']
          )

          assert_equal '[{"id":"abc"}]', output
          assert_includes File.read(args_file).split("\n"), '-T'
        end
      end
    end
  end

  def test_stream_restic_dump_requires_a_live_accessory
    Dir.mktmpdir do |dir|
      bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}), cwd: dir)
      bridge.define_singleton_method(:config) { { 'accessories' => {} } }

      error = assert_raises(KamalBackup::ConfigurationError) do
        bridge.stream_restic_dump(
          accessory_name: 'backup',
          repository: '/var/lib/restic-repo',
          snapshot: 'latest',
          filename: '/databases/demo/app/postgres.pgdump',
          io: StringIO.new
        )
      end

      assert_includes error.message, 'could not find a live backup accessory "backup"'
    end
  end

  def test_stream_restic_dump_uses_kamal_ssh_user_port_proxy_and_key
    args_file = nil
    Dir.mktmpdir do |outer|
      args_file = File.join(outer, 'ssh-args')
      key_path = File.join(outer, 'id_ed25519')
      File.write(key_path, 'key-file')
      config_path = File.join(outer, 'ssh_config')
      File.write(config_path, "User from-file\n")

      with_fake_ssh(<<~SCRIPT) do
        #!/bin/sh
        printf '%s\\n' "$@" > #{args_file}
        prev=
        identity=
        config=
        for arg in "$@"; do
          if [ "$prev" = "-i" ]; then identity=$arg; fi
          if [ "$prev" = "-F" ]; then config=$arg; fi
          prev=$arg
        done
        grep -q 'BEGIN OPENSSH PRIVATE KEY' "$identity" || exit 1
        grep -q '#{config_path}' "$config" || exit 1
        printf dump-bytes
      SCRIPT
        Dir.mktmpdir do |dir|
          bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}), cwd: dir)
          bridge.instance_variable_set(
            :@config,
            {
              'service' => 'demo',
              'ssh_options' => {
                'user' => 'app',
                'port' => 2222,
                'proxy' => { 'jump_proxies' => 'root@bastion' },
                'keys' => [key_path],
                'keys_only' => true,
                'config' => config_path,
                'forward_agent' => false,
                'key_data' => ["-----BEGIN OPENSSH PRIVATE KEY-----\nsecret\n"]
              },
              'accessories' => {
                'backup' => {
                  'host' => 'example.com',
                  'service' => 'demo-backup'
                }
              }
            }
          )

          bridge.stream_restic_dump(
            accessory_name: 'backup',
            repository: '/var/lib/restic-repo',
            snapshot: 'latest',
            filename: '/databases/demo/app/postgres.pgdump',
            io: StringIO.new
          )
        end
      end

      args = File.read(args_file).split("\n")
      assert_equal '2222', args[args.index('-p') + 1]
      assert_equal 'app', args[args.index('-l') + 1]
      assert_equal 'root@bastion', args[args.index('-J') + 1]
      assert_equal key_path, args[args.index('-i') + 1]
      refute_equal key_path, args[args.rindex('-i') + 1]
      refute_includes args.join("\n"), 'BEGIN OPENSSH PRIVATE KEY'
      assert_includes args, 'IdentitiesOnly=yes'
      assert_includes args, 'ForwardAgent=no'
      assert_includes args, '-F'
      assert_equal 'example.com', args[-2]
    end
  end

  def test_raise_restic_accessory_error_reports_other_command_failures
    bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}))
    spec = KamalBackup::CommandSpec.new(argv: %w[ssh example.com restic])

    error = assert_raises(KamalBackup::CommandError) do
      bridge.send(
        :raise_restic_accessory_error,
        spec,
        1,
        'permission denied',
        snapshot: 'abc',
        filename: '/databases/demo/app/postgres.pgdump'
      )
    end

    assert_includes error.message, 'command failed (1)'
    assert_includes error.message, 'permission denied'
  end

  def test_ssh_proxy_args_cover_jump_hosts_and_proxy_commands
    bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}))
    jump = Struct.new(:jump_proxies).new('bastion')
    command = Struct.new(:command_line_template).new('ssh -W %h:%p user@proxy')

    assert_equal ['-J', 'root@bastion'], bridge.send(:ssh_proxy_args, jump)
    assert_equal ['-J', 'root@host'], bridge.send(:ssh_proxy_args, 'host')
    assert_equal [], bridge.send(:ssh_proxy_args, command)
    assert_equal [], bridge.send(:ssh_proxy_args, 'ssh -W %h:%p user@proxy')
    assert_equal [], bridge.send(:ssh_proxy_args, { 'command' => 'ssh -W %h:%p jump' })
    assert_equal [], bridge.send(:ssh_proxy_args, { 'command' => '/usr/local/bin/tunnel-wrapper' })
    assert_equal 'ssh -W %h:%p user@proxy', bridge.send(:ssh_proxy_command, command)
    assert_equal 'ssh -W %h:%p user@proxy', bridge.send(:ssh_proxy_command, 'ssh -W %h:%p user@proxy')
    assert_equal '/usr/local/bin/tunnel-wrapper', bridge.send(:ssh_proxy_command, { 'command' => '/usr/local/bin/tunnel-wrapper' })
    assert_nil bridge.send(:ssh_proxy_command, '   ')
    assert_nil bridge.send(:ssh_proxy_command, { 'command' => '' })
    assert_nil bridge.send(:ssh_proxy_command, { 'command' => '   ' })
  end

  def test_ssh_argv_enables_agent_forwarding_and_multiple_config_files
    Dir.mktmpdir do |dir|
      first = File.join(dir, 'first')
      second = File.join(dir, 'second')
      File.write(first, "User one\n")
      File.write(second, "User two\n")
      bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}), cwd: dir)
      bridge.instance_variable_set(
        :@config,
        { 'ssh_options' => { 'forward_agent' => true, 'config' => [first, second] } }
      )

      config_file = bridge.send(:ssh_config_file)
      argv = bridge.send(:ssh_argv, 'example.com', 'true', identity_files: [], config_file: config_file.path)

      assert_includes argv, 'ForwardAgent=yes'
      assert_includes File.read(config_file.path), first
      assert_includes File.read(config_file.path), second
    ensure
      config_file&.close!
    end
  end

  def test_ssh_identity_cleanup_ignores_close_errors
    bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}))
    bridge.instance_variable_set(:@config, { 'ssh_options' => { 'key_data' => ['secret-key'] } })
    file = Tempfile.new('kamal-backup-ssh-test')
    file.define_singleton_method(:close!) { raise StandardError, 'busy' }

    Tempfile.stub(:new, file) do
      bridge.send(:with_ssh_identity_files) { |_paths, _config| nil }
    end
  ensure
    file&.close
    file&.unlink
  end

  def test_stream_restic_dump_defaults_to_kamal_ssh_user_and_port
    Dir.mktmpdir do |outer|
      args_file = File.join(outer, 'ssh-args')
      with_fake_ssh(<<~SCRIPT) do
        #!/bin/sh
        printf '%s\\n' "$@" > #{args_file}
        printf dump-bytes
      SCRIPT
        Dir.mktmpdir do |dir|
          bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}), cwd: dir)
          bridge.instance_variable_set(
            :@config,
            {
              'service' => 'demo',
              'accessories' => {
                'backup' => {
                  'host' => 'example.com',
                  'service' => 'demo-backup'
                }
              }
            }
          )

          bridge.stream_restic_dump(
            accessory_name: 'backup',
            repository: '/var/lib/restic-repo',
            snapshot: 'latest',
            filename: '/databases/demo/app/postgres.pgdump',
            io: StringIO.new
          )
        end
      end

      args = File.read(args_file).split("\n")
      assert_includes args, '-T'
      assert_equal '22', args[args.index('-p') + 1]
      assert_equal 'root', args[args.index('-l') + 1]
    end
  end

  def test_stream_restic_dump_streams_binary_output_over_ssh
    with_fake_ssh("#!/bin/sh\nshift\nprintf dump-bytes\n") do
      Dir.mktmpdir do |dir|
        bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}), cwd: dir)
        bridge.instance_variable_set(
          :@config,
          {
            'service' => 'demo',
            'accessories' => {
              'backup' => {
                'host' => 'example.com',
                'service' => 'demo-backup'
              }
            }
          }
        )
        io = StringIO.new

        result = bridge.stream_restic_dump(
          accessory_name: 'backup',
          repository: '/var/lib/restic-repo',
          snapshot: 'latest',
          filename: '/databases/demo/app/postgres.pgdump',
          io: io
        )

        assert_equal true, result
        assert_equal 'dump-bytes', io.string
      end
    end
  end

  def test_stream_restic_dump_maps_missing_snapshot_errors
    with_fake_ssh(<<~SCRIPT) do
      #!/bin/sh
      shift
      echo 'Fatal: failed to find snapshot: no matching ID found for prefix "does-not-exist"' >&2
      exit 1
    SCRIPT
      Dir.mktmpdir do |dir|
        bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}), cwd: dir)
        bridge.instance_variable_set(
          :@config,
          {
            'service' => 'demo',
            'accessories' => {
              'backup' => {
                'host' => 'example.com',
                'service' => 'demo-backup'
              }
            }
          }
        )

        error = assert_raises(KamalBackup::CommandError) do
          bridge.stream_restic_dump(
            accessory_name: 'backup',
            repository: '/var/lib/restic-repo',
            snapshot: 'does-not-exist',
            filename: '/databases/demo/app/postgres.pgdump',
            io: StringIO.new
          )
        end

        assert_equal 'backup not found for snapshot "does-not-exist"', error.message
      end
    end
  end

  def test_accessory_restic_keeps_repository_query_credentials_off_the_ssh_command
    Dir.mktmpdir do |outer|
      args_file = File.join(outer, 'ssh-args')
      repository = 's3:https://s3.example.com/bucket?access_key_id=AKIAEXAMPLE&secret_access_key=s3cretvalue'
      error = nil

      with_fake_ssh(<<~SCRIPT) do
        #!/bin/sh
        printf '%s\\n' "$@" > #{args_file}
        echo 'Fatal: unable to open repository at s3:https://s3.example.com/bucket?access_key_id=AKIAEXAMPLE&secret_access_key=s3cretvalue' >&2
        exit 1
      SCRIPT
        Dir.mktmpdir do |dir|
          bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}), cwd: dir)
          bridge.instance_variable_set(
            :@config,
            {
              'service' => 'demo',
              'accessories' => {
                'backup' => {
                  'host' => 'example.com',
                  'service' => 'demo-backup'
                }
              }
            }
          )

          error = assert_raises(KamalBackup::CommandError) do
            bridge.stream_restic_dump(
              accessory_name: 'backup',
              repository: repository,
              snapshot: 'latest',
              filename: '/databases/demo/app/postgres.pgdump',
              io: StringIO.new
            )
          end
        end
      end

      args = File.read(args_file)
      refute_includes args, 'AKIAEXAMPLE'
      refute_includes args, 's3cretvalue'
      refute_includes args, 'RESTIC_REPOSITORY='
      refute_includes error.command.argv.join("\n"), 'AKIAEXAMPLE'
      refute_includes error.command.argv.join("\n"), 's3cretvalue'
      assert_includes error.message, '[REDACTED]'
      refute_includes error.message, 'AKIAEXAMPLE'
      refute_includes error.message, 's3cretvalue'
    end
  end

  def test_capture_restic_command_keeps_listing_errors_generic
    with_fake_ssh(<<~SCRIPT) do
      #!/bin/sh
      echo 'open /run/secrets/restic-repository: no such file or directory' >&2
      exit 1
    SCRIPT
      Dir.mktmpdir do |dir|
        bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}), cwd: dir)
        bridge.instance_variable_set(
          :@config,
          {
            'service' => 'demo',
            'accessories' => {
              'backup' => {
                'host' => 'example.com',
                'service' => 'demo-backup'
              }
            }
          }
        )

        error = assert_raises(KamalBackup::CommandError) do
          bridge.capture_restic_command(
            accessory_name: 'backup',
            repository_file: '/run/secrets/restic-repository',
            argv: ['snapshots', '--json', '--tag', 'app:demo']
          )
        end

        assert_includes error.message, 'command failed (1)'
        assert_includes error.message, 'no such file or directory'
        refute_includes error.message, 'backup file "--tag"'
        refute_includes error.message, 'backup not found for snapshot "--json"'
      end
    end
  end

  def test_capture_restic_command_keeps_missing_snapshot_listing_errors_generic
    with_fake_ssh(<<~SCRIPT) do
      #!/bin/sh
      echo 'Fatal: failed to find snapshot: no matching ID found for prefix "abcdef"' >&2
      exit 1
    SCRIPT
      Dir.mktmpdir do |dir|
        bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}), cwd: dir)
        bridge.instance_variable_set(
          :@config,
          {
            'service' => 'demo',
            'accessories' => {
              'backup' => {
                'host' => 'example.com',
                'service' => 'demo-backup'
              }
            }
          }
        )

        error = assert_raises(KamalBackup::CommandError) do
          bridge.capture_restic_command(
            accessory_name: 'backup',
            repository: '/var/lib/restic-repo',
            argv: ['ls', '--json', 'abcdef']
          )
        end

        assert_includes error.message, 'command failed (1)'
        refute_includes error.message, 'backup not found for snapshot "--json"'
        refute_includes error.message, 'backup not found for snapshot "abcdef"'
      end
    end
  end

  def test_stream_restic_dump_passes_repository_file_to_the_accessory
    Dir.mktmpdir do |outer|
      args_file = File.join(outer, 'ssh-args')

      with_fake_ssh(<<~SCRIPT) do
        #!/bin/sh
        printf '%s\\n' "$@" > #{args_file}
        printf dump-bytes
      SCRIPT
        Dir.mktmpdir do |dir|
          bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}), cwd: dir)
          bridge.instance_variable_set(
            :@config,
            {
              'service' => 'demo',
              'accessories' => {
                'backup' => {
                  'host' => 'example.com',
                  'service' => 'demo-backup'
                }
              }
            }
          )

          bridge.stream_restic_dump(
            accessory_name: 'backup',
            repository_file: '/run/secrets/restic-repository',
            snapshot: 'latest',
            filename: '/databases/demo/app/postgres.pgdump',
            io: StringIO.new
          )
        end
      end

      args = File.read(args_file)
      assert_includes args, 'kamal-backup run-restic --'
      refute_includes args, 'RESTIC_REPOSITORY'
      refute_includes args, '/run/secrets/restic-repository'
    end
  end

  def test_accessory_restic_loads_mounted_config_instead_of_injecting_repository_settings
    Dir.mktmpdir do |outer|
      args_file = File.join(outer, 'ssh-args')

      with_fake_ssh(<<~SCRIPT) do
        #!/bin/sh
        printf '%s\\n' "$@" > #{args_file}
        printf dump-bytes
      SCRIPT
        Dir.mktmpdir do |dir|
          bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}), cwd: dir)
          bridge.instance_variable_set(
            :@config,
            {
              'service' => 'demo',
              'accessories' => {
                'backup' => {
                  'host' => 'example.com',
                  'service' => 'demo-backup'
                }
              }
            }
          )

          bridge.stream_restic_dump(
            accessory_name: 'backup',
            snapshot: 'latest',
            filename: '/databases/demo/app/postgres.pgdump',
            io: StringIO.new
          )
        end
      end

      args = File.read(args_file)
      assert_includes args, 'docker exec demo-backup kamal-backup run-restic -- dump latest '
      refute_includes args, 'RESTIC_REPOSITORY'
      refute_includes args, 'RESTIC_PASSWORD'
    end
  end

  def test_proxy_command_is_kept_in_a_private_ssh_config
    bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}))
    bridge.instance_variable_set(
      :@config,
      { 'ssh_options' => { 'config' => false, 'proxy' => { 'command' => '/usr/local/bin/tunnel-wrapper' } } }
    )
    file = bridge.send(:ssh_config_file)

    assert_equal "ProxyCommand /usr/local/bin/tunnel-wrapper\n", File.read(file.path)
    assert_equal 0o600, File.stat(file.path).mode & 0o777
    argv = bridge.send(:ssh_argv, 'example.com', 'true', identity_files: [], config_file: file.path)
    assert_includes argv, file.path
    refute_includes argv, '/dev/null'
    refute_includes argv.join("\n"), 'tunnel-wrapper'

    jump = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}))
    jump.instance_variable_set(:@config, { 'ssh_options' => { 'proxy' => 'bastion.example' } })
    assert_nil jump.send(:ssh_config_file)
    assert_equal ['-J', 'root@bastion.example'], jump.send(:ssh_proxy_args, 'bastion.example')
  ensure
    file&.close!
  end

  def test_accessory_restic_keeps_proxy_credentials_out_of_the_process_and_the_error
    Dir.mktmpdir do |outer|
      args_file = File.join(outer, 'ssh-args')
      config_copy = File.join(outer, 'ssh-config')
      command = 'sh -c curl https://proxy.example/connect?token=proxy-secret-value'

      with_fake_ssh(<<~SCRIPT) do
        #!/bin/sh
        printf '%s\\n' "$@" > #{args_file}
        config=
        prev=
        for arg in "$@"; do
          if [ "$prev" = "-F" ]; then
            config=$arg
          fi
          prev=$arg
        done
        cp "$config" #{config_copy}
        echo 'ssh failed while running #{command}' >&2
        exit 1
      SCRIPT
        Dir.mktmpdir do |dir|
          bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}), cwd: dir)
          bridge.instance_variable_set(
            :@config,
            {
              'service' => 'demo',
              'ssh_options' => { 'proxy' => { 'command' => command } },
              'accessories' => {
                'backup' => {
                  'host' => 'example.com',
                  'service' => 'demo-backup'
                }
              }
            }
          )

          error = assert_raises(KamalBackup::CommandError) do
            bridge.stream_restic_dump(
              accessory_name: 'backup',
              repository: 's3:https://s3.example.com/bucket?token=repo-token-value',
              snapshot: 'latest',
              filename: '/databases/demo/app/postgres.pgdump',
              io: StringIO.new
            )
          end

          args = File.read(args_file)
          config_path = args.split("\n")[args.split("\n").index('-F') + 1]
          refute_includes args, 'proxy-secret-value'
          refute_includes args, 'repo-token-value'
          refute_includes error.message, 'proxy-secret-value'
          refute_includes error.message, 'repo-token-value'
          refute_includes error.command.argv.join("\n"), 'proxy-secret-value'
          refute_includes error.command.argv.join("\n"), 'repo-token-value'
          assert_includes error.message, 'REDACTED'
          assert_includes File.read(config_copy), "ProxyCommand #{command}"
          refute File.exist?(config_path)
        end
      end
    end
  end

  def test_accessory_restic_redacts_bare_proxy_tokens_and_repository_query_secrets
    command = 'tunnel-wrapper --token proxy-plain-token'
    repository = 's3:https://s3.example.com/bucket?auth=repo-auth-value&region=us-east-1'

    with_fake_ssh(<<~SCRIPT) do
      #!/bin/sh
      echo proxy-plain-token >&2
      echo repo-auth-value >&2
      echo 'tunnel-wrapper --token proxy-plain-token' >&2
      echo 's3:https://s3.example.com/bucket?auth=repo-auth-value&region=us-east-1' >&2
      exit 1
    SCRIPT
      Dir.mktmpdir do |dir|
        bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}), cwd: dir)
        bridge.instance_variable_set(
          :@config,
          {
            'service' => 'demo',
            'ssh_options' => { 'proxy' => { 'command' => command } },
            'accessories' => {
              'backup' => {
                'host' => 'example.com',
                'service' => 'demo-backup'
              }
            }
          }
        )

        error = assert_raises(KamalBackup::CommandError) do
          bridge.stream_restic_dump(
            accessory_name: 'backup',
            repository: repository,
            snapshot: 'latest',
            filename: '/databases/demo/app/postgres.pgdump',
            io: StringIO.new
          )
        end

        refute_includes error.message, 'proxy-plain-token'
        refute_includes error.message, 'repo-auth-value'
        refute_includes error.stderr, 'proxy-plain-token'
        refute_includes error.stderr, 'repo-auth-value'
        assert_includes error.stderr, 'us-east-1'
        assert_includes error.stderr, '[REDACTED]'
        refute_includes error.command.argv.join("\n"), 'proxy-plain-token'
        refute_includes error.command.argv.join("\n"), 'repo-auth-value'
      end
    end
  end

  def test_quoted_proxy_tokens_are_redacted_when_stderr_prints_only_the_secret
    cases = [
      ["tunnel-wrapper --token 'single-secret-value'", 'single-secret-value'],
      ['tunnel-wrapper --token "double-secret-value"', 'double-secret-value'],
      ["tunnel-wrapper --token 'proxy secret value'", 'proxy secret value'],
      [%(sh -c "tunnel-wrapper --token 'nested-secret-value'"), 'nested-secret-value'],
      ["tunnel-wrapper --token 'unclosed-secret-value", 'unclosed-secret-value']
    ]

    cases.each do |command, secret|
      assert_proxy_token_redacted(command, secret)
    end
  end

  def test_credential_values_drop_shell_quotes_around_proxy_tokens
    bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}))
    cases = {
      "tunnel-wrapper --token 'single-secret-value'" => 'single-secret-value',
      'tunnel-wrapper --token "double-secret-value"' => 'double-secret-value',
      "tunnel-wrapper --token 'proxy secret value'" => 'proxy secret value',
      %(sh -c "tunnel-wrapper --token 'nested-secret-value'") => 'nested-secret-value',
      "tunnel-wrapper --token 'unclosed-secret-value" => 'unclosed-secret-value',
      's3:https://s3.example.com/bucket?auth=repo-auth-value&region=us-east-1' => 'repo-auth-value'
    }

    cases.each do |command, secret|
      values = bridge.send(:credential_values_in, command)
      assert_includes values, secret, command
      refute_includes values, %('#{secret}'), command
      refute_includes values, %("#{secret}"), command
    end

    repository = bridge.send(
      :credential_values_in,
      's3:https://s3.example.com/bucket?auth=repo-auth-value&region=us-east-1'
    )
    refute_includes repository, 'us-east-1'
  end

  def test_proxy_only_ssh_config_includes_default_files
    Dir.mktmpdir do |dir|
      user_config = File.join(dir, 'user_config')
      explicit = File.join(dir, 'explicit_config')
      File.write(user_config, "Host example\n  User deploy\n")
      File.write(explicit, "Host *\n")
      files = []
      bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}))
      bridge.define_singleton_method(:default_ssh_config_paths) { [user_config] }

      bridge.instance_variable_set(
        :@config,
        { 'ssh_options' => { 'proxy' => { 'command' => '/usr/local/bin/tunnel-wrapper' } } }
      )
      omitted = bridge.send(:ssh_config_file)
      files << omitted
      assert_equal <<~CONFIG, File.read(omitted.path)
        ProxyCommand /usr/local/bin/tunnel-wrapper
        Include "#{user_config}"
      CONFIG

      bridge.instance_variable_set(
        :@config,
        { 'ssh_options' => { 'config' => true, 'proxy' => { 'command' => '/usr/local/bin/tunnel-wrapper' } } }
      )
      enabled = bridge.send(:ssh_config_file)
      files << enabled
      assert_includes File.read(enabled.path), %(Include "#{user_config}")

      bridge.instance_variable_set(
        :@config,
        { 'ssh_options' => { 'config' => false, 'proxy' => { 'command' => '/usr/local/bin/tunnel-wrapper' } } }
      )
      disabled = bridge.send(:ssh_config_file)
      files << disabled
      assert_equal "ProxyCommand /usr/local/bin/tunnel-wrapper\n", File.read(disabled.path)

      bridge.instance_variable_set(
        :@config,
        {
          'ssh_options' => {
            'config' => explicit,
            'proxy' => { 'command' => '/usr/local/bin/tunnel-wrapper' }
          }
        }
      )
      chosen = bridge.send(:ssh_config_file)
      files << chosen
      chosen_text = File.read(chosen.path)
      assert_includes chosen_text, %(Include "#{explicit}")
      refute_includes chosen_text, user_config
    ensure
      Array(files).each { |file| file.close! if file.respond_to?(:close!) }
    end
  end

  def test_default_ssh_config_paths_skip_missing_files
    bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}))
    original_home = ENV.fetch('HOME', nil)

    Dir.mktmpdir do |home|
      ENV['HOME'] = home
      refute_includes bridge.send(:default_ssh_config_paths), File.join(home, '.ssh', 'config')

      FileUtils.mkdir_p(File.join(home, '.ssh'))
      File.write(File.join(home, '.ssh', 'config'), "Host *\n")
      paths = bridge.send(:default_ssh_config_paths)
      assert_includes paths, File.join(home, '.ssh', 'config')
      paths.each { |path| assert File.file?(path) }
    end
  ensure
    if original_home
      ENV['HOME'] = original_home
    else
      ENV.delete('HOME')
    end
  end

  def test_stream_restic_dump_does_not_report_a_missing_password_file_as_a_missing_dump
    with_fake_ssh(<<~SCRIPT) do
      #!/bin/sh
      echo 'open /run/secrets/restic-password: no such file or directory' >&2
      echo 'open /run/secrets/restic-repository: no such file or directory' >&2
      exit 1
    SCRIPT
      Dir.mktmpdir do |dir|
        bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}), cwd: dir)
        bridge.instance_variable_set(
          :@config,
          {
            'service' => 'demo',
            'accessories' => {
              'backup' => {
                'host' => 'example.com',
                'service' => 'demo-backup'
              }
            }
          }
        )

        error = assert_raises(KamalBackup::CommandError) do
          bridge.stream_restic_dump(
            accessory_name: 'backup',
            repository: '/var/lib/restic-repo',
            snapshot: 'latest',
            filename: '/databases/demo/app/postgres.pgdump',
            io: StringIO.new
          )
        end

        assert_includes error.message, 'command failed (1)'
        assert_includes error.message, '/run/secrets/restic-password'
        assert_includes error.message, '/run/secrets/restic-repository'
        refute_includes error.message, 'backup file'
      end
    end
  end

  def assert_proxy_token_redacted(command, secret)
    with_fake_ssh(<<~SCRIPT) do
      #!/bin/sh
      printf '%s\\n' #{Shellwords.shellescape(secret)} >&2
      exit 1
    SCRIPT
      Dir.mktmpdir do |dir|
        bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}), cwd: dir)
        bridge.instance_variable_set(
          :@config,
          {
            'service' => 'demo',
            'ssh_options' => { 'proxy' => { 'command' => command } },
            'accessories' => {
              'backup' => {
                'host' => 'example.com',
                'service' => 'demo-backup'
              }
            }
          }
        )

        error = assert_raises(KamalBackup::CommandError, command) do
          bridge.stream_restic_dump(
            accessory_name: 'backup',
            repository: '/var/lib/restic-repo',
            snapshot: 'latest',
            filename: '/databases/demo/app/postgres.pgdump',
            io: StringIO.new
          )
        end

        refute_includes error.message, secret, command
        refute_includes error.stderr, secret, command
        assert_includes error.stderr, '[REDACTED]', command
        refute_includes error.command.argv.join("\n"), secret, command
      end
    end
  end

  def with_fake_ssh(script)
    Dir.mktmpdir do |dir|
      bin_dir = File.join(dir, 'bin')
      FileUtils.mkdir_p(bin_dir)
      fake_ssh = File.join(bin_dir, 'ssh')
      File.write(fake_ssh, script)
      FileUtils.chmod('+x', fake_ssh)
      previous_path = ENV.fetch('PATH')
      ENV['PATH'] = "#{bin_dir}#{File::PATH_SEPARATOR}#{previous_path}"
      begin
        yield
      ensure
        ENV['PATH'] = previous_path
      end
    end
  end
end
