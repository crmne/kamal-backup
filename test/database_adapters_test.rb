require_relative "test_helper"

class DatabaseAdaptersTest < Minitest::Test
  def redactor
    KamalBackup::Redactor.new(env: {})
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

  def test_postgres_restore_uses_restore_database_url
    config = KamalBackup::Config.new(env: base_env(
      "DATABASE_ADAPTER" => "postgres",
      "DATABASE_URL" => "postgres://app:secret@db/app",
      "RESTORE_DATABASE_URL" => "postgres://app:secret@db/app_restore"
    ))
    adapter = KamalBackup::Databases::Postgres.new(config, redactor: redactor)
    command = adapter.restore_command

    assert_includes command.argv, "app_restore"
    refute_includes command.argv.join(" "), "secret"
    assert_equal(
      {
        "PGHOST" => "db",
        "PGUSER" => "app",
        "PGPASSWORD" => "secret",
        "PGDATABASE" => "app_restore"
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

  def test_postgres_restore_target_identifier_keeps_url_for_exact_safety_check
    config = KamalBackup::Config.new(env: base_env(
      "DATABASE_ADAPTER" => "postgres",
      "DATABASE_URL" => "postgres://app:secret@db/app",
      "RESTORE_DATABASE_URL" => "postgres://app:secret@db/app"
    ))
    adapter = KamalBackup::Databases::Postgres.new(config, redactor: redactor)

    error = assert_raises(KamalBackup::ConfigurationError) { adapter.validate_restore_target }
    assert_match(/production-looking restore target/, error.message)
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

  def test_mysql_restore_uses_restore_database_url
    config = KamalBackup::Config.new(env: base_env(
      "DATABASE_ADAPTER" => "mysql",
      "DATABASE_URL" => "mysql2://app:secret@mysql:3306/app_test",
      "RESTORE_DATABASE_URL" => "mysql2://restore:restore-secret@mysql:3306/app_restore",
      "MYSQL_CLIENT_BIN" => "mysql"
    ))
    adapter = KamalBackup::Databases::Mysql.new(config, redactor: redactor)
    command = adapter.restore_command

    assert_equal "mysql", command.argv.first
    assert_includes command.argv, "app_restore"
    assert_equal({ "MYSQL_PWD" => "restore-secret" }, command.env)
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

  def test_sqlite_refuses_in_place_restore_without_flag
    Dir.mktmpdir do |dir|
      source = File.join(dir, "app.sqlite3")
      File.write(source, "")
      config = KamalBackup::Config.new(env: base_env(
        "DATABASE_ADAPTER" => "sqlite",
        "SQLITE_DATABASE_PATH" => source,
        "RESTORE_SQLITE_DATABASE_PATH" => source
      ))
      adapter = KamalBackup::Databases::Sqlite.new(config, redactor: redactor)

      error = assert_raises(KamalBackup::ConfigurationError) { adapter.send(:validate_restore_target) }
      assert_match(/in-place SQLite restore/, error.message)
    end
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
end
