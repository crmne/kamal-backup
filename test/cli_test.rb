require_relative "test_helper"

class CLITest < Minitest::Test
  def stub_constructor(klass, fake = nil, replacement: nil)
    original_new = klass.method(:new)
    handler = replacement || proc { |*_, **| fake }

    klass.define_singleton_method(:new, &handler)
    yield
  ensure
    klass.define_singleton_method(:new) { |*args, **kwargs, &block| original_new.call(*args, **kwargs, &block) }
  end

  def with_fake_app(fake, &block)
    stub_constructor(KamalBackup::App, fake, &block)
  end

  def with_fake_bridge(fake)
    stub_constructor(KamalBackup::KamalBridge, fake, replacement: proc { |*_, **| fake }) { yield }
  end

  def without_stdin
    previous_stdin = $stdin
    File.open(File::NULL) do |input|
      $stdin = input
      yield
    end
  ensure
    $stdin = previous_stdin
  end

  def test_start_redacts_error_messages
    fake = Object.new
    def fake.backup
      raise KamalBackup::ConfigurationError, "bad postgres://app:secret@db/app with secret"
    end

    _, err = capture_io do
      error = assert_raises(SystemExit) do
        with_fake_app(fake) do
          KamalBackup::CLI.start(["backup"], env: { "DATABASE_URL" => "postgres://app:secret@db/app", "PGPASSWORD" => "secret" })
        end
      end
      assert_equal 1, error.status
    end

    refute_includes err, "secret"
    assert_includes err, "postgres://[REDACTED]@db/app"
  end

  def test_version_command_prints_version
    out, _ = capture_io { KamalBackup::CLI.start(["--version"], env: base_env) }

    assert_equal "#{KamalBackup::VERSION}\n", out
  end

  def test_help_lists_commands
    out, = capture_io { KamalBackup::CLI.start([], env: base_env) }

    assert_includes out, "kamal-backup help [COMMAND]"
    assert_includes out, "kamal-backup init"
    assert_includes out, "kamal-backup backup"
    assert_includes out, "kamal-backup validate"
    assert_includes out, "kamal-backup restore SUBCOMMAND ...ARGS"
    assert_includes out, "kamal-backup drill SUBCOMMAND ...ARGS"
    assert_includes out, "kamal-backup restore local [SNAPSHOT]"
    assert_includes out, "kamal-backup drill production [SNAPSHOT]"
  end

  def test_validate_without_destination_validates_local_config
    Dir.mktmpdir do |dir|
      db = File.join(dir, "app.sqlite3")
      files = File.join(dir, "storage")
      File.write(db, "")
      FileUtils.mkdir_p(files)

      out, _ = Dir.chdir(dir) do
        capture_io do
          KamalBackup::CLI.start(["validate"], env: base_env(
            "DATABASE_ADAPTER" => "sqlite",
            "SQLITE_DATABASE_PATH" => db,
            "BACKUP_PATHS" => files
          ))
        end
      end

      assert_equal "ok\n", out
    end
  end

  def test_restore_local_prints_json_output
    fake = Object.new
    def fake.restore_to_local_machine(*)
      { status: "ok", mode: "local" }
    end

    out, _ = capture_io do
      with_fake_app(fake) do
        KamalBackup::CLI.start(["restore", "local", "--yes"], env: base_env)
      end
    end

    assert_includes out, "\"status\": \"ok\""
    assert_includes out, "\"mode\": \"local\""
  end

  def test_restore_production_requires_specific_confirmation_flag_for_noninteractive_use
    fake = Object.new
    def fake.restore_to_production(*)
      raise "should not run"
    end

    _, err = capture_io do
      error = assert_raises(SystemExit) do
        with_fake_app(fake) do
          KamalBackup::CLI.start(["restore", "production", "latest", "--yes"], env: base_env)
        end
      end
      assert_equal 1, error.status
    end

    assert_includes err, "--yes does not bypass restore production"
  end

  def test_restore_production_with_explicit_confirmation_prints_json_output
    fake = Object.new
    def fake.restore_to_production(*)
      { status: "ok", mode: "production" }
    end

    out, _ = capture_io do
      with_fake_app(fake) do
        KamalBackup::CLI.start(["restore", "production", "latest", "--confirm-production-restore"], env: base_env)
      end
    end

    assert_includes out, "\"status\": \"ok\""
    assert_includes out, "\"mode\": \"production\""
  end

  def test_drill_local_prints_json_output
    fake = Object.new
    def fake.drill_on_local_machine(*, **)
      { status: "ok", mode: "local" }
    end

    def fake.drill_failed?(result)
      result.fetch(:status) != "ok"
    end

    out, _ = capture_io do
      with_fake_app(fake) do
        KamalBackup::CLI.start(["drill", "local", "--yes"], env: base_env)
      end
    end

    assert_includes out, "\"status\": \"ok\""
    assert_includes out, "\"mode\": \"local\""
  end

  def test_drill_local_exits_non_zero_when_the_drill_failed
    fake = Object.new
    def fake.drill_on_local_machine(*, **)
      { status: "failed", error: "restore failed" }
    end

    def fake.drill_failed?(result)
      result.fetch(:status) != "ok"
    end

    out, _ = capture_io do
      with_fake_app(fake) do
        error = assert_raises(SystemExit) do
          KamalBackup::CLI.start(["drill", "local", "--yes"], env: base_env)
        end
        assert_equal 1, error.status
      end
    end

    assert_includes out, "\"status\": \"failed\""
    assert_includes out, "\"error\": \"restore failed\""
  end

  def test_drill_production_uses_the_requested_scratch_targets
    fake = Object.new
    fake.define_singleton_method(:config) { Struct.new(:database_adapter).new("postgres") }
    fake.define_singleton_method(:drill_on_production) do |snapshot, database_name:, sqlite_path:, file_target:, check_command:|
      {
        snapshot: snapshot,
        database_name: database_name,
        sqlite_path: sqlite_path,
        file_target: file_target,
        check_command: check_command
      }
    end
    fake.define_singleton_method(:drill_failed?) { |_| false }

    out, _ = capture_io do
      with_fake_app(fake) do
        KamalBackup::CLI.start(
          ["drill", "production", "latest", "--database", "app_restore_20260423", "--files", "/restore/files", "--check", "printf verified", "--yes"],
          env: base_env
        )
      end
    end

    assert_includes out, "\"database_name\": \"app_restore_20260423\""
    assert_includes out, "\"file_target\": \"/restore/files\""
    assert_includes out, "\"check_command\": \"printf verified\""
  end

  def test_restore_requires_confirmation_or_yes
    fake = Object.new
    def fake.restore_to_local_machine(*)
      raise "should not run"
    end

    _, err = capture_io do
      without_stdin do
        error = assert_raises(SystemExit) do
          with_fake_app(fake) do
            KamalBackup::CLI.start(["restore", "local"], env: base_env)
          end
        end
        assert_equal 1, error.status
      end
    end

    assert_includes err, "confirmation required"
  end

  def test_restore_production_with_destination_passes_specific_confirmation_flag
    fake_bridge = Object.new
    calls = []

    fake_bridge.define_singleton_method(:accessory_name) { |preferred:| "backup" }
    fake_bridge.define_singleton_method(:remote_version) do |accessory_name:|
      calls << { accessory_name: accessory_name, command: "kamal-backup version" }
      KamalBackup::VERSION
    end
    fake_bridge.define_singleton_method(:execute_on_accessory) do |accessory_name:, command:|
      calls << { accessory_name: accessory_name, command: command }
      KamalBackup::CommandResult.new(stdout: "remote restore\n", stderr: "", status: 0)
    end

    out, _ = capture_io do
      with_fake_bridge(fake_bridge) do
        KamalBackup::CLI.start(["-d", "production", "restore", "production", "latest", "--confirm-production-restore"], env: {})
      end
    end

    assert_equal [
      { accessory_name: "backup", command: "kamal-backup version" },
      { accessory_name: "backup", command: "kamal-backup restore production latest --confirm-production-restore" }
    ], calls
    assert_equal "remote restore\n", out
  end

  def test_init_creates_local_config_stubs
    Dir.mktmpdir do |dir|
      out, _ = Dir.chdir(dir) do
        capture_io { KamalBackup::CLI.start(["init"], env: {}) }
      end

      assert File.file?(File.join(dir, "config", "kamal-backup.yml"))
      assert_includes File.read(File.join(dir, "config", "kamal-backup.yml")), "accessory: backup"
      assert_includes File.read(File.join(dir, "config", "kamal-backup.yml")), "app_name: your-app"
      assert_includes File.read(File.join(dir, "config", "kamal-backup.yml")), "backup_schedule_seconds: 86400"
      refute File.exist?(File.join(dir, "config", "kamal-backup.local.yml"))
      assert_includes out, "Add this accessory block to your Kamal deploy config:"
      assert_includes out, "files:"
      assert_includes out, "config/kamal-backup.yml:/app/config/kamal-backup.yml:ro"
      assert_includes out, "Local restore and drill also require the restic binary on your machine."
      assert_includes out, "Create config/kamal-backup.local.yml only if you need to override those local defaults."
      refute_includes out, "aliases:"
    end
  end

  def test_backup_with_destination_runs_through_kamal
    fake_bridge = Object.new
    calls = []
    preferred_values = []

    fake_bridge.define_singleton_method(:accessory_name) do |preferred:|
      preferred_values << preferred
      "backup"
    end

    fake_bridge.define_singleton_method(:execute_on_accessory) do |accessory_name:, command:|
      calls << { accessory_name: accessory_name, command: command }
      KamalBackup::CommandResult.new(stdout: "remote backup\n", stderr: "", status: 0)
    end

    fake_bridge.define_singleton_method(:remote_version) do |accessory_name:|
      calls << { accessory_name: accessory_name, command: "kamal-backup version" }
      KamalBackup::VERSION
    end

    Dir.mktmpdir do |dir|
      out, _ = Dir.chdir(dir) do
        capture_io do
          with_fake_bridge(fake_bridge) do
            KamalBackup::CLI.start(["-d", "production", "backup"], env: {})
          end
        end
      end

      assert_equal [nil], preferred_values
      assert_equal [
        { accessory_name: "backup", command: "kamal-backup version" },
        { accessory_name: "backup", command: "kamal-backup backup" }
      ], calls
      assert_equal "remote backup\n", out
    end
  end

  def test_remote_commands_without_destination_use_default_deploy_config_when_present
    commands = {
      ["backup"] => "kamal-backup backup",
      ["list"] => "kamal-backup list",
      ["check"] => "kamal-backup check",
      ["evidence"] => "kamal-backup evidence"
    }

    commands.each do |argv, expected_command|
      fake_bridge = Object.new
      calls = []

      fake_bridge.define_singleton_method(:accessory_name) { |preferred:| "backup" }
      fake_bridge.define_singleton_method(:remote_version) do |accessory_name:|
        calls << { accessory_name: accessory_name, command: "kamal-backup version" }
        KamalBackup::VERSION
      end
      fake_bridge.define_singleton_method(:execute_on_accessory) do |accessory_name:, command:|
        calls << { accessory_name: accessory_name, command: command }
        KamalBackup::CommandResult.new(stdout: "remote #{argv.first}\n", stderr: "", status: 0)
      end

      Dir.mktmpdir do |dir|
        config_dir = File.join(dir, "config")
        FileUtils.mkdir_p(config_dir)
        File.write(File.join(config_dir, "deploy.yml"), "accessories: {}\n")

        out, _ = Dir.chdir(dir) do
          capture_io do
            with_fake_bridge(fake_bridge) do
              KamalBackup::CLI.start(argv, env: {})
            end
          end
        end

        assert_equal [
          { accessory_name: "backup", command: "kamal-backup version" },
          { accessory_name: "backup", command: expected_command }
        ], calls
        assert_equal "remote #{argv.first}\n", out
      end
    end
  end

  def test_validate_with_destination_checks_rendered_accessory_config_without_remote_exec
    fake_bridge = Object.new
    calls = []

    fake_bridge.define_singleton_method(:accessory_name) { |preferred:| "backup" }
    fake_bridge.define_singleton_method(:accessory_environment) do |accessory_name:|
      calls << { accessory_name: accessory_name, command: "accessory_environment" }
      {
        "APP_NAME" => "chatwithwork",
        "DATABASE_ADAPTER" => "postgres",
        "DATABASE_URL" => "postgres://chatwithwork@chatwithwork-db:5432/chatwithwork_production",
        "BACKUP_PATHS" => "/data/storage",
        "RESTIC_REPOSITORY" => "s3:https://s3.example.com/chatwithwork-backups",
        "RESTIC_PASSWORD" => "configured"
      }
    end
    fake_bridge.define_singleton_method(:remote_version) do |**|
      raise "should not check a running accessory"
    end
    fake_bridge.define_singleton_method(:execute_on_accessory) do |**|
      raise "should not run remote commands"
    end

    out, _ = capture_io do
      with_fake_bridge(fake_bridge) do
        KamalBackup::CLI.start(["-d", "production", "validate"], env: {})
      end
    end

    assert_equal [{ accessory_name: "backup", command: "accessory_environment" }], calls
    assert_equal "ok\n", out
  end

  def test_restore_local_with_destination_uses_remote_defaults_and_local_targets
    fake_bridge = Object.new
    received = {}

    fake_bridge.define_singleton_method(:accessory_name) { |preferred:| "backup" }
    fake_bridge.define_singleton_method(:local_restore_defaults) do |accessory_name:|
      {
        "APP_NAME" => "chatwithwork",
        "DATABASE_ADAPTER" => "postgres",
        "RESTIC_REPOSITORY" => "s3:https://s3.example.com/chatwithwork-backups",
        "LOCAL_RESTORE_SOURCE_PATHS" => "/data/storage"
      }
    end

    fake_app = Object.new
    fake_app.define_singleton_method(:restore_to_local_machine) do |_snapshot|
      { status: "ok" }
    end

    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, "config")
      FileUtils.mkdir_p(config_dir)
      File.write(
        File.join(config_dir, "database.yml"),
        <<~YAML
          development:
            adapter: postgresql
            database: chatwithwork_development
            username: chatwithwork
            host: localhost
        YAML
      )

      out, _ = Dir.chdir(dir) do
        capture_io do
          with_fake_bridge(fake_bridge) do
            stub_constructor(
              KamalBackup::App,
              replacement: proc do |*_, config:, **|
                received[:config] = config
                fake_app
              end
            ) do
              KamalBackup::CLI.start(["-d", "production", "restore", "local", "latest", "--yes"], env: { "RESTIC_PASSWORD" => "secret" })
            end
          end
        end
      end

      config = received.fetch(:config)

      assert_equal "chatwithwork", config.app_name
      assert_equal "postgres", config.database_adapter
      assert_equal "s3:https://s3.example.com/chatwithwork-backups", config.restic_repository
      assert_equal ["/data/storage"], config.local_restore_source_paths
      assert_equal "chatwithwork_development", config.value("PGDATABASE")
      assert_equal "chatwithwork", config.value("PGUSER")
      assert_equal "localhost", config.value("PGHOST")
      assert_equal [File.join(dir, "storage")], config.backup_paths
      assert_includes out, "\"status\": \"ok\""
    end
  end

  def test_restore_local_with_destination_uses_shared_yaml_as_production_source
    fake_bridge = Object.new
    received = {}

    fake_bridge.define_singleton_method(:accessory_name) { |preferred:| "backup" }
    fake_bridge.define_singleton_method(:local_restore_defaults) { |accessory_name:| {} }

    fake_app = Object.new
    fake_app.define_singleton_method(:restore_to_local_machine) do |_snapshot|
      { status: "ok" }
    end

    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, "config")
      FileUtils.mkdir_p(config_dir)
      File.write(
        File.join(config_dir, "database.yml"),
        <<~YAML
          development:
            adapter: postgresql
            database: chatwithwork_development
            username: chatwithwork
            host: localhost
        YAML
      )
      File.write(
        File.join(config_dir, "kamal-backup.yml"),
        <<~YAML
          accessory: backup
          app_name: chatwithwork
          database_adapter: postgres
          database_url: postgres://chatwithwork@chatwithwork-db:5432/chatwithwork_production
          backup_paths:
            - /data/storage
          restic_repository: s3:https://s3.example.com/chatwithwork-backups
        YAML
      )

      out, _ = Dir.chdir(dir) do
        capture_io do
          with_fake_bridge(fake_bridge) do
            stub_constructor(
              KamalBackup::App,
              replacement: proc do |*_, config:, **|
                received[:config] = config
                fake_app
              end
            ) do
              KamalBackup::CLI.start(["-d", "production", "restore", "local", "latest", "--yes"], env: { "RESTIC_PASSWORD" => "secret" })
            end
          end
        end
      end

      config = received.fetch(:config)

      assert_equal "chatwithwork", config.app_name
      assert_equal "postgres", config.database_adapter
      assert_equal "s3:https://s3.example.com/chatwithwork-backups", config.restic_repository
      assert_equal ["/data/storage"], config.local_restore_source_paths
      assert_equal [File.join(dir, "storage")], config.backup_paths
      assert_includes out, "\"status\": \"ok\""
    end
  end

  def test_version_with_destination_runs_through_kamal
    fake_bridge = Object.new
    requested_accessories = []

    fake_bridge.define_singleton_method(:accessory_name) { |preferred:| "backup" }
    fake_bridge.define_singleton_method(:remote_version) do |accessory_name:|
      requested_accessories << accessory_name
      KamalBackup::VERSION
    end

    out, _ = capture_io do
      with_fake_bridge(fake_bridge) do
        KamalBackup::CLI.start(["-d", "production", "version"], env: {})
      end
    end

    assert_equal ["backup"], requested_accessories
    assert_includes out, "local: #{KamalBackup::VERSION}"
    assert_includes out, "remote: #{KamalBackup::VERSION}"
    assert_includes out, "status: in sync"
  end

  def test_version_without_destination_uses_default_deploy_config_when_present
    fake_bridge = Object.new
    requested_accessories = []

    fake_bridge.define_singleton_method(:accessory_name) { |preferred:| "backup" }
    fake_bridge.define_singleton_method(:remote_version) do |accessory_name:|
      requested_accessories << accessory_name
      KamalBackup::VERSION
    end

    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, "config")
      FileUtils.mkdir_p(config_dir)
      File.write(File.join(config_dir, "deploy.yml"), "accessories: {}\n")

      out, _ = Dir.chdir(dir) do
        capture_io do
          with_fake_bridge(fake_bridge) do
            KamalBackup::CLI.start(["version"], env: {})
          end
        end
      end

      assert_equal ["backup"], requested_accessories
      assert_includes out, "local: #{KamalBackup::VERSION}"
      assert_includes out, "remote: #{KamalBackup::VERSION}"
      assert_includes out, "status: in sync"
    end
  end

  def test_remote_commands_fail_when_versions_do_not_match
    fake_bridge = Object.new

    fake_bridge.define_singleton_method(:accessory_name) { |preferred:| "backup" }
    fake_bridge.define_singleton_method(:remote_version) { |accessory_name:| "0.0.9" }
    fake_bridge.define_singleton_method(:execute_on_accessory) do |**|
      raise "should not run"
    end

    _, err = capture_io do
      error = assert_raises(SystemExit) do
        with_fake_bridge(fake_bridge) do
          KamalBackup::CLI.start(["-d", "production", "list"], env: {})
        end
      end
      assert_equal 1, error.status
    end

    assert_includes err, "local gem version #{KamalBackup::VERSION} does not match remote accessory version 0.0.9"
    assert_includes err, "bin/kamal accessory reboot backup -d production"
  end

  def test_version_with_destination_reports_out_of_sync_without_failing
    fake_bridge = Object.new

    fake_bridge.define_singleton_method(:accessory_name) { |preferred:| "backup" }
    fake_bridge.define_singleton_method(:remote_version) { |accessory_name:| "0.0.9" }

    out, _ = capture_io do
      with_fake_bridge(fake_bridge) do
        KamalBackup::CLI.start(["-d", "production", "version"], env: {})
      end
    end

    assert_includes out, "local: #{KamalBackup::VERSION}"
    assert_includes out, "remote: 0.0.9"
    assert_includes out, "status: out of sync"
    assert_includes out, "fix: bin/kamal accessory reboot backup -d production"
  end
end
