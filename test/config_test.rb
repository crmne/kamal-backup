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

  def test_loads_local_yaml_config_from_the_current_project
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, "config")
      FileUtils.mkdir_p(config_dir)
      File.write(
        File.join(config_dir, "kamal-backup.local.yml"),
        <<~YAML
          app_name: local-app
          database_adapter: sqlite
          sqlite_database_path: tmp/development.sqlite3
          backup_paths:
            - storage
            - tmp/uploads
          local_restore_source_paths:
            - /data/storage
            - /data/uploads
        YAML
      )

      config = KamalBackup::Config.new(env: { "RESTIC_REPOSITORY" => "/tmp/restic", "RESTIC_PASSWORD" => "secret" }, cwd: dir)

      assert_equal "local-app", config.app_name
      assert_equal "sqlite", config.database_adapter
      assert_equal "tmp/development.sqlite3", config.value("SQLITE_DATABASE_PATH")
      assert_equal ["storage", "tmp/uploads"], config.backup_paths
      assert_equal ["/data/storage", "/data/uploads"], config.local_restore_source_paths
    end
  end

  def test_environment_overrides_local_yaml_config
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, "config")
      FileUtils.mkdir_p(config_dir)
      File.write(
        File.join(config_dir, "kamal-backup.local.yml"),
        <<~YAML
          app_name: file-app
        YAML
      )

      config = KamalBackup::Config.new(env: { "APP_NAME" => "env-app" }, cwd: dir)

      assert_equal "env-app", config.app_name
    end
  end

  def test_refuses_suspicious_backup_path
    config = KamalBackup::Config.new(env: base_env("DATABASE_ADAPTER" => "postgres", "DATABASE_URL" => "postgres://app@db/app", "BACKUP_PATHS" => "/"))

    error = assert_raises(KamalBackup::ConfigurationError) { config.validate_backup_paths }
    assert_match(/refusing suspicious backup path/, error.message)
  end

  def test_validates_existing_backup_paths
    Dir.mktmpdir do |dir|
      config = KamalBackup::Config.new(env: base_env("BACKUP_PATHS" => dir))

      config.validate_backup_paths
    end
  end

  def test_refuses_production_like_restore_target
    config = KamalBackup::Config.new(env: base_env)

    error = assert_raises(KamalBackup::ConfigurationError) do
      config.validate_database_restore_target("postgres://app@db/app_production")
    end
    assert_match(/production-looking/, error.message)
  end

  def test_local_machine_restore_does_not_require_a_restore_flag
    Dir.mktmpdir do |dir|
      config = KamalBackup::Config.new(env: base_env("BACKUP_PATHS" => dir))

      config.validate_local_machine_restore
    end
  end

  def test_local_machine_restore_refuses_production_environment_without_override
    config = KamalBackup::Config.new(env: base_env(
      "BACKUP_PATHS" => "/tmp/storage",
      "RAILS_ENV" => "production"
    ))

    error = assert_raises(KamalBackup::ConfigurationError) { config.validate_local_machine_restore }
    assert_match(/restore local refuses to run with RAILS_ENV=production/, error.message)
  end

  def test_local_machine_restore_accepts_missing_target_paths
    config = KamalBackup::Config.new(env: base_env(
      "BACKUP_PATHS" => "/tmp/storage"
    ))

    config.validate_local_machine_restore
  end

  def test_local_machine_restore_source_paths_must_match_target_path_count
    config = KamalBackup::Config.new(env: base_env(
      "BACKUP_PATHS" => "/tmp/storage:/tmp/uploads",
      "LOCAL_RESTORE_SOURCE_PATHS" => "/data/storage"
    ))

    error = assert_raises(KamalBackup::ConfigurationError) { config.validate_local_machine_restore }
    assert_match(/LOCAL_RESTORE_SOURCE_PATHS must contain the same number of paths as BACKUP_PATHS/, error.message)
  end

  def test_retention_args_use_restic_flags
    config = KamalBackup::Config.new(env: base_env("RESTIC_KEEP_LAST" => "3", "RESTIC_KEEP_DAILY" => "0"))

    assert_includes config.retention_args, "--keep-last"
    assert_includes config.retention_args, "3"
    refute_includes config.retention_args, "--keep-daily"
  end

  def test_forget_after_backup_defaults_to_true
    config = KamalBackup::Config.new(env: base_env)

    assert config.forget_after_backup?
  end

  def test_forget_after_backup_can_be_disabled
    config = KamalBackup::Config.new(env: base_env("RESTIC_FORGET_AFTER_BACKUP" => "false"))

    refute config.forget_after_backup?
  end
end
