# frozen_string_literal: true

require_relative 'test_helper'

class ConfigTest < Minitest::Test
  def test_detects_postgres_from_database_url
    config = KamalBackup::Config.new(env: base_env('DATABASE_URL' => 'postgres://app@db/app'))

    assert_equal 'postgres', config.database_adapter
  end

  def test_detects_mysql_from_mysql2_database_url
    config = KamalBackup::Config.new(env: base_env('DATABASE_URL' => 'mysql2://app@db/app'))

    assert_equal 'mysql', config.database_adapter
  end

  def test_detects_sqlite_from_path
    config = KamalBackup::Config.new(env: base_env('SQLITE_DATABASE_PATH' => '/data/db.sqlite3'))

    assert_equal 'sqlite', config.database_adapter
  end

  def test_parses_colon_and_newline_backup_paths
    config = KamalBackup::Config.new(env: base_env('BACKUP_PATHS' => "/data/storage:/data/uploads\n/data/other"))

    assert_equal ['/data/storage', '/data/uploads', '/data/other'], config.backup_paths
  end

  def test_loads_local_yaml_config_from_the_current_project
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, 'config')
      FileUtils.mkdir_p(config_dir)
      File.write(
        File.join(config_dir, 'kamal-backup.local.yml'),
        <<~YAML
          app: local-app
          databases:
            - name: app
              adapter: sqlite
              path: tmp/development.sqlite3
          paths:
            - storage
            - tmp/uploads
          restore_from:
            - /data/storage
            - /data/uploads
        YAML
      )

      config = KamalBackup::Config.new(env: { 'RESTIC_REPOSITORY' => '/tmp/restic', 'RESTIC_PASSWORD' => 'secret' },
                                       cwd: dir)

      assert_equal 'local-app', config.app_name
      assert_equal 'sqlite', config.database_adapter
      assert_equal 'tmp/development.sqlite3', config.databases.first.value('SQLITE_DATABASE_PATH')
      assert_equal ['storage', 'tmp/uploads'], config.backup_paths
      assert_equal ['/data/storage', '/data/uploads'], config.local_restore_source_paths
    end
  end

  def test_loads_restic_repository_and_password_sources_from_yaml
    Dir.mktmpdir do |dir|
      password_file = File.join(dir, 'restic-password')
      repository_file = File.join(dir, 'restic-repository')
      File.write(password_file, 'secret')
      File.write(repository_file, '/tmp/restic')
      config_dir = File.join(dir, 'config')
      FileUtils.mkdir_p(config_dir)
      File.write(
        File.join(config_dir, 'kamal-backup.yml'),
        <<~YAML
          app: file-app
          restic:
            repository_file: #{repository_file}
            password:
              file: #{password_file}
        YAML
      )

      config = KamalBackup::Config.new(env: {}, cwd: dir)

      assert_equal repository_file, config.restic_repository_file
      assert_equal password_file, config.restic_password_file
      config.validate_restic
    end
  end

  def test_restic_password_command_satisfies_password_validation
    config = KamalBackup::Config.new(env: {
                                       'APP_NAME' => 'test-app',
                                       'RESTIC_REPOSITORY' => '/tmp/restic-repo',
                                       'RESTIC_PASSWORD_COMMAND' => 'pass show restic/test-app'
                                     })

    config.validate_restic
  end

  def test_restic_validation_accepts_missing_remote_files_when_file_checks_are_disabled
    config = KamalBackup::Config.new(env: {
                                       'APP_NAME' => 'test-app',
                                       'RESTIC_REPOSITORY_FILE' => '/remote/restic-repository',
                                       'RESTIC_PASSWORD_FILE' => '/remote/restic-password'
                                     })

    config.validate_restic(check_files: false)
  end

  def test_restic_validation_rejects_missing_password_sources
    config = KamalBackup::Config.new(env: {
                                       'APP_NAME' => 'test-app',
                                       'RESTIC_REPOSITORY' => '/tmp/restic-repo'
                                     })

    error = assert_raises(KamalBackup::ConfigurationError) { config.validate_restic }
    assert_match(/RESTIC_PASSWORD, RESTIC_PASSWORD_FILE, or RESTIC_PASSWORD_COMMAND is required/, error.message)
  end

  def test_environment_overrides_local_yaml_config
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, 'config')
      FileUtils.mkdir_p(config_dir)
      File.write(
        File.join(config_dir, 'kamal-backup.local.yml'),
        <<~YAML
          app: file-app
        YAML
      )

      config = KamalBackup::Config.new(env: { 'APP_NAME' => 'env-app' }, cwd: dir)

      assert_equal 'env-app', config.app_name
    end
  end

  def test_infers_database_and_state_defaults_from_a_rails_postgres_app
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, 'config')
      FileUtils.mkdir_p(config_dir)
      File.write(
        File.join(config_dir, 'database.yml'),
        <<~YAML
          default: &default
            adapter: postgresql
            pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
            username: app

          development:
            <<: *default
            database: app_development
            host: localhost
            port: 5432
        YAML
      )
      File.write(
        File.join(config_dir, 'deploy.yml'),
        <<~YAML
          service: app
        YAML
      )

      config = KamalBackup::Config.new(env: { 'RESTIC_REPOSITORY' => '/tmp/restic', 'RESTIC_PASSWORD' => 'secret' },
                                       cwd: dir)

      assert_equal 'app', config.app_name
      assert_equal 'postgres', config.database_adapter
      assert_equal 'app', config.value('PGUSER')
      assert_equal 'app_development', config.value('PGDATABASE')
      assert_equal 'localhost', config.value('PGHOST')
      assert_empty config.backup_paths
      assert_equal File.join(dir, 'tmp', 'kamal-backup'), config.state_dir
    end
  end

  def test_infers_database_defaults_from_a_rails_sqlite_app
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, 'config')
      FileUtils.mkdir_p(config_dir)
      File.write(
        File.join(config_dir, 'database.yml'),
        <<~YAML
          development:
            adapter: sqlite3
            database: storage/development.sqlite3
        YAML
      )

      config = KamalBackup::Config.new(env: { 'RESTIC_REPOSITORY' => '/tmp/restic', 'RESTIC_PASSWORD' => 'secret' },
                                       cwd: dir)

      assert_equal 'sqlite', config.database_adapter
      assert_equal File.join(dir, 'storage', 'development.sqlite3'), config.value('SQLITE_DATABASE_PATH')
      assert_empty config.backup_paths
    end
  end

  def test_local_yaml_adds_explicit_paths_to_rails_defaults
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, 'config')
      FileUtils.mkdir_p(config_dir)
      File.write(
        File.join(config_dir, 'database.yml'),
        <<~YAML
          development:
            adapter: sqlite3
            database: storage/development.sqlite3
        YAML
      )
      File.write(
        File.join(config_dir, 'kamal-backup.local.yml'),
        <<~YAML
          databases:
            - name: app
              adapter: sqlite
              path: custom/dev.sqlite3
          paths:
            - uploads
        YAML
      )

      config = KamalBackup::Config.new(env: { 'RESTIC_REPOSITORY' => '/tmp/restic', 'RESTIC_PASSWORD' => 'secret' },
                                       cwd: dir)

      assert_equal 'custom/dev.sqlite3', config.databases.first.value('SQLITE_DATABASE_PATH')
      assert_equal ['uploads'], config.backup_paths
    end
  end

  def test_loads_grouped_yaml_config_with_secret_references_and_durations
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, 'config')
      FileUtils.mkdir_p(config_dir)
      File.write(
        File.join(config_dir, 'kamal-backup.yml'),
        <<~YAML
          app: grouped-app
          accessory: backup
          databases:
            - name: app
              adapter: postgres
              url: postgres://grouped@postgres:5432/grouped_production
              password:
                secret: APP_DATABASE_PASSWORD
            - name: queue
              adapter: postgres
              url:
                secret: QUEUE_DATABASE_URL
          paths:
            - /data/storage
          restic:
            repository: s3:https://s3.example.com/grouped
            password:
              secret: BACKUP_RESTIC_PASSWORD
            init_if_missing: true
            retention:
              keep_last: 3
          backup:
            schedule: 1d
          state:
            path: /state
        YAML
      )

      config = KamalBackup::Config.new(
        env: {
          'APP_DATABASE_PASSWORD' => 'app-secret',
          'QUEUE_DATABASE_URL' => 'postgres://queue:queue-secret@postgres:5432/queue_production',
          'BACKUP_RESTIC_PASSWORD' => 'restic-secret'
        },
        cwd: dir,
        load_project_defaults: false
      )

      assert_equal 'grouped-app', config.app_name
      assert_equal 'backup', config.accessory_name
      assert_equal %w[app queue], config.databases.map(&:database_name)
      assert_equal 'app-secret', config.databases.first.value('PGPASSWORD')
      assert_equal 'postgres://queue:queue-secret@postgres:5432/queue_production',
                   config.databases.last.value('DATABASE_URL')
      assert_equal ['/data/storage'], config.backup_paths
      assert_equal 's3:https://s3.example.com/grouped', config.restic_repository
      assert_equal 'restic-secret', config.restic_password
      assert_equal 86_400, config.backup_schedule_seconds
      assert_equal '/state', config.state_dir
      assert_includes config.retention_args, '3'
    end
  end

  def test_loads_yaml_backup_paths_with_excludes
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, 'config')
      FileUtils.mkdir_p(config_dir)
      File.write(
        File.join(config_dir, 'kamal-backup.yml'),
        <<~YAML
          app: excluded-files
          databases:
            - name: app
              adapter: postgres
              url: postgres://app@postgres:5432/app_production
          paths:
            - path: /rails/storage
              exclude:
                - /rails/storage/*.sqlite3
                - /rails/storage/*.sqlite3-wal
                - /rails/storage/*.sqlite3-shm
            - /rails/uploads
          restic:
            repository: /tmp/restic-repo
            password: restic-secret
        YAML
      )

      config = KamalBackup::Config.new(env: {}, cwd: dir, load_project_defaults: false)

      assert_equal ['/rails/storage', '/rails/uploads'], config.backup_paths
      assert_equal [
        '/rails/storage/*.sqlite3',
        '/rails/storage/*.sqlite3-wal',
        '/rails/storage/*.sqlite3-shm'
      ], config.backup_path_excludes(['/rails/storage'])
      assert_empty config.backup_path_excludes(['/rails/uploads'])
      config.validate_backup(check_files: false)
    end
  end

  def test_adds_sqlite_database_files_to_backup_path_excludes
    config = KamalBackup::Config.new(env: base_env(
      'DATABASE_ADAPTER' => 'sqlite',
      'SQLITE_DATABASE_PATH' => '/rails/storage/production.sqlite3',
      'BACKUP_PATHS' => '/rails/storage'
    ))

    assert_equal [
      '/rails/storage/production.sqlite3',
      '/rails/storage/production.sqlite3-wal',
      '/rails/storage/production.sqlite3-shm'
    ], config.backup_path_excludes
  end

  def test_does_not_add_sqlite_excludes_when_database_is_outside_backup_paths
    config = KamalBackup::Config.new(env: base_env(
      'DATABASE_ADAPTER' => 'sqlite',
      'SQLITE_DATABASE_PATH' => '/rails/db/production.sqlite3',
      'BACKUP_PATHS' => '/rails/storage'
    ))

    assert_empty config.backup_path_excludes
  end

  def test_loads_restic_rest_credentials_from_yaml
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, 'config')
      FileUtils.mkdir_p(config_dir)
      File.write(
        File.join(config_dir, 'kamal-backup.yml'),
        <<~YAML
          app: rest-app
          databases:
            - name: app
              adapter: sqlite
              path: /data/storage/production.sqlite3
          restic:
            repository: rest:https://backup.example.com/prod
            password: restic-secret
            rest:
              username:
                secret: RESTIC_REST_USER
              password:
                secret: RESTIC_REST_PASSWORD
        YAML
      )

      config = KamalBackup::Config.new(
        env: {
          'RESTIC_REST_USER' => 'backup',
          'RESTIC_REST_PASSWORD' => 'rest-server-secret'
        },
        cwd: dir,
        load_project_defaults: false
      )

      assert_equal 'rest:https://backup.example.com/prod', config.restic_repository
      assert_equal 'backup', config.value('RESTIC_REST_USERNAME')
      assert_equal 'rest-server-secret', config.value('RESTIC_REST_PASSWORD')
    end
  end

  def test_legacy_yaml_keys_are_rejected
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, 'config')
      FileUtils.mkdir_p(config_dir)
      File.write(
        File.join(config_dir, 'kamal-backup.yml'),
        <<~YAML
          app_name: old-app
        YAML
      )

      error = assert_raises(KamalBackup::ConfigurationError) do
        KamalBackup::Config.new(env: {}, cwd: dir, load_project_defaults: false)
      end

      assert_match(/legacy key app_name/, error.message)
    end
  end

  def test_validate_backup_rejects_missing_declared_database_secret
    Dir.mktmpdir do |dir|
      files = File.join(dir, 'storage')
      FileUtils.mkdir_p(files)
      config_dir = File.join(dir, 'config')
      FileUtils.mkdir_p(config_dir)
      File.write(
        File.join(config_dir, 'kamal-backup.yml'),
        <<~YAML
          app: missing-secret
          databases:
            - name: app
              adapter: postgres
              url: postgres://app@postgres:5432/app_production
              password:
                secret: APP_DATABASE_PASSWORD
          paths:
            - #{files}
          restic:
            repository: /tmp/restic-repo
            password: restic-secret
        YAML
      )

      config = KamalBackup::Config.new(env: {}, cwd: dir, load_project_defaults: false)

      error = assert_raises(KamalBackup::ConfigurationError) { config.validate_backup }
      assert_match(/APP_DATABASE_PASSWORD/, error.message)
    end
  end

  def test_empty_grouped_databases_do_not_fall_back_to_env_database_settings
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, 'config')
      FileUtils.mkdir_p(config_dir)
      File.write(
        File.join(config_dir, 'kamal-backup.yml'),
        <<~YAML
          app: empty-db
          databases: []
          restic:
            repository: /tmp/restic-repo
            password: restic-secret
        YAML
      )

      config = KamalBackup::Config.new(
        env: { 'DATABASE_URL' => 'postgres://app@db/app' },
        cwd: dir,
        load_project_defaults: false
      )

      assert_empty config.databases
      error = assert_raises(KamalBackup::ConfigurationError) { config.validate_backup }
      assert_match(/databases must contain at least one database/, error.message)
    end
  end

  def test_local_paths_still_use_production_restore_from_defaults
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, 'config')
      FileUtils.mkdir_p(config_dir)
      File.write(
        File.join(config_dir, 'kamal-backup.local.yml'),
        <<~YAML
          paths:
            - storage
        YAML
      )

      config = KamalBackup::Config.new(
        env: {},
        cwd: dir,
        defaults: { 'LOCAL_RESTORE_SOURCE_PATHS' => '/data/storage' },
        config_paths: [KamalBackup::Config::LOCAL_CONFIG_PATH],
        load_project_defaults: false
      )

      assert_equal ['storage'], config.backup_paths
      assert_equal ['/data/storage'], config.local_restore_source_paths
    end
  end

  def test_paths_reject_unknown_hash_entry_keys
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, 'config')
      FileUtils.mkdir_p(config_dir)
      File.write(
        File.join(config_dir, 'kamal-backup.yml'),
        <<~YAML
          app: bad-paths
          paths:
            - path: /data/storage
              excludes:
                - tmp
        YAML
      )

      error = assert_raises(KamalBackup::ConfigurationError) do
        KamalBackup::Config.new(env: {}, cwd: dir, load_project_defaults: false)
      end

      assert_match(/paths\[1\] contains unknown key "excludes"/, error.message)
    end
  end

  def test_paths_reject_invalid_exclude_shapes
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, 'config')
      FileUtils.mkdir_p(config_dir)
      File.write(
        File.join(config_dir, 'kamal-backup.yml'),
        <<~YAML
          app: bad-paths
          paths:
            - path: /data/storage
              exclude: /data/storage/*.sqlite3
        YAML
      )

      error = assert_raises(KamalBackup::ConfigurationError) do
        KamalBackup::Config.new(env: {}, cwd: dir, load_project_defaults: false)
      end

      assert_match(/paths\[1\]\.exclude must be a YAML sequence/, error.message)
    end
  end

  def test_paths_reject_entries_without_path
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, 'config')
      FileUtils.mkdir_p(config_dir)
      File.write(
        File.join(config_dir, 'kamal-backup.yml'),
        <<~YAML
          app: bad-paths
          paths:
            - exclude:
                - /data/storage/*.sqlite3
        YAML
      )

      error = assert_raises(KamalBackup::ConfigurationError) do
        KamalBackup::Config.new(env: {}, cwd: dir, load_project_defaults: false)
      end

      assert_match(/paths\[1\] path is required/, error.message)
    end
  end

  def test_refuses_suspicious_backup_path
    config = KamalBackup::Config.new(env: base_env('DATABASE_ADAPTER' => 'postgres',
                                                   'DATABASE_URL' => 'postgres://app@db/app', 'BACKUP_PATHS' => '/'))

    error = assert_raises(KamalBackup::ConfigurationError) { config.validate_backup_paths }
    assert_match(/refusing suspicious backup path/, error.message)
  end

  def test_validates_existing_backup_paths
    Dir.mktmpdir do |dir|
      config = KamalBackup::Config.new(env: base_env('BACKUP_PATHS' => dir))

      config.validate_backup_paths
    end
  end

  def test_remote_backup_validation_skips_local_path_existence_checks
    config = KamalBackup::Config.new(env: base_env(
      'DATABASE_ADAPTER' => 'sqlite',
      'SQLITE_DATABASE_PATH' => '/remote/db/production.sqlite3',
      'BACKUP_PATHS' => '/remote/storage'
    ))

    config.validate_backup(check_files: false)
  end

  def test_refuses_production_like_restore_target
    config = KamalBackup::Config.new(env: base_env)

    error = assert_raises(KamalBackup::ConfigurationError) do
      config.validate_database_restore_target('postgres://app@db/app_production')
    end
    assert_match(/production-looking/, error.message)
  end

  def test_production_restore_env_does_not_bypass_production_like_targets
    config = KamalBackup::Config.new(env: base_env('KAMAL_BACKUP_ALLOW_PRODUCTION_RESTORE' => 'true'))

    error = assert_raises(KamalBackup::ConfigurationError) do
      config.validate_database_restore_target('postgres://app@db/app_production')
    end

    assert_match(/production-looking/, error.message)
  end

  def test_local_machine_restore_does_not_require_a_restore_flag
    Dir.mktmpdir do |dir|
      config = KamalBackup::Config.new(env: base_env('BACKUP_PATHS' => dir))

      config.validate_local_machine_restore
    end
  end

  def test_local_machine_restore_refuses_production_environment_without_override
    config = KamalBackup::Config.new(env: base_env(
      'BACKUP_PATHS' => '/tmp/storage',
      'RAILS_ENV' => 'production'
    ))

    error = assert_raises(KamalBackup::ConfigurationError) { config.validate_local_machine_restore }
    assert_match(/restore local refuses to run with RAILS_ENV=production/, error.message)
  end

  def test_local_machine_restore_accepts_missing_target_paths
    config = KamalBackup::Config.new(env: base_env(
      'BACKUP_PATHS' => '/tmp/storage'
    ))

    config.validate_local_machine_restore
  end

  def test_rails_local_restore_requires_explicit_targets_for_production_file_paths
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, 'config')
      FileUtils.mkdir_p(config_dir)
      File.write(
        File.join(config_dir, 'database.yml'),
        <<~YAML
          development:
            adapter: postgresql
            database: app_development
        YAML
      )

      config = KamalBackup::Config.new(
        env: {},
        cwd: dir,
        defaults: { 'LOCAL_RESTORE_SOURCE_PATHS' => '/data/storage' },
        config_paths: [KamalBackup::Config::LOCAL_CONFIG_PATH]
      )

      assert_empty config.backup_paths
      error = assert_raises(KamalBackup::ConfigurationError) { config.validate_local_machine_restore }
      assert_match(/local file paths must be explicitly configured/, error.message)
    end
  end

  def test_local_machine_restore_source_paths_must_match_target_path_count
    config = KamalBackup::Config.new(env: base_env(
      'BACKUP_PATHS' => '/tmp/storage:/tmp/uploads',
      'LOCAL_RESTORE_SOURCE_PATHS' => '/data/storage'
    ))

    error = assert_raises(KamalBackup::ConfigurationError) { config.validate_local_machine_restore }
    assert_match(/local file paths must be explicitly configured and match the number of production restore source paths/,
                 error.message)
  end

  def test_retention_args_use_restic_flags
    config = KamalBackup::Config.new(env: base_env('RESTIC_KEEP_LAST' => '3', 'RESTIC_KEEP_DAILY' => '0'))

    assert_includes config.retention_args, '--keep-last'
    assert_includes config.retention_args, '3'
    refute_includes config.retention_args, '--keep-daily'
  end

  def test_forget_after_backup_defaults_to_true
    config = KamalBackup::Config.new(env: base_env)

    assert config.forget_after_backup?
  end

  def test_forget_after_backup_can_be_disabled
    config = KamalBackup::Config.new(env: base_env('RESTIC_FORGET_AFTER_BACKUP' => 'false'))

    refute config.forget_after_backup?
  end
end
