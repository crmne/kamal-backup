require_relative "test_helper"

class ConfigTest < Minitest::Test
  def test_detects_postgres_from_database_url
    config = KamalBackup::Config.new(env: base_env("DATABASE_URL" => "postgres://app@db/app"))

    assert_equal "postgres", config.database_adapter
  end

  def test_detects_mysql_from_mysql2_database_url
    config = KamalBackup::Config.new(env: base_env("DATABASE_URL" => "mysql2://app@db/app"))

    assert_equal "mysql", config.database_adapter
  end

  def test_detects_sqlite_from_path
    config = KamalBackup::Config.new(env: base_env("SQLITE_DATABASE_PATH" => "/data/db.sqlite3"))

    assert_equal "sqlite", config.database_adapter
  end

  def test_parses_colon_and_newline_backup_paths
    config = KamalBackup::Config.new(env: base_env("BACKUP_PATHS" => "/data/storage:/data/uploads\n/data/other"))

    assert_equal ["/data/storage", "/data/uploads", "/data/other"], config.backup_paths
  end

  def test_refuses_suspicious_backup_path
    config = KamalBackup::Config.new(env: base_env("DATABASE_ADAPTER" => "postgres", "DATABASE_URL" => "postgres://app@db/app", "BACKUP_PATHS" => "/"))

    error = assert_raises(KamalBackup::ConfigurationError) { config.validate_backup_paths! }
    assert_match(/refusing suspicious backup path/, error.message)
  end

  def test_validates_existing_backup_paths
    Dir.mktmpdir do |dir|
      config = KamalBackup::Config.new(env: base_env("BACKUP_PATHS" => dir))

      config.validate_backup_paths!
    end
  end

  def test_restore_requires_explicit_flag
    config = KamalBackup::Config.new(env: base_env)

    error = assert_raises(KamalBackup::ConfigurationError) { config.validate_restore_allowed! }
    assert_match(/KAMAL_BACKUP_ALLOW_RESTORE=true/, error.message)
  end

  def test_refuses_production_like_restore_target
    config = KamalBackup::Config.new(env: base_env)

    error = assert_raises(KamalBackup::ConfigurationError) do
      config.validate_database_restore_target!("postgres://app@db/app_production")
    end
    assert_match(/production-looking/, error.message)
  end

  def test_retention_args_use_restic_flags
    config = KamalBackup::Config.new(env: base_env("RESTIC_KEEP_LAST" => "3", "RESTIC_KEEP_DAILY" => "0"))

    assert_includes config.retention_args, "--keep-last"
    assert_includes config.retention_args, "3"
    refute_includes config.retention_args, "--keep-daily"
  end
end
