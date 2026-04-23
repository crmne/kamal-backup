require_relative "test_helper"

class CLITest < Minitest::Test
  def with_fake_app(fake)
    original_new = KamalBackup::App.method(:new)

    KamalBackup::App.define_singleton_method(:new) { |**| fake }
    yield
  ensure
    KamalBackup::App.define_singleton_method(:new) { |**kwargs| original_new.call(**kwargs) }
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
    assert_includes out, "kamal-backup backup"
    assert_includes out, "kamal-backup restore SUBCOMMAND ...ARGS"
    assert_includes out, "kamal-backup drill SUBCOMMAND ...ARGS"
    assert_includes out, "kamal-backup restore local [SNAPSHOT]"
    assert_includes out, "kamal-backup drill production [SNAPSHOT]"
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
      error = assert_raises(SystemExit) do
        with_fake_app(fake) do
          KamalBackup::CLI.start(["restore", "local"], env: base_env)
        end
      end
      assert_equal 1, error.status
    end

    assert_includes err, "confirmation required"
  end
end
