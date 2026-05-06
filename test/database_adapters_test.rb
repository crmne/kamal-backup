require_relative "test_helper"

class DatabaseAdaptersTest < Minitest::Test
  def redactor
    KamalBackup::Redactor.new(env: {})
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

  def test_postgres_dump_command_uses_custom_format
    config = KamalBackup::Config.new(env: base_env(
      "DATABASE_ADAPTER" => "postgres",
      "DATABASE_URL" => "postgres://app:secret@db/app"
    ))
    adapter = KamalBackup::Databases::Postgres.new(config, redactor: redactor)
    command = adapter.dump_command

    assert_equal [
      "pg_dump",
      "--format=custom",
      "--no-owner",
      "--no-privileges"
    ], command.argv
    refute_includes command.argv.join(" "), "secret"
    assert_equal(
      {
        "PGHOST" => "db",
        "PGUSER" => "app",
        "PGPASSWORD" => "secret",
        "PGDATABASE" => "app"
      },
      command.env
    )
  end

  def test_postgres_current_restore_uses_current_database_url
    config = KamalBackup::Config.new(env: base_env(
      "DATABASE_ADAPTER" => "postgres",
      "DATABASE_URL" => "postgres://app:secret@db/app_development"
    ))
    adapter = KamalBackup::Databases::Postgres.new(config, redactor: redactor)
    command = adapter.current_restore_command

    assert_includes command.argv, "app_development"
    refute_includes command.argv.join(" "), "secret"
    assert_equal(
      {
        "PGHOST" => "db",
        "PGUSER" => "app",
        "PGPASSWORD" => "secret",
        "PGDATABASE" => "app_development"
      },
      command.env
    )
  end

  def test_postgres_scratch_restore_uses_the_requested_database
    config = KamalBackup::Config.new(env: base_env(
      "DATABASE_ADAPTER" => "postgres",
      "DATABASE_URL" => "postgres://app:secret@db/app_production"
    ))
    adapter = KamalBackup::Databases::Postgres.new(config, redactor: redactor)
    command = adapter.scratch_restore_command("app_restore_20260423")

    assert_includes command.argv, "app_restore_20260423"
    assert_equal "app_restore_20260423", command.env.fetch("PGDATABASE")
  end

  def test_postgres_scratch_restore_refuses_the_current_database
    config = KamalBackup::Config.new(env: base_env(
      "DATABASE_ADAPTER" => "postgres",
      "DATABASE_URL" => "postgres://app:secret@db/app"
    ))
    adapter = KamalBackup::Databases::Postgres.new(config, redactor: redactor)

    error = assert_raises(KamalBackup::ConfigurationError) do
      adapter.send(:validate_scratch_restore_target, "app")
    end
    assert_match(/scratch database must differ/, error.message)
  end

  def test_mysql_dump_command_uses_transaction_safe_options_and_password_env
    config = KamalBackup::Config.new(env: base_env(
      "DATABASE_ADAPTER" => "mysql",
      "DATABASE_URL" => "mysql2://app:secret@mysql:3306/app_test",
      "MYSQL_DUMP_BIN" => "mysqldump"
    ))
    adapter = KamalBackup::Databases::Mysql.new(config, redactor: redactor)
    command = adapter.dump_command

    assert_equal "mysqldump", command.argv.first
    assert_includes command.argv, "--single-transaction"
    assert_includes command.argv, "--quick"
    assert_includes command.argv, "--routines"
    assert_includes command.argv, "--triggers"
    assert_includes command.argv, "--events"
    assert_includes command.argv, "app_test"
    assert_equal({ "MYSQL_PWD" => "secret" }, command.env)
  end

  def test_mysql_current_restore_uses_current_database_url
    config = KamalBackup::Config.new(env: base_env(
      "DATABASE_ADAPTER" => "mysql",
      "DATABASE_URL" => "mysql2://app:secret@mysql:3306/app_development",
      "MYSQL_CLIENT_BIN" => "mysql"
    ))
    adapter = KamalBackup::Databases::Mysql.new(config, redactor: redactor)
    command = adapter.current_restore_command

    assert_equal "mysql", command.argv.first
    assert_includes command.argv, "app_development"
    assert_equal({ "MYSQL_PWD" => "secret" }, command.env)
  end

  def test_mysql_scratch_restore_uses_the_requested_database
    config = KamalBackup::Config.new(env: base_env(
      "DATABASE_ADAPTER" => "mysql",
      "DATABASE_URL" => "mysql2://app:secret@mysql:3306/app_production",
      "MYSQL_CLIENT_BIN" => "mysql"
    ))
    adapter = KamalBackup::Databases::Mysql.new(config, redactor: redactor)
    command = adapter.scratch_restore_command("app_restore_20260423")

    assert_equal "mysql", command.argv.first
    assert_includes command.argv, "app_restore_20260423"
    assert_equal({ "MYSQL_PWD" => "secret" }, command.env)
  end

  def test_mysql_scratch_restore_refuses_the_current_database
    config = KamalBackup::Config.new(env: base_env(
      "DATABASE_ADAPTER" => "mysql",
      "DATABASE_URL" => "mysql2://app:secret@mysql:3306/app_production",
      "MYSQL_CLIENT_BIN" => "mysql"
    ))
    adapter = KamalBackup::Databases::Mysql.new(config, redactor: redactor)

    error = assert_raises(KamalBackup::ConfigurationError) do
      adapter.send(:validate_scratch_restore_target, "app_production")
    end
    assert_match(/scratch database must differ/, error.message)
  end

  def test_sqlite_current_restore_uses_the_configured_database_path
    config = KamalBackup::Config.new(env: base_env(
      "DATABASE_ADAPTER" => "sqlite",
      "SQLITE_DATABASE_PATH" => "/tmp/app_development.sqlite3"
    ))
    adapter = KamalBackup::Databases::Sqlite.new(config, redactor: redactor)

    assert_equal "/tmp/app_development.sqlite3", adapter.current_target_identifier
  end

  def test_sqlite_scratch_restore_refuses_the_current_database_path
    config = KamalBackup::Config.new(env: base_env(
      "DATABASE_ADAPTER" => "sqlite",
      "SQLITE_DATABASE_PATH" => "/tmp/app_development.sqlite3"
    ))
    adapter = KamalBackup::Databases::Sqlite.new(config, redactor: redactor)

    error = assert_raises(KamalBackup::ConfigurationError) do
      adapter.send(:validate_scratch_restore_target, "/tmp/app_development.sqlite3")
    end
    assert_match(/scratch SQLite path must differ/, error.message)
  end

  def test_sqlite_literal_escapes_single_quotes
    config = KamalBackup::Config.new(env: base_env(
      "DATABASE_ADAPTER" => "sqlite",
      "SQLITE_DATABASE_PATH" => "/tmp/app.sqlite3"
    ))
    adapter = KamalBackup::Databases::Sqlite.new(config, redactor: redactor)

    assert_equal "'/tmp/kamal''backup.sqlite3'", adapter.send(:sqlite_literal, "/tmp/kamal'backup.sqlite3")
  end

  def test_sqlite_backup_retries_immutable_uri_when_readonly_wal_sidecars_are_absent
    Dir.mktmpdir do |dir|
      source = File.join(dir, "app db.sqlite3")
      target = File.join(dir, "backup.sqlite3")
      config = KamalBackup::Config.new(env: base_env(
        "DATABASE_ADAPTER" => "sqlite",
        "SQLITE_DATABASE_PATH" => source
      ))
      adapter = KamalBackup::Databases::Sqlite.new(config, redactor: redactor)
      attempts = 0

      stub_command_capture(proc do |spec|
        attempts += 1
        if attempts == 1
          raise KamalBackup::CommandError.new(
            "command failed (1): sqlite3\nError: attempt to write a readonly database",
            command: spec,
            status: 1,
            stderr: "Error: attempt to write a readonly database"
          )
        else
          KamalBackup::CommandResult.new(stdout: "", stderr: "", status: 0)
        end
      end) do |specs|
        adapter.send(:backup_to_file, source, target)

        assert_equal 2, specs.size
        assert_equal source, specs.first.argv[1]
        assert_equal "file:#{dir}/app%20db.sqlite3?immutable=1", specs.last.argv[1]
      end
    end
  end

  def test_sqlite_backup_does_not_retry_immutable_uri_when_wal_file_exists
    Dir.mktmpdir do |dir|
      source = File.join(dir, "app.sqlite3")
      target = File.join(dir, "backup.sqlite3")
      FileUtils.touch("#{source}-wal")
      config = KamalBackup::Config.new(env: base_env(
        "DATABASE_ADAPTER" => "sqlite",
        "SQLITE_DATABASE_PATH" => source
      ))
      adapter = KamalBackup::Databases::Sqlite.new(config, redactor: redactor)
      error = KamalBackup::CommandError.new(
        "command failed (1): sqlite3\nError: attempt to write a readonly database",
        command: KamalBackup::CommandSpec.new(argv: ["sqlite3", source, ".backup #{target}"]),
        status: 1,
        stderr: "Error: attempt to write a readonly database"
      )

      stub_command_capture(proc { |_spec| raise error }) do |specs|
        assert_raises(KamalBackup::CommandError) { adapter.send(:backup_to_file, source, target) }
        assert_equal 1, specs.size
      end
    end
  end
end
