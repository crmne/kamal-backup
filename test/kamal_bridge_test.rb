require_relative "test_helper"

class KamalBridgeTest < Minitest::Test
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

      stub_command_capture(KamalBackup::CommandResult.new(stdout: output, stderr: "", status: 0)) do |specs|
        assert_equal "0.1.2", bridge.remote_version(accessory_name: "backup")
        assert_equal ["kamal", "accessory", "exec", "--reuse", "backup", "kamal-backup version"], specs.first.argv
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
        config_file: "config/deploy.yml",
        destination: "production",
        cwd: dir
      )

      stub_command_capture(KamalBackup::CommandResult.new(stdout: output, stderr: "", status: 0)) do |specs|
        assert_equal "0.2.5", bridge.remote_version(accessory_name: "backup")
        assert_equal [
          "kamal",
          "accessory",
          "exec",
          "-c",
          "config/deploy.yml",
          "-d",
          "production",
          "--reuse",
          "backup",
          "kamal-backup version"
        ], specs.first.argv
      end
    end
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
        when ["kamal", "config", "--version", "latest"]
          KamalBackup::CommandResult.new(stdout: config_output, stderr: "", status: 0)
        when ["kamal", "secrets", "print"]
          KamalBackup::CommandResult.new(stdout: secret_output, stderr: "", status: 0)
        else
          raise "unexpected command: #{spec.argv.inspect}"
        end
      end) do
        env = bridge.accessory_environment(accessory_name: "backup")

        assert_equal "chatwithwork", env.fetch("APP_NAME")
        assert_equal "/var/lib/kamal-backup/restic-repository", env.fetch("RESTIC_REPOSITORY_FILE")
        assert_equal "secret", env.fetch("RESTIC_PASSWORD")
        assert_equal "key", env.fetch("AWS_ACCESS_KEY_ID")
        assert_equal "postgres-secret", env.fetch("PGPASSWORD")
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
        when ["kamal", "config", "--version", "latest"]
          KamalBackup::CommandResult.new(stdout: config_output, stderr: "", status: 0)
        when ["kamal", "secrets", "print"]
          KamalBackup::CommandResult.new(stdout: secret_output, stderr: "", status: 0)
        else
          raise "unexpected command: #{spec.argv.inspect}"
        end
      end) do
        env = bridge.accessory_environment(accessory_name: "backup")

        assert_equal "s3:https://s3.example.com/app-backups", env.fetch("RESTIC_REPOSITORY")
        assert_equal "secret with spaces", env.fetch("RESTIC_PASSWORD")
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
        when ["kamal", "config", "--version", "latest"]
          KamalBackup::CommandResult.new(stdout: config_output, stderr: "", status: 0)
        when ["kamal", "secrets", "print"]
          KamalBackup::CommandResult.new(stdout: secret_output, stderr: "", status: 0)
        else
          raise "unexpected command: #{spec.argv.inspect}"
        end
      end) do
        env = bridge.accessory_environment(accessory_name: "backup")

        refute env.key?("RESTIC_PASSWORD")
      end
    end
  end

  def test_kamal_command_prefers_project_binstub
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "bin"))
      binstub = File.join(dir, "bin", "kamal")
      File.write(binstub, "#!/bin/sh\n")
      FileUtils.chmod("+x", binstub)

      bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}), cwd: dir)

      stub_command_capture(KamalBackup::CommandResult.new(stdout: "0.2.2\n", stderr: "", status: 0)) do |specs|
        assert_equal "0.2.2", bridge.remote_version(accessory_name: "backup")
        assert_equal ["bin/kamal", "accessory", "exec", "--reuse", "backup", "kamal-backup version"], specs.first.argv
      end
    end
  end

  def test_kamal_command_uses_bundle_exec_when_only_gemfile_exists
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile"), "source \"https://rubygems.org\"\n")

      bridge = KamalBackup::KamalBridge.new(redactor: KamalBackup::Redactor.new(env: {}), cwd: dir)

      stub_command_capture(KamalBackup::CommandResult.new(stdout: "0.2.2\n", stderr: "", status: 0)) do |specs|
        assert_equal "0.2.2", bridge.remote_version(accessory_name: "backup")
        assert_equal ["bundle", "exec", "kamal", "accessory", "exec", "--reuse", "backup", "kamal-backup version"], specs.first.argv
      end
    end
  end
end
