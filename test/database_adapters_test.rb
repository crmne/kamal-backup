# frozen_string_literal: true

require_relative 'test_helper'

class DatabaseAdaptersTest < Minitest::Test
  def redactor
    KamalBackup::Redactor.new(env: {})
  end

  def test_postgres_dump_command_uses_custom_format
    config = KamalBackup::Config.new(env: base_env(
      'DATABASE_ADAPTER' => 'postgres',
      'DATABASE_URL' => 'postgres://app:secret@db/app'
    ))
    adapter = KamalBackup::Databases::Postgres.new(config, redactor: redactor)
    command = adapter.dump_command

    assert_equal [
      'pg_dump',
      '--format=custom',
      '--no-owner',
      '--no-privileges'
    ], command.argv
    refute_includes command.argv.join(' '), 'secret'
    assert_equal(
      {
        'PGHOST' => 'db',
        'PGUSER' => 'app',
        'PGPASSWORD' => 'secret',
        'PGDATABASE' => 'app'
      },
      command.env
    )
  end

  def test_database_backup_uses_stable_filename_and_tags
    config = KamalBackup::Config.new(env: base_env(
      'APP_NAME' => 'chatwithwork',
      'DATABASE_ADAPTER' => 'postgres',
      'DATABASE_URL' => 'postgres://app:secret@db/app'
    ))
    adapter = KamalBackup::Databases::Postgres.new(config.databases.first, redactor: redactor)

    assert_equal 'databases/chatwithwork/app/postgres.pgdump', adapter.database_filename
    assert_equal ['type:database', 'database:app', 'adapter:postgres'], adapter.backup_tags
  end

  def test_postgres_current_restore_uses_current_database_url
    config = KamalBackup::Config.new(env: base_env(
      'DATABASE_ADAPTER' => 'postgres',
      'DATABASE_URL' => 'postgres://app:secret@db/app_development'
    ))
    adapter = KamalBackup::Databases::Postgres.new(config, redactor: redactor)
    command = adapter.current_restore_command

    assert_includes command.argv, 'app_development'
    refute_includes command.argv.join(' '), 'secret'
    assert_equal(
      {
        'PGHOST' => 'db',
        'PGUSER' => 'app',
        'PGPASSWORD' => 'secret',
        'PGDATABASE' => 'app_development'
      },
      command.env
    )
  end

  def test_postgres_current_restore_resets_the_schema_first
    config = KamalBackup::Config.new(env: base_env(
      'DATABASE_ADAPTER' => 'postgres',
      'DATABASE_URL' => 'postgres://app:secret@db/app_production'
    ))
    adapter = KamalBackup::Databases::Postgres.new(config, redactor: redactor)

    captured = []
    fake_restic = Object.new
    fake_restic.define_singleton_method(:pipe_dump_to_command) do |_snapshot, _filename, _command|
      captured << :pg_restore
      KamalBackup::CommandResult.new(stdout: '', stderr: '', status: 0)
    end

    KamalBackup::Command.stub(:capture, lambda { |spec, **|
      captured << spec.argv
      KamalBackup::CommandResult.new(stdout: '', stderr: '', status: 0)
    }) do
      adapter.restore_to_current(fake_restic, 'latest', 'dump.pgdump')
    end

    reset = captured.first
    assert_kind_of Array, reset, 'schema reset must run before pg_restore'
    assert_equal 'psql', reset.first
    assert_includes reset.join(' '), 'DROP SCHEMA IF EXISTS public CASCADE'
    assert_includes reset.join(' '), 'CREATE SCHEMA public'
    assert_equal :pg_restore, captured.last
  end

  def test_postgres_current_restore_raises_when_pg_restore_ignores_errors
    config = KamalBackup::Config.new(env: base_env(
      'DATABASE_ADAPTER' => 'postgres',
      'DATABASE_URL' => 'postgres://app:secret@db/app_production'
    ))
    adapter = KamalBackup::Databases::Postgres.new(config, redactor: redactor)

    fake_restic = Object.new
    fake_restic.define_singleton_method(:pipe_dump_to_command) do |_snapshot, _filename, _command|
      KamalBackup::CommandResult.new(
        stdout: '',
        stderr: "pg_restore: warning: errors ignored on restore: 19\n",
        status: 0
      )
    end

    error = nil
    KamalBackup::Command.stub(:capture, lambda { |_spec, **|
      KamalBackup::CommandResult.new(stdout: '', stderr: '', status: 0)
    }) do
      error = assert_raises(KamalBackup::CommandError) do
        adapter.restore_to_current(fake_restic, 'latest', 'dump.pgdump')
      end
    end

    assert_includes error.message, '19'
    assert_includes error.message, 'partially restored'
  end

  def test_postgres_scratch_restore_uses_the_requested_database
    config = KamalBackup::Config.new(env: base_env(
      'DATABASE_ADAPTER' => 'postgres',
      'DATABASE_URL' => 'postgres://app:secret@db/app_production'
    ))
    adapter = KamalBackup::Databases::Postgres.new(config, redactor: redactor)
    command = adapter.scratch_restore_command('app_restore_20260423')

    assert_includes command.argv, 'app_restore_20260423'
    assert_equal 'app_restore_20260423', command.env.fetch('PGDATABASE')
  end

  def test_postgres_scratch_restore_refuses_the_current_database
    config = KamalBackup::Config.new(env: base_env(
      'DATABASE_ADAPTER' => 'postgres',
      'DATABASE_URL' => 'postgres://app:secret@db/app'
    ))
    adapter = KamalBackup::Databases::Postgres.new(config, redactor: redactor)

    error = assert_raises(KamalBackup::ConfigurationError) do
      adapter.send(:validate_scratch_restore_target, 'app')
    end
    assert_match(/scratch database must differ/, error.message)
  end

  def test_mysql_dump_command_uses_transaction_safe_options_and_password_env
    config = KamalBackup::Config.new(env: base_env(
      'DATABASE_ADAPTER' => 'mysql',
      'DATABASE_URL' => 'mysql2://app:secret@mysql:3306/app_test',
      'MYSQL_DUMP_BIN' => 'mysqldump'
    ))
    adapter = KamalBackup::Databases::Mysql.new(config, redactor: redactor)
    command = adapter.dump_command

    assert_equal 'mysqldump', command.argv.first
    assert_includes command.argv, '--single-transaction'
    assert_includes command.argv, '--quick'
    assert_includes command.argv, '--routines'
    assert_includes command.argv, '--triggers'
    assert_includes command.argv, '--events'
    assert_includes command.argv, 'app_test'
    assert_equal({ 'MYSQL_PWD' => 'secret' }, command.env)
  end

  def test_mysql_current_restore_uses_current_database_url
    config = KamalBackup::Config.new(env: base_env(
      'DATABASE_ADAPTER' => 'mysql',
      'DATABASE_URL' => 'mysql2://app:secret@mysql:3306/app_development',
      'MYSQL_CLIENT_BIN' => 'mysql'
    ))
    adapter = KamalBackup::Databases::Mysql.new(config, redactor: redactor)
    command = adapter.current_restore_command

    assert_equal 'mysql', command.argv.first
    assert_includes command.argv, 'app_development'
    assert_equal({ 'MYSQL_PWD' => 'secret' }, command.env)
  end

  def test_mysql_scratch_restore_uses_the_requested_database
    config = KamalBackup::Config.new(env: base_env(
      'DATABASE_ADAPTER' => 'mysql',
      'DATABASE_URL' => 'mysql2://app:secret@mysql:3306/app_production',
      'MYSQL_CLIENT_BIN' => 'mysql'
    ))
    adapter = KamalBackup::Databases::Mysql.new(config, redactor: redactor)
    command = adapter.scratch_restore_command('app_restore_20260423')

    assert_equal 'mysql', command.argv.first
    assert_includes command.argv, 'app_restore_20260423'
    assert_equal({ 'MYSQL_PWD' => 'secret' }, command.env)
  end

  def test_mysql_scratch_restore_refuses_the_current_database
    config = KamalBackup::Config.new(env: base_env(
      'DATABASE_ADAPTER' => 'mysql',
      'DATABASE_URL' => 'mysql2://app:secret@mysql:3306/app_production',
      'MYSQL_CLIENT_BIN' => 'mysql'
    ))
    adapter = KamalBackup::Databases::Mysql.new(config, redactor: redactor)

    error = assert_raises(KamalBackup::ConfigurationError) do
      adapter.send(:validate_scratch_restore_target, 'app_production')
    end
    assert_match(/scratch database must differ/, error.message)
  end

  def test_sqlite_current_restore_uses_the_configured_database_path
    config = KamalBackup::Config.new(env: base_env(
      'DATABASE_ADAPTER' => 'sqlite',
      'SQLITE_DATABASE_PATH' => '/tmp/app_development.sqlite3'
    ))
    adapter = KamalBackup::Databases::Sqlite.new(config, redactor: redactor)

    assert_equal '/tmp/app_development.sqlite3', adapter.current_target_identifier
  end

  def test_sqlite_scratch_restore_refuses_the_current_database_path
    config = KamalBackup::Config.new(env: base_env(
      'DATABASE_ADAPTER' => 'sqlite',
      'SQLITE_DATABASE_PATH' => '/tmp/app_development.sqlite3'
    ))
    adapter = KamalBackup::Databases::Sqlite.new(config, redactor: redactor)

    error = assert_raises(KamalBackup::ConfigurationError) do
      adapter.send(:validate_scratch_restore_target, '/tmp/app_development.sqlite3')
    end
    assert_match(/scratch SQLite path must differ/, error.message)
  end

  def test_sqlite_literal_escapes_single_quotes
    config = KamalBackup::Config.new(env: base_env(
      'DATABASE_ADAPTER' => 'sqlite',
      'SQLITE_DATABASE_PATH' => '/tmp/app.sqlite3'
    ))
    adapter = KamalBackup::Databases::Sqlite.new(config, redactor: redactor)

    assert_equal "'/tmp/kamal''backup.sqlite3'", adapter.send(:sqlite_literal, "/tmp/kamal'backup.sqlite3")
  end

  def test_normalize_adapter_maps_aliases_to_canonical_names
    assert_equal 'postgres', KamalBackup::Databases.normalize_adapter('postgresql')
    assert_equal 'postgres', KamalBackup::Databases.normalize_adapter('Postgres')
    assert_equal 'mysql', KamalBackup::Databases.normalize_adapter('mysql2')
    assert_equal 'mysql', KamalBackup::Databases.normalize_adapter('mariadb')
    assert_equal 'sqlite', KamalBackup::Databases.normalize_adapter('sqlite3')
    assert_nil KamalBackup::Databases.normalize_adapter('oracle')
  end

  AdapterOnlyConfig = Struct.new(:database_adapter)

  def test_build_dispatches_to_the_adapter_class
    assert_instance_of KamalBackup::Databases::Postgres,
                       KamalBackup::Databases::Base.build(AdapterOnlyConfig.new('postgres'), redactor: redactor)
    assert_instance_of KamalBackup::Databases::Mysql,
                       KamalBackup::Databases::Base.build(AdapterOnlyConfig.new('mysql'), redactor: redactor)
    assert_instance_of KamalBackup::Databases::Sqlite,
                       KamalBackup::Databases::Base.build(AdapterOnlyConfig.new('sqlite'), redactor: redactor)
  end

  def test_build_raises_for_unsupported_adapters
    error = assert_raises(KamalBackup::ConfigurationError) do
      KamalBackup::Databases::Base.build(AdapterOnlyConfig.new('oracle'), redactor: redactor)
    end
    assert_match(/unsupported DATABASE_ADAPTER/, error.message)
  end

  def test_mysql_builds_the_connection_from_env_variables
    config = KamalBackup::Config.new(env: base_env(
      'DATABASE_ADAPTER' => 'mysql',
      'MYSQL_DATABASE' => 'app_production',
      'MYSQL_HOST' => 'db.internal',
      'MYSQL_PORT' => '3307',
      'MYSQL_USER' => 'app',
      'MYSQL_PASSWORD' => 'env-secret',
      'MYSQL_DUMP_BIN' => 'mysqldump'
    ))
    adapter = KamalBackup::Databases::Mysql.new(config, redactor: redactor)
    command = adapter.dump_command

    assert_equal 'app_production', command.argv.last
    assert_includes command.argv.each_cons(2).to_a, ['--host', 'db.internal']
    assert_includes command.argv.each_cons(2).to_a, ['--port', '3307']
    assert_includes command.argv.each_cons(2).to_a, ['--user', 'app']
    assert_equal({ 'MYSQL_PWD' => 'env-secret' }, command.env)
  end

  def test_mysql_falls_back_to_mariadb_env_variables
    config = KamalBackup::Config.new(env: base_env(
      'DATABASE_ADAPTER' => 'mysql',
      'MARIADB_DATABASE' => 'app_production',
      'MARIADB_HOST' => 'mariadb.internal',
      'MARIADB_USER' => 'app',
      'MARIADB_PASSWORD' => 'mariadb-secret',
      'MYSQL_DUMP_BIN' => 'mariadb-dump'
    ))
    adapter = KamalBackup::Databases::Mysql.new(config, redactor: redactor)
    command = adapter.dump_command

    assert_equal 'app_production', command.argv.last
    assert_includes command.argv.each_cons(2).to_a, ['--host', 'mariadb.internal']
    assert_equal({ 'MYSQL_PWD' => 'mariadb-secret' }, command.env)
  end

  def test_mysql_requires_a_database_name_without_a_url
    config = KamalBackup::Config.new(env: base_env('DATABASE_ADAPTER' => 'mysql'))
    adapter = KamalBackup::Databases::Mysql.new(config, redactor: redactor)

    error = assert_raises(KamalBackup::ConfigurationError) { adapter.dump_command }
    assert_match(/MYSQL_DATABASE or MARIADB_DATABASE is required/, error.message)
  end

  def test_mysql_requires_a_database_name_in_the_url
    config = KamalBackup::Config.new(env: base_env(
      'DATABASE_ADAPTER' => 'mysql',
      'DATABASE_URL' => 'mysql2://app:secret@mysql:3306/'
    ))
    adapter = KamalBackup::Databases::Mysql.new(config, redactor: redactor)

    error = assert_raises(KamalBackup::ConfigurationError) { adapter.dump_command }
    assert_match(/database name is missing/, error.message)
  end

  def test_mysql_rejects_an_unparseable_url
    config = KamalBackup::Config.new(env: base_env(
      'DATABASE_ADAPTER' => 'mysql',
      'DATABASE_URL' => 'mysql2://exa mple.com/app'
    ))
    adapter = KamalBackup::Databases::Mysql.new(config, redactor: redactor)

    error = assert_raises(KamalBackup::ConfigurationError) { adapter.dump_command }
    assert_match(/invalid database URL/, error.message)
  end

  def test_mysql_url_password_falls_back_to_env_password
    config = KamalBackup::Config.new(env: base_env(
      'DATABASE_ADAPTER' => 'mysql',
      'DATABASE_URL' => 'mysql2://app@mysql/app_production',
      'MYSQL_PASSWORD' => 'env-secret',
      'MYSQL_DUMP_BIN' => 'mysqldump'
    ))
    adapter = KamalBackup::Databases::Mysql.new(config, redactor: redactor)

    assert_equal({ 'MYSQL_PWD' => 'env-secret' }, adapter.dump_command.env)
  end

  def test_mysql_target_identifiers_include_the_host
    config = KamalBackup::Config.new(env: base_env(
      'DATABASE_ADAPTER' => 'mysql',
      'DATABASE_URL' => 'mysql2://app:secret@mysql/app_production'
    ))
    adapter = KamalBackup::Databases::Mysql.new(config, redactor: redactor)

    assert_equal 'mysql/app_production', adapter.current_target_identifier
    assert_equal 'mysql/app_scratch', adapter.scratch_target_identifier('app_scratch')
  end

  def test_postgres_builds_the_connection_from_env_variables
    config = KamalBackup::Config.new(env: base_env(
      'DATABASE_ADAPTER' => 'postgres',
      'PGDATABASE' => 'app_production',
      'PGHOST' => 'db.internal',
      'PGUSER' => 'app',
      'PGPASSWORD' => 'env-secret'
    ))
    adapter = KamalBackup::Databases::Postgres.new(config, redactor: redactor)
    command = adapter.current_restore_command

    assert_equal 'app_production', command.argv.last
    assert_equal 'db.internal', command.env.fetch('PGHOST')
    assert_equal 'env-secret', command.env.fetch('PGPASSWORD')
  end

  def test_postgres_requires_a_database_without_a_url
    config = KamalBackup::Config.new(env: base_env('DATABASE_ADAPTER' => 'postgres'))
    adapter = KamalBackup::Databases::Postgres.new(config, redactor: redactor)

    error = assert_raises(KamalBackup::ConfigurationError) { adapter.current_restore_command }
    assert_match(/DATABASE_URL or PGDATABASE is required/, error.message)
  end

  def test_postgres_rejects_non_postgres_url_schemes
    config = KamalBackup::Config.new(env: base_env(
      'DATABASE_ADAPTER' => 'postgres',
      'DATABASE_URL' => 'mysql://app@db/app'
    ))
    adapter = KamalBackup::Databases::Postgres.new(config, redactor: redactor)

    error = assert_raises(KamalBackup::ConfigurationError) { adapter.dump_command }
    assert_match(%r{must use postgres:// or postgresql://}, error.message)
  end

  def test_postgres_requires_a_database_name_in_the_url
    config = KamalBackup::Config.new(env: base_env(
      'DATABASE_ADAPTER' => 'postgres',
      'DATABASE_URL' => 'postgres://app@db/'
    ))
    adapter = KamalBackup::Databases::Postgres.new(config, redactor: redactor)

    error = assert_raises(KamalBackup::ConfigurationError) { adapter.dump_command }
    assert_match(/database name is missing/, error.message)
  end

  def test_postgres_maps_url_query_params_to_pg_env
    config = KamalBackup::Config.new(env: base_env(
      'DATABASE_ADAPTER' => 'postgres',
      'DATABASE_URL' => 'postgres://app@db/app?sslmode=require&connect_timeout=5'
    ))
    adapter = KamalBackup::Databases::Postgres.new(config, redactor: redactor)
    env = adapter.dump_command.env

    assert_equal 'require', env.fetch('PGSSLMODE')
    assert_equal '5', env.fetch('PGCONNECT_TIMEOUT')
  end

  def test_mysql_prefers_mariadb_binaries_when_available
    config = KamalBackup::Config.new(env: base_env(
      'DATABASE_ADAPTER' => 'mysql',
      'DATABASE_URL' => 'mysql2://app:secret@mysql/app_production'
    ))
    adapter = KamalBackup::Databases::Mysql.new(config, redactor: redactor)

    KamalBackup::Command.stub(:available?, true) do
      assert_equal 'mariadb-dump', adapter.dump_command.argv.first
      assert_equal 'mariadb', adapter.current_restore_command.argv.first
    end

    KamalBackup::Command.stub(:available?, false) do
      assert_equal 'mysqldump', adapter.dump_command.argv.first
      assert_equal 'mysql', adapter.current_restore_command.argv.first
    end
  end

  def test_postgres_url_password_falls_back_to_pgpassword
    config = KamalBackup::Config.new(env: base_env(
      'DATABASE_ADAPTER' => 'postgres',
      'DATABASE_URL' => 'postgres://app@db/app',
      'PGPASSWORD' => 'env-secret'
    ))
    adapter = KamalBackup::Databases::Postgres.new(config, redactor: redactor)

    assert_equal 'env-secret', adapter.dump_command.env.fetch('PGPASSWORD')
  end
end
