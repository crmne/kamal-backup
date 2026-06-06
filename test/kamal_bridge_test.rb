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
        assert_equal ['kamal', 'accessory', 'exec', '--reuse', 'backup', 'kamal-backup version'], specs.first.argv
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
          'kamal-backup version'
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
      assert_equal ['kamal', 'accessory', 'exec', '--reuse', 'backup', 'kamal-backup version'],
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
      kwargs.fetch(:tee_stdout).print("kamal stdout\n")
      kwargs.fetch(:tee_stderr).print("kamal stderr\n")
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
        bridge.execute_on_accessory(accessory_name: 'backup', command: 'kamal-backup backup', stream: true)
      end

      assert result.streamed
      assert_equal "kamal stdout\n", out.string
      assert_equal "kamal stderr\n", err.string
      assert_equal ['kamal', 'accessory', 'exec', '--reuse', 'backup', 'kamal-backup backup'],
                   calls.first.fetch(:spec).argv
      assert_equal false, calls.first.fetch(:kwargs).fetch(:log)
      assert_equal false, calls.first.fetch(:kwargs).fetch(:log_output)
      assert_same out, calls.first.fetch(:kwargs).fetch(:tee_stdout)
      assert_same err, calls.first.fetch(:kwargs).fetch(:tee_stderr)
    end
  ensure
    KamalBackup::Command.define_singleton_method(:capture) { |*args, **kwargs, &block| original.call(*args, **kwargs, &block) }
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

      assert_equal '1', calls.first.fetch(:spec).env.fetch('SSHKIT_COLOR')
      assert_equal false, calls.first.fetch(:kwargs).fetch(:log)
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
      assert_equal ['kamal', 'accessory', 'exec', '--interactive', '--reuse', 'backup', 'kamal-backup backup'],
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
        assert_equal ['bin/kamal', 'accessory', 'exec', '--reuse', 'backup', 'kamal-backup version'], specs.first.argv
      end
    end
  end

  def test_kamal_command_uses_bundle_exec_when_only_gemfile_exists
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Gemfile'), "source \"https://rubygems.org\"\n")

      bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}), cwd: dir)

      stub_command_capture(KamalBackup::CommandResult.new(stdout: "0.2.2\n", stderr: '', status: 0)) do |specs|
        assert_equal '0.2.2', bridge.remote_version(accessory_name: 'backup')
        assert_equal ['bundle', 'exec', 'kamal', 'accessory', 'exec', '--reuse', 'backup', 'kamal-backup version'],
                     specs.first.argv
      end
    end
  end
end
