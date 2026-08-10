# frozen_string_literal: true

require_relative 'test_helper'
require 'json'

class AppTest < Minitest::Test
  class FakeRestic
    attr_reader :backup_path_calls, :check_calls, :database_file_calls, :ensure_repository_calls,
                :latest_snapshot_calls, :prune_calls, :restore_snapshot_calls, :unlock_calls

    def initialize
      @backup_path_calls = []
      @check_calls = 0
      @database_file_calls = []
      @ensure_repository_calls = 0
      @latest_snapshot_calls = []
      @prune_calls = 0
      @restore_snapshot_calls = []
      @unlock_calls = 0
      @database_snapshot = 'latest-database-snapshot'
      @files_snapshot = 'latest-files-snapshot'
      @snapshot_time = nil
      @staged_files = {}
    end

    def ensure_repository
      @ensure_repository_calls += 1
    end

    def backup_paths(paths, tags:)
      @backup_path_calls << { paths: paths, tags: tags }
    end

    def prune
      @prune_calls += 1
      [KamalBackup::CommandResult.new(stdout: "pruned\n", stderr: '', status: 0)]
    end

    def check
      @check_calls += 1
      KamalBackup::CommandResult.new(stdout: 'checked', stderr: '', status: 0)
    end

    def unlock
      @unlock_calls += 1
      KamalBackup::CommandResult.new(stdout: "unlocked\n", stderr: '', status: 0)
    end

    attr_writer :database_snapshot, :files_snapshot, :snapshot_time

    def latest_snapshot(tags:)
      @latest_snapshot_calls << tags
      snapshot_time = @snapshot_time || Time.now.utc.iso8601

      if tags.include?('type:database')
        { 'short_id' => @database_snapshot, 'time' => snapshot_time }
      elsif @files_snapshot
        { 'short_id' => @files_snapshot, 'time' => snapshot_time }
      end
    end

    def database_file(snapshot, adapter, database_name: nil)
      @database_file_calls << { snapshot: snapshot, adapter: adapter, database_name: database_name }
      'database.dump'
    end

    def stage_file(snapshot, path, content)
      @staged_files[snapshot] ||= []
      @staged_files[snapshot] << { path: path, content: content }
    end

    def restore_snapshot(snapshot, target)
      @restore_snapshot_calls << { snapshot: snapshot, target: target }

      Array(@staged_files[snapshot]).each do |entry|
        path = File.join(target, entry.fetch(:path).sub(%r{\A/+}, ''))
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, entry.fetch(:content))
      end
    end
  end

  class FakeDatabase
    attr_reader :backup_calls, :config, :current_restore_calls, :scratch_restore_calls, :adapter_name,
                :current_target_identifier

    def initialize(adapter_name: 'sqlite', current_target_identifier: nil, database_name: 'app')
      @adapter_name = adapter_name
      @current_target_identifier = current_target_identifier || default_current_target_identifier(adapter_name)
      @config = Struct.new(:database_name).new(database_name)
      @backup_calls = []
      @current_restore_calls = []
      @scratch_restore_calls = []
    end

    def backup(restic)
      @backup_calls << { restic: restic }
    end

    def restore_to_current(restic, snapshot, filename)
      @current_restore_calls << { restic: restic, snapshot: snapshot, filename: filename }
    end

    def restore_to_scratch(restic, snapshot, filename, target:)
      @scratch_restore_calls << { restic: restic, snapshot: snapshot, filename: filename, target: target }
    end

    def scratch_target_identifier(target)
      case adapter_name
      when 'sqlite'
        target
      else
        "db/#{target}"
      end
    end

    private

    def default_current_target_identifier(adapter_name)
      case adapter_name
      when 'sqlite'
        '/tmp/app_development.sqlite3'
      when 'mysql'
        'mysql/app_production'
      else
        'db/app_production'
      end
    end
  end

  def test_backup_creates_one_file_snapshot_for_all_paths
    Dir.mktmpdir do |dir|
      db = File.join(dir, 'app.sqlite3')
      first_path = File.join(dir, 'storage')
      second_path = File.join(dir, 'uploads')
      state = File.join(dir, 'state')
      File.write(db, '')
      FileUtils.mkdir_p(first_path)
      FileUtils.mkdir_p(second_path)
      restic = FakeRestic.new
      database = FakeDatabase.new

      app = KamalBackup::App.new(
        env: base_env(
          'DATABASE_ADAPTER' => 'sqlite',
          'SQLITE_DATABASE_PATH' => db,
          'BACKUP_PATHS' => "#{first_path}:#{second_path}",
          'KAMAL_BACKUP_STATE_DIR' => state
        ),
        restic: restic,
        database: database
      )

      result = app.backup

      assert_equal 1, restic.ensure_repository_calls
      assert_equal 1, database.backup_calls.size
      assert_equal 1, restic.backup_path_calls.size
      assert_equal [first_path, second_path], restic.backup_path_calls.first.fetch(:paths)
      assert_equal ['type:files'], restic.backup_path_calls.first.fetch(:tags)
      assert_equal 1, restic.prune_calls
      assert_equal 'backup_result', result.fetch(:kind)
      assert_equal 'latest-database-snapshot', result.fetch(:databases).first.fetch(:snapshot)
      assert_equal 'latest-files-snapshot', result.fetch(:files).fetch(:snapshot)
      assert_equal 'latest-files-snapshot',
                   JSON.parse(File.read(app.config.last_backup_path)).fetch('files').fetch('snapshot')
    end
  end

  def test_backup_skips_when_last_backup_is_not_due
    Dir.mktmpdir do |dir|
      db = File.join(dir, 'app.sqlite3')
      files = File.join(dir, 'storage')
      state = File.join(dir, 'state')
      File.write(db, '')
      FileUtils.mkdir_p(files)
      FileUtils.mkdir_p(state)
      File.write(
        File.join(state, 'last_backup.json'),
        JSON.pretty_generate(
          status: 'ok',
          finished_at: Time.now.utc.iso8601
        )
      )
      restic = FakeRestic.new
      database = FakeDatabase.new

      app = KamalBackup::App.new(
        env: base_env(
          'DATABASE_ADAPTER' => 'sqlite',
          'SQLITE_DATABASE_PATH' => db,
          'BACKUP_PATHS' => files,
          'KAMAL_BACKUP_STATE_DIR' => state,
          'BACKUP_SCHEDULE_SECONDS' => '86400'
        ),
        restic: restic,
        database: database
      )

      result = app.backup

      assert_equal 'skipped', result.fetch(:status)
      assert_equal 'not_due', result.fetch(:reason)
      assert_equal 'kamal-backup backup --force', result.fetch(:force_command)
      assert_equal 0, restic.ensure_repository_calls
      assert_equal 0, database.backup_calls.size
      assert_equal 0, restic.backup_path_calls.size
    end
  end

  def test_backup_skips_when_disabled
    Dir.mktmpdir do |dir|
      db = File.join(dir, 'app.sqlite3')
      files = File.join(dir, 'storage')
      state = File.join(dir, 'state')
      File.write(db, '')
      FileUtils.mkdir_p(files)
      FileUtils.mkdir_p(state)
      restic = FakeRestic.new
      database = FakeDatabase.new

      app = KamalBackup::App.new(
        env: base_env(
          'DATABASE_ADAPTER' => 'sqlite',
          'SQLITE_DATABASE_PATH' => db,
          'BACKUP_PATHS' => files,
          'KAMAL_BACKUP_STATE_DIR' => state,
          'BACKUP_ENABLED' => 'false'
        ),
        restic: restic,
        database: database
      )

      result = app.backup

      assert_equal 'skipped', result.fetch(:status)
      assert_equal 'disabled', result.fetch(:reason)
      assert_equal 0, restic.ensure_repository_calls
      assert_equal 0, database.backup_calls.size
      assert_equal 0, restic.backup_path_calls.size
    end
  end

  def test_backup_force_overrides_disabled
    Dir.mktmpdir do |dir|
      db = File.join(dir, 'app.sqlite3')
      files = File.join(dir, 'storage')
      state = File.join(dir, 'state')
      File.write(db, '')
      FileUtils.mkdir_p(files)
      FileUtils.mkdir_p(state)
      restic = FakeRestic.new
      database = FakeDatabase.new

      app = KamalBackup::App.new(
        env: base_env(
          'DATABASE_ADAPTER' => 'sqlite',
          'SQLITE_DATABASE_PATH' => db,
          'BACKUP_PATHS' => files,
          'KAMAL_BACKUP_STATE_DIR' => state,
          'BACKUP_ENABLED' => 'false'
        ),
        restic: restic,
        database: database
      )

      result = app.backup(force: true)

      assert_equal 'backup_result', result.fetch(:kind)
      assert_equal 1, database.backup_calls.size
    end
  end

  def test_backup_force_runs_even_when_last_backup_is_not_due
    Dir.mktmpdir do |dir|
      db = File.join(dir, 'app.sqlite3')
      files = File.join(dir, 'storage')
      state = File.join(dir, 'state')
      File.write(db, '')
      FileUtils.mkdir_p(files)
      FileUtils.mkdir_p(state)
      File.write(
        File.join(state, 'last_backup.json'),
        JSON.pretty_generate(
          status: 'ok',
          finished_at: Time.now.utc.iso8601
        )
      )
      restic = FakeRestic.new
      database = FakeDatabase.new

      app = KamalBackup::App.new(
        env: base_env(
          'DATABASE_ADAPTER' => 'sqlite',
          'SQLITE_DATABASE_PATH' => db,
          'BACKUP_PATHS' => files,
          'KAMAL_BACKUP_STATE_DIR' => state,
          'BACKUP_SCHEDULE_SECONDS' => '86400'
        ),
        restic: restic,
        database: database
      )

      result = app.backup(force: true)

      assert_equal 'ok', result.fetch(:status)
      assert_equal 1, restic.ensure_repository_calls
      assert_equal 1, database.backup_calls.size
      assert_equal 1, restic.backup_path_calls.size
    end
  end

  def test_backup_fails_when_fresh_snapshots_are_missing
    Dir.mktmpdir do |dir|
      db = File.join(dir, 'app.sqlite3')
      files = File.join(dir, 'storage')
      File.write(db, '')
      FileUtils.mkdir_p(files)
      restic = FakeRestic.new
      restic.snapshot_time = (Time.now.utc - 60).iso8601
      database = FakeDatabase.new

      app = KamalBackup::App.new(
        env: base_env(
          'DATABASE_ADAPTER' => 'sqlite',
          'SQLITE_DATABASE_PATH' => db,
          'BACKUP_PATHS' => files
        ),
        restic: restic,
        database: database
      )

      error = assert_raises(KamalBackup::ConfigurationError) { app.backup }

      assert_includes error.message, 'backup did not create a fresh database snapshot'
    end
  end

  def test_backup_can_skip_forget_for_append_only_repositories
    Dir.mktmpdir do |dir|
      db = File.join(dir, 'app.sqlite3')
      files = File.join(dir, 'storage')
      File.write(db, '')
      FileUtils.mkdir_p(files)
      restic = FakeRestic.new

      app = KamalBackup::App.new(
        env: base_env(
          'DATABASE_ADAPTER' => 'sqlite',
          'SQLITE_DATABASE_PATH' => db,
          'BACKUP_PATHS' => files,
          'RESTIC_FORGET_AFTER_BACKUP' => 'false'
        ),
        restic: restic,
        database: FakeDatabase.new
      )

      app.backup

      assert_equal 0, restic.prune_calls
    end
  end

  def test_backup_can_run_restic_check_after_success
    Dir.mktmpdir do |dir|
      db = File.join(dir, 'app.sqlite3')
      files = File.join(dir, 'storage')
      File.write(db, '')
      FileUtils.mkdir_p(files)
      restic = FakeRestic.new

      app = KamalBackup::App.new(
        env: base_env(
          'DATABASE_ADAPTER' => 'sqlite',
          'SQLITE_DATABASE_PATH' => db,
          'BACKUP_PATHS' => files,
          'RESTIC_CHECK_AFTER_BACKUP' => 'true'
        ),
        restic: restic,
        database: FakeDatabase.new
      )

      app.backup

      assert_equal 1, restic.check_calls
    end
  end

  def test_prune_applies_retention_without_requiring_paths_to_exist
    Dir.mktmpdir do |dir|
      restic = FakeRestic.new
      app = KamalBackup::App.new(
        env: base_env(
          'DATABASE_ADAPTER' => 'sqlite',
          'SQLITE_DATABASE_PATH' => File.join(dir, 'missing.sqlite3'),
          'BACKUP_PATHS' => File.join(dir, 'missing-storage')
        ),
        restic: restic,
        database: FakeDatabase.new
      )

      result = app.prune

      assert_equal 1, restic.prune_calls
      assert_equal "pruned\n", result.first.stdout
    end
  end

  def test_unlock_clears_stale_repository_locks
    Dir.mktmpdir do |dir|
      restic = FakeRestic.new
      app = KamalBackup::App.new(
        env: base_env(
          'DATABASE_ADAPTER' => 'sqlite',
          'SQLITE_DATABASE_PATH' => File.join(dir, 'missing.sqlite3'),
          'BACKUP_PATHS' => File.join(dir, 'missing-storage')
        ),
        restic: restic,
        database: FakeDatabase.new
      )

      result = app.unlock

      assert_equal 1, restic.unlock_calls
      assert_equal "unlocked\n", result
    end
  end

  def test_backup_runs_each_configured_database_and_file_group
    Dir.mktmpdir do |dir|
      storage = File.join(dir, 'storage')
      uploads = File.join(dir, 'uploads')
      FileUtils.mkdir_p(storage)
      FileUtils.mkdir_p(uploads)
      config_dir = File.join(dir, 'config')
      FileUtils.mkdir_p(config_dir)
      File.write(
        File.join(config_dir, 'kamal-backup.yml'),
        <<~YAML
          app: multi
          databases:
            - name: app
              adapter: postgres
              url: postgres://multi@postgres:5432/multi_production
            - name: queue
              adapter: postgres
              url: postgres://multi@postgres:5432/multi_queue_production
          paths:
            - #{storage}
            - #{uploads}
          restic:
            repository: /tmp/restic-repo
            password: restic-secret
        YAML
      )

      restic = FakeRestic.new
      app_database = FakeDatabase.new(adapter_name: 'postgres', database_name: 'app')
      queue_database = FakeDatabase.new(adapter_name: 'postgres', database_name: 'queue')
      app = KamalBackup::App.new(
        config: KamalBackup::Config.new(env: {}, cwd: dir, load_project_defaults: false),
        restic: restic,
        database: [app_database, queue_database]
      )

      app.backup

      assert_equal 1, app_database.backup_calls.size
      assert_equal 1, queue_database.backup_calls.size
      assert_equal 1, restic.backup_path_calls.size
      assert_equal [storage, uploads], restic.backup_path_calls.first.fetch(:paths)
      assert_includes restic.backup_path_calls.first.fetch(:tags), 'type:files'
    end
  end

  def test_restore_to_local_machine_restores_database_and_replaces_backup_paths
    Dir.mktmpdir do |dir|
      db = File.join(dir, 'app_development.sqlite3')
      source_files = '/data/storage'
      files = File.join(dir, 'storage')
      old_file = File.join(files, 'old.txt')
      File.write(db, '')
      FileUtils.mkdir_p(files)
      File.write(old_file, 'stale')

      restic = FakeRestic.new
      restic.stage_file('latest-files-snapshot', File.join(source_files, 'hello.txt'), 'hello from backup')
      database = FakeDatabase.new(adapter_name: 'sqlite', current_target_identifier: db)

      app = KamalBackup::App.new(
        env: base_env(
          'DATABASE_ADAPTER' => 'sqlite',
          'SQLITE_DATABASE_PATH' => db,
          'BACKUP_PATHS' => files,
          'LOCAL_RESTORE_SOURCE_PATHS' => source_files
        ),
        restic: restic,
        database: database
      )

      result = app.restore_to_local_machine('latest')

      assert_equal [['type:files'], ['type:database', 'database:app', 'adapter:sqlite']], restic.latest_snapshot_calls
      assert_equal [{ snapshot: 'latest-database-snapshot', adapter: 'sqlite', database_name: 'app' }],
                   restic.database_file_calls
      assert_equal 1, database.current_restore_calls.size
      assert_equal 'latest-database-snapshot', database.current_restore_calls.first.fetch(:snapshot)
      assert_equal 1, restic.restore_snapshot_calls.size
      assert_equal 'latest-files-snapshot', restic.restore_snapshot_calls.first.fetch(:snapshot)
      refute_equal File.expand_path(files), restic.restore_snapshot_calls.first.fetch(:target)
      assert_equal 1, result.fetch(:schema_version)
      assert_equal 'restore_result', result.fetch(:kind)
      assert_equal 'local', result.fetch(:scope)
      assert_equal 'hello from backup', File.read(File.join(files, 'hello.txt'))
      refute File.exist?(old_file)
    end
  end

  def test_restore_to_production_replaces_live_paths
    Dir.mktmpdir do |dir|
      db = File.join(dir, 'app_production.sqlite3')
      files = File.join(dir, 'storage')
      old_file = File.join(files, 'old.txt')
      File.write(db, '')
      FileUtils.mkdir_p(files)
      File.write(old_file, 'stale')
      target_identity = [File.stat(files).dev, File.stat(files).ino]

      restic = FakeRestic.new
      restic.stage_file('latest-files-snapshot', File.join(files, 'hello.txt'), 'hello from production backup')
      database = FakeDatabase.new(adapter_name: 'sqlite', current_target_identifier: db)

      app = KamalBackup::App.new(
        env: base_env(
          'DATABASE_ADAPTER' => 'sqlite',
          'SQLITE_DATABASE_PATH' => db,
          'BACKUP_PATHS' => files
        ),
        restic: restic,
        database: database
      )

      result = app.restore_to_production('latest')

      assert_equal 1, result.fetch(:schema_version)
      assert_equal 'restore_result', result.fetch(:kind)
      assert_equal 'production', result.fetch(:scope)
      assert_equal 1, database.current_restore_calls.size
      assert_equal 'hello from production backup', File.read(File.join(files, 'hello.txt'))
      refute File.exist?(old_file)
      assert_equal target_identity, [File.stat(files).dev, File.stat(files).ino]
    end
  end

  def test_restore_to_production_replaces_a_configured_file
    Dir.mktmpdir do |dir|
      db = File.join(dir, 'app_production.sqlite3')
      file = File.join(dir, 'manifest.json')
      File.write(db, '')
      File.write(file, 'stale')

      restic = FakeRestic.new
      restic.stage_file('latest-files-snapshot', file, 'restored')
      database = FakeDatabase.new(adapter_name: 'sqlite', current_target_identifier: db)
      app = KamalBackup::App.new(
        env: base_env(
          'DATABASE_ADAPTER' => 'sqlite',
          'SQLITE_DATABASE_PATH' => db,
          'BACKUP_PATHS' => file
        ),
        restic: restic,
        database: database
      )

      app.restore_to_production('latest')

      assert_equal 'restored', File.read(file)
      assert_equal 1, database.current_restore_calls.size
    end
  end

  def test_file_restore_reports_an_unwritable_file_target
    Dir.mktmpdir do |dir|
      target = File.join(dir, 'manifest.json')
      source_path = '/data/manifest.json'
      stage_dir = File.join(dir, 'stage')
      source = File.join(stage_dir, source_path.sub(%r{\A/+}, ''))
      FileUtils.mkdir_p(File.dirname(source))
      File.write(source, 'restored')
      File.write(target, 'stale')
      app = KamalBackup::App.new(env: base_env)

      error = FileUtils.stub(:remove_entry, ->(*) { raise Errno::EROFS, target }) do
        assert_raises(KamalBackup::ConfigurationError) do
          app.send(:replace_target_path, stage_dir, source_path, target)
        end
      end

      assert_includes error.message, 'target must be writable'
    end
  end

  def test_file_restore_preflight_reports_an_unwritable_directory_target
    Dir.mktmpdir do |dir|
      target = File.join(dir, 'storage')
      FileUtils.mkdir_p(target)
      app = KamalBackup::App.new(env: base_env)

      error = Dir.stub(:mktmpdir, ->(*) { raise Errno::EROFS, target }) do
        assert_raises(KamalBackup::ConfigurationError) do
          app.send(:ensure_writable_restore_target, target)
        end
      end

      assert_includes error.message, 'target must be writable'
    end
  end

  def test_restore_to_production_preserves_sqlite_database_inside_file_backup_path
    Dir.mktmpdir do |dir|
      files = File.join(dir, 'storage')
      db = File.join(files, 'app_production.sqlite3')
      FileUtils.mkdir_p(files)
      File.write(db, 'live')

      restic = FakeRestic.new
      restic.stage_file('latest-files-snapshot', File.join(files, 'hello.txt'), 'restored file')
      database = FakeDatabase.new(adapter_name: 'sqlite', current_target_identifier: db)
      database.define_singleton_method(:restore_to_current) do |_restic, _snapshot, _filename|
        FileUtils.mkdir_p(File.dirname(db))
        File.write(db, 'restored database')
      end

      app = KamalBackup::App.new(
        env: base_env(
          'DATABASE_ADAPTER' => 'sqlite',
          'SQLITE_DATABASE_PATH' => db,
          'BACKUP_PATHS' => files
        ),
        restic: restic,
        database: database
      )

      app.restore_to_production('latest')

      assert_equal 'restored database', File.read(db)
      assert_equal 'restored file', File.read(File.join(files, 'hello.txt'))
    end
  end

  def test_restore_to_local_machine_preserves_sqlite_database_inside_file_backup_path
    Dir.mktmpdir do |dir|
      source_files = '/data/storage'
      files = File.join(dir, 'storage')
      db = File.join(files, 'app_development.sqlite3')
      FileUtils.mkdir_p(files)
      File.write(db, 'live')

      restic = FakeRestic.new
      restic.stage_file('latest-files-snapshot', File.join(source_files, 'hello.txt'), 'restored file')
      database = FakeDatabase.new(adapter_name: 'sqlite', current_target_identifier: db)
      database.define_singleton_method(:restore_to_current) do |_restic, _snapshot, _filename|
        FileUtils.mkdir_p(File.dirname(db))
        File.write(db, 'restored database')
      end

      app = KamalBackup::App.new(
        env: base_env(
          'DATABASE_ADAPTER' => 'sqlite',
          'SQLITE_DATABASE_PATH' => db,
          'BACKUP_PATHS' => files,
          'LOCAL_RESTORE_SOURCE_PATHS' => source_files
        ),
        restic: restic,
        database: database
      )

      app.restore_to_local_machine('latest')

      assert_equal 'restored database', File.read(db)
      assert_equal 'restored file', File.read(File.join(files, 'hello.txt'))
    end
  end

  def test_drill_on_local_machine_preserves_sqlite_database_inside_file_backup_path
    Dir.mktmpdir do |dir|
      source_files = '/data/storage'
      files = File.join(dir, 'storage')
      db = File.join(files, 'app_development.sqlite3')
      state = File.join(dir, 'state')
      FileUtils.mkdir_p(files)
      File.write(db, 'live')

      restic = FakeRestic.new
      restic.stage_file('latest-files-snapshot', File.join(source_files, 'hello.txt'), 'restored file')
      database = FakeDatabase.new(adapter_name: 'sqlite', current_target_identifier: db)
      database.define_singleton_method(:restore_to_current) do |_restic, _snapshot, _filename|
        FileUtils.mkdir_p(File.dirname(db))
        File.write(db, 'restored database')
      end

      app = KamalBackup::App.new(
        env: base_env(
          'DATABASE_ADAPTER' => 'sqlite',
          'SQLITE_DATABASE_PATH' => db,
          'BACKUP_PATHS' => files,
          'LOCAL_RESTORE_SOURCE_PATHS' => source_files,
          'KAMAL_BACKUP_STATE_DIR' => state
        ),
        restic: restic,
        database: database
      )

      result = app.drill_on_local_machine('latest')

      assert_equal 'ok', result.fetch(:status)
      assert_equal 'restored database', File.read(db)
      assert_equal 'restored file', File.read(File.join(files, 'hello.txt'))
      assert_equal [['type:files'], ['type:database', 'database:app', 'adapter:sqlite']],
                   restic.latest_snapshot_calls
    end
  end

  def test_restore_to_local_machine_skips_file_restore_for_database_only_backups
    Dir.mktmpdir do |dir|
      db = File.join(dir, 'app_development.sqlite3')
      File.write(db, '')

      restic = FakeRestic.new
      restic.files_snapshot = nil
      database = FakeDatabase.new(adapter_name: 'sqlite', current_target_identifier: db)

      app = KamalBackup::App.new(
        env: base_env(
          'DATABASE_ADAPTER' => 'sqlite',
          'SQLITE_DATABASE_PATH' => db,
          'BACKUP_PATHS' => ''
        ),
        restic: restic,
        database: database
      )

      result = app.restore_to_local_machine('latest')

      assert_equal 1, database.current_restore_calls.size
      assert_equal 'latest-database-snapshot', database.current_restore_calls.first.fetch(:snapshot)
      assert_empty restic.restore_snapshot_calls
      assert_nil result.fetch(:files)
      assert_equal 'restore_result', result.fetch(:kind)
      assert_equal [['type:database', 'database:app', 'adapter:sqlite']], restic.latest_snapshot_calls
    end
  end

  def test_restore_to_production_skips_file_restore_for_database_only_backups
    Dir.mktmpdir do |dir|
      db = File.join(dir, 'app_production.sqlite3')
      File.write(db, '')

      restic = FakeRestic.new
      restic.files_snapshot = nil
      database = FakeDatabase.new(adapter_name: 'sqlite', current_target_identifier: db)

      app = KamalBackup::App.new(
        env: base_env(
          'DATABASE_ADAPTER' => 'sqlite',
          'SQLITE_DATABASE_PATH' => db,
          'BACKUP_PATHS' => ''
        ),
        restic: restic,
        database: database
      )

      result = app.restore_to_production('latest')

      assert_equal 1, database.current_restore_calls.size
      assert_empty restic.restore_snapshot_calls
      assert_nil result.fetch(:files)
      assert_equal 'production', result.fetch(:scope)
      assert_equal [['type:database', 'database:app', 'adapter:sqlite']], restic.latest_snapshot_calls
    end
  end

  def test_drill_on_local_machine_skips_file_restore_for_database_only_backups
    Dir.mktmpdir do |dir|
      db = File.join(dir, 'app_development.sqlite3')
      state = File.join(dir, 'state')
      File.write(db, '')

      restic = FakeRestic.new
      restic.files_snapshot = nil
      database = FakeDatabase.new(adapter_name: 'sqlite', current_target_identifier: db)

      app = KamalBackup::App.new(
        env: base_env(
          'DATABASE_ADAPTER' => 'sqlite',
          'SQLITE_DATABASE_PATH' => db,
          'BACKUP_PATHS' => '',
          'KAMAL_BACKUP_STATE_DIR' => state
        ),
        restic: restic,
        database: database
      )

      result = app.drill_on_local_machine('latest')

      assert_equal 'ok', result.fetch(:status)
      assert_equal 1, database.current_restore_calls.size
      assert_empty restic.restore_snapshot_calls
      assert_nil result.fetch(:files)
      assert_equal [['type:database', 'database:app', 'adapter:sqlite']], restic.latest_snapshot_calls
    end
  end

  def test_drill_on_production_skips_file_restore_for_database_only_backups
    Dir.mktmpdir do |dir|
      target = File.join(dir, 'restored-files')
      state = File.join(dir, 'state')
      restic = FakeRestic.new
      restic.files_snapshot = nil
      database = FakeDatabase.new(adapter_name: 'postgres')

      app = KamalBackup::App.new(
        env: base_env(
          'DATABASE_ADAPTER' => 'postgres',
          'DATABASE_URL' => 'postgres://app@db/app_production',
          'BACKUP_PATHS' => '',
          'KAMAL_BACKUP_STATE_DIR' => state
        ),
        restic: restic,
        database: database
      )

      result = app.drill_on_production(
        'latest',
        database_name: 'app_restore_20260711',
        file_target: target
      )

      assert_equal 'ok', result.fetch(:status)
      assert_equal 1, database.scratch_restore_calls.size
      assert_empty restic.restore_snapshot_calls
      assert_nil result.fetch(:files)
      assert_equal [['type:database', 'database:app', 'adapter:postgres']], restic.latest_snapshot_calls
    end
  end

  def test_restore_to_production_rejects_a_missing_file_snapshot_before_restoring_the_database
    Dir.mktmpdir do |dir|
      db = File.join(dir, 'app_production.sqlite3')
      files = File.join(dir, 'storage')
      File.write(db, '')
      FileUtils.mkdir_p(files)

      restic = FakeRestic.new
      restic.files_snapshot = nil
      database = FakeDatabase.new(adapter_name: 'sqlite', current_target_identifier: db)
      app = KamalBackup::App.new(
        env: base_env(
          'DATABASE_ADAPTER' => 'sqlite',
          'SQLITE_DATABASE_PATH' => db,
          'BACKUP_PATHS' => files
        ),
        restic: restic,
        database: database
      )

      error = assert_raises(KamalBackup::ConfigurationError) do
        app.restore_to_production('latest')
      end

      assert_includes error.message, 'no restic snapshot found for type:files'
      assert_empty database.current_restore_calls
    end
  end

  def test_drill_on_production_restores_scratch_targets_and_records_success
    Dir.mktmpdir do |dir|
      target = File.join(dir, 'restored-files')
      state = File.join(dir, 'state')
      restic = FakeRestic.new
      database = FakeDatabase.new(adapter_name: 'postgres')

      app = KamalBackup::App.new(
        env: base_env(
          'DATABASE_ADAPTER' => 'postgres',
          'DATABASE_URL' => 'postgres://app@db/app_production',
          'KAMAL_BACKUP_STATE_DIR' => state
        ),
        restic: restic,
        database: database
      )

      result = app.drill_on_production(
        'latest',
        database_name: 'app_restore_20260423',
        file_target: target,
        check_command: 'printf verified'
      )

      assert_equal 'ok', result.fetch(:status)
      assert_equal 1, result.fetch(:schema_version)
      assert_equal 'drill_result', result.fetch(:kind)
      assert_equal 'production', result.fetch(:scope)
      assert_equal 'latest-database-snapshot', result.fetch(:databases).first.fetch(:snapshot)
      assert_equal 'postgres', result.fetch(:databases).first.fetch(:adapter)
      assert_equal File.expand_path(target), result.fetch(:files).fetch(:target)
      assert_equal 'ok', result.fetch(:check).fetch(:status)
      assert_equal 'verified', result.fetch(:check).fetch(:output)
      assert_equal 1, database.scratch_restore_calls.size
      assert_equal 'app_restore_20260423', database.scratch_restore_calls.first.fetch(:target)
      assert File.file?(File.join(state, 'last_restore_drill.json'))
    end
  end

  def test_drill_on_local_machine_marks_failed_checks_and_persists_the_result
    Dir.mktmpdir do |dir|
      db = File.join(dir, 'app_development.sqlite3')
      source_files = '/data/storage'
      files = File.join(dir, 'storage')
      state = File.join(dir, 'state')
      File.write(db, '')
      FileUtils.mkdir_p(files)

      restic = FakeRestic.new
      restic.stage_file('latest-files-snapshot', File.join(source_files, 'hello.txt'), 'hello from backup')
      database = FakeDatabase.new(adapter_name: 'sqlite', current_target_identifier: db)

      app = KamalBackup::App.new(
        env: base_env(
          'DATABASE_ADAPTER' => 'sqlite',
          'SQLITE_DATABASE_PATH' => db,
          'BACKUP_PATHS' => files,
          'LOCAL_RESTORE_SOURCE_PATHS' => source_files,
          'KAMAL_BACKUP_STATE_DIR' => state
        ),
        restic: restic,
        database: database
      )

      result = app.drill_on_local_machine('latest', check_command: 'exit 1')
      persisted = JSON.parse(File.read(File.join(state, 'last_restore_drill.json')))

      assert_equal 'failed', result.fetch(:status)
      assert_equal 1, result.fetch(:schema_version)
      assert_equal 'drill_result', result.fetch(:kind)
      assert_equal 'local', result.fetch(:scope)
      assert_equal 'failed', result.fetch(:check).fetch(:status)
      assert_includes result.fetch(:error), 'command failed'
      assert_equal 'failed', persisted.fetch('status')
      assert_equal 'failed', persisted.fetch('check').fetch('status')
    end
  end

  def test_restore_to_local_machine_reports_missing_restic_before_running
    Dir.mktmpdir do |dir|
      db = File.join(dir, 'app_development.sqlite3')
      files = File.join(dir, 'storage')
      File.write(db, '')
      FileUtils.mkdir_p(files)

      app = KamalBackup::App.new(
        env: base_env(
          'DATABASE_ADAPTER' => 'sqlite',
          'SQLITE_DATABASE_PATH' => db,
          'BACKUP_PATHS' => files
        ),
        database: FakeDatabase.new(adapter_name: 'sqlite', current_target_identifier: db)
      )

      error = KamalBackup::Command.stub(:available?, false) do
        assert_raises(KamalBackup::ConfigurationError) do
          app.restore_to_local_machine('latest')
        end
      end

      assert_includes error.message, 'restic is required on PATH'
    end
  end
end
