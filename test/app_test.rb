require_relative "test_helper"
require "json"

class AppTest < Minitest::Test
  class FakeRestic
    attr_reader :backup_path_calls, :check_calls, :database_file_calls
    attr_reader :ensure_repository_calls, :forget_calls, :latest_snapshot_calls, :restore_snapshot_calls

    def initialize
      @backup_path_calls = []
      @check_calls = 0
      @database_file_calls = []
      @ensure_repository_calls = 0
      @forget_calls = 0
      @latest_snapshot_calls = []
      @restore_snapshot_calls = []
      @database_snapshot = "latest-database-snapshot"
      @files_snapshot = "latest-files-snapshot"
      @staged_files = {}
    end

    def ensure_repository
      @ensure_repository_calls += 1
    end

    def backup_paths(paths, tags:)
      @backup_path_calls << { paths: paths, tags: tags }
    end

    def forget_after_success
      @forget_calls += 1
    end

    def check
      @check_calls += 1
      KamalBackup::CommandResult.new(stdout: "checked", stderr: "", status: 0)
    end

    attr_writer :database_snapshot, :files_snapshot

    def latest_snapshot(tags:)
      @latest_snapshot_calls << tags

      if tags.include?("type:database")
        { "short_id" => @database_snapshot }
      else
        { "short_id" => @files_snapshot }
      end
    end

    def database_file(snapshot, adapter)
      @database_file_calls << { snapshot: snapshot, adapter: adapter }
      "database.dump"
    end

    def stage_file(snapshot, path, content)
      @staged_files[snapshot] ||= []
      @staged_files[snapshot] << { path: path, content: content }
    end

    def restore_snapshot(snapshot, target)
      @restore_snapshot_calls << { snapshot: snapshot, target: target }

      Array(@staged_files[snapshot]).each do |entry|
        path = File.join(target, entry.fetch(:path).sub(%r{\A/+}, ""))
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, entry.fetch(:content))
      end
    end
  end

  class FakeDatabase
    attr_reader :backup_calls, :current_restore_calls, :scratch_restore_calls

    def initialize(adapter_name: "sqlite", current_target_identifier: nil)
      @adapter_name = adapter_name
      @current_target_identifier = current_target_identifier || default_current_target_identifier(adapter_name)
      @backup_calls = []
      @current_restore_calls = []
      @scratch_restore_calls = []
    end

    def adapter_name
      @adapter_name
    end

    def backup(restic, timestamp)
      @backup_calls << { restic: restic, timestamp: timestamp }
    end

    def restore_to_current(restic, snapshot, filename)
      @current_restore_calls << { restic: restic, snapshot: snapshot, filename: filename }
    end

    def restore_to_scratch(restic, snapshot, filename, target:)
      @scratch_restore_calls << { restic: restic, snapshot: snapshot, filename: filename, target: target }
    end

    def current_target_identifier
      @current_target_identifier
    end

    def scratch_target_identifier(target)
      case adapter_name
      when "sqlite"
        target
      else
        "db/#{target}"
      end
    end

    private
      def default_current_target_identifier(adapter_name)
        case adapter_name
        when "sqlite"
          "/tmp/app_development.sqlite3"
        when "mysql"
          "mysql/app_production"
        else
          "db/app_production"
        end
      end
  end

  def test_backup_creates_one_file_snapshot_for_all_paths
    Dir.mktmpdir do |dir|
      db = File.join(dir, "app.sqlite3")
      first_path = File.join(dir, "storage")
      second_path = File.join(dir, "uploads")
      File.write(db, "")
      FileUtils.mkdir_p(first_path)
      FileUtils.mkdir_p(second_path)
      restic = FakeRestic.new
      database = FakeDatabase.new

      app = KamalBackup::App.new(
        env: base_env(
          "DATABASE_ADAPTER" => "sqlite",
          "SQLITE_DATABASE_PATH" => db,
          "BACKUP_PATHS" => "#{first_path}:#{second_path}"
        ),
        restic: restic,
        database: database
      )

      app.backup

      assert_equal 1, restic.ensure_repository_calls
      assert_equal 1, database.backup_calls.size
      assert_equal 1, restic.backup_path_calls.size
      assert_equal [first_path, second_path], restic.backup_path_calls.first.fetch(:paths)
      assert_includes restic.backup_path_calls.first.fetch(:tags), "type:files"
      assert restic.backup_path_calls.first.fetch(:tags).any? { |tag| tag.start_with?("run:") }
      assert_equal 1, restic.forget_calls
    end
  end

  def test_backup_can_skip_forget_for_append_only_repositories
    Dir.mktmpdir do |dir|
      db = File.join(dir, "app.sqlite3")
      files = File.join(dir, "storage")
      File.write(db, "")
      FileUtils.mkdir_p(files)
      restic = FakeRestic.new

      app = KamalBackup::App.new(
        env: base_env(
          "DATABASE_ADAPTER" => "sqlite",
          "SQLITE_DATABASE_PATH" => db,
          "BACKUP_PATHS" => files,
          "RESTIC_FORGET_AFTER_BACKUP" => "false"
        ),
        restic: restic,
        database: FakeDatabase.new
      )

      app.backup

      assert_equal 0, restic.forget_calls
    end
  end

  def test_backup_can_run_restic_check_after_success
    Dir.mktmpdir do |dir|
      db = File.join(dir, "app.sqlite3")
      files = File.join(dir, "storage")
      File.write(db, "")
      FileUtils.mkdir_p(files)
      restic = FakeRestic.new

      app = KamalBackup::App.new(
        env: base_env(
          "DATABASE_ADAPTER" => "sqlite",
          "SQLITE_DATABASE_PATH" => db,
          "BACKUP_PATHS" => files,
          "RESTIC_CHECK_AFTER_BACKUP" => "true"
        ),
        restic: restic,
        database: FakeDatabase.new
      )

      app.backup

      assert_equal 1, restic.check_calls
    end
  end

  def test_restore_to_local_machine_restores_database_and_replaces_backup_paths
    Dir.mktmpdir do |dir|
      db = File.join(dir, "app_development.sqlite3")
      source_files = "/data/storage"
      files = File.join(dir, "storage")
      old_file = File.join(files, "old.txt")
      File.write(db, "")
      FileUtils.mkdir_p(files)
      File.write(old_file, "stale")

      restic = FakeRestic.new
      restic.stage_file("latest-files-snapshot", File.join(source_files, "hello.txt"), "hello from backup")
      database = FakeDatabase.new(adapter_name: "sqlite", current_target_identifier: db)

      app = KamalBackup::App.new(
        env: base_env(
          "DATABASE_ADAPTER" => "sqlite",
          "SQLITE_DATABASE_PATH" => db,
          "BACKUP_PATHS" => files,
          "LOCAL_RESTORE_SOURCE_PATHS" => source_files
        ),
        restic: restic,
        database: database
      )

      result = app.restore_to_local_machine("latest")

      assert_equal [%w[type:database adapter:sqlite], %w[type:files]], restic.latest_snapshot_calls
      assert_equal [{ snapshot: "latest-database-snapshot", adapter: "sqlite" }], restic.database_file_calls
      assert_equal 1, database.current_restore_calls.size
      assert_equal "latest-database-snapshot", database.current_restore_calls.first.fetch(:snapshot)
      assert_equal 1, restic.restore_snapshot_calls.size
      assert_equal "latest-files-snapshot", restic.restore_snapshot_calls.first.fetch(:snapshot)
      refute_equal File.expand_path(files), restic.restore_snapshot_calls.first.fetch(:target)
      assert_equal 1, result.fetch(:schema_version)
      assert_equal "restore_result", result.fetch(:kind)
      assert_equal "local", result.fetch(:scope)
      assert_equal "hello from backup", File.read(File.join(files, "hello.txt"))
      refute File.exist?(old_file)
    end
  end

  def test_restore_to_production_replaces_live_paths
    Dir.mktmpdir do |dir|
      db = File.join(dir, "app_production.sqlite3")
      files = File.join(dir, "storage")
      old_file = File.join(files, "old.txt")
      File.write(db, "")
      FileUtils.mkdir_p(files)
      File.write(old_file, "stale")

      restic = FakeRestic.new
      restic.stage_file("latest-files-snapshot", File.join(files, "hello.txt"), "hello from production backup")
      database = FakeDatabase.new(adapter_name: "sqlite", current_target_identifier: db)

      app = KamalBackup::App.new(
        env: base_env(
          "DATABASE_ADAPTER" => "sqlite",
          "SQLITE_DATABASE_PATH" => db,
          "BACKUP_PATHS" => files
        ),
        restic: restic,
        database: database
      )

      result = app.restore_to_production("latest")

      assert_equal 1, result.fetch(:schema_version)
      assert_equal "restore_result", result.fetch(:kind)
      assert_equal "production", result.fetch(:scope)
      assert_equal 1, database.current_restore_calls.size
      assert_equal "hello from production backup", File.read(File.join(files, "hello.txt"))
      refute File.exist?(old_file)
    end
  end

  def test_drill_on_production_restores_scratch_targets_and_records_success
    Dir.mktmpdir do |dir|
      target = File.join(dir, "restored-files")
      state = File.join(dir, "state")
      restic = FakeRestic.new
      database = FakeDatabase.new(adapter_name: "postgres")

      app = KamalBackup::App.new(
        env: base_env(
          "DATABASE_ADAPTER" => "postgres",
          "DATABASE_URL" => "postgres://app@db/app_production",
          "KAMAL_BACKUP_STATE_DIR" => state
        ),
        restic: restic,
        database: database
      )

      result = app.drill_on_production(
        "latest",
        database_name: "app_restore_20260423",
        file_target: target,
        check_command: "printf verified"
      )

      assert_equal "ok", result.fetch(:status)
      assert_equal 1, result.fetch(:schema_version)
      assert_equal "drill_result", result.fetch(:kind)
      assert_equal "production", result.fetch(:scope)
      assert_equal "latest-database-snapshot", result.fetch(:database).fetch(:snapshot)
      assert_equal "postgres", result.fetch(:database).fetch(:adapter)
      assert_equal File.expand_path(target), result.fetch(:files).fetch(:target)
      assert_equal "ok", result.fetch(:check).fetch(:status)
      assert_equal "verified", result.fetch(:check).fetch(:output)
      assert_equal 1, database.scratch_restore_calls.size
      assert_equal "app_restore_20260423", database.scratch_restore_calls.first.fetch(:target)
      assert File.file?(File.join(state, "last_restore_drill.json"))
    end
  end

  def test_drill_on_local_machine_marks_failed_checks_and_persists_the_result
    Dir.mktmpdir do |dir|
      db = File.join(dir, "app_development.sqlite3")
      source_files = "/data/storage"
      files = File.join(dir, "storage")
      state = File.join(dir, "state")
      File.write(db, "")
      FileUtils.mkdir_p(files)

      restic = FakeRestic.new
      restic.stage_file("latest-files-snapshot", File.join(source_files, "hello.txt"), "hello from backup")
      database = FakeDatabase.new(adapter_name: "sqlite", current_target_identifier: db)

      app = KamalBackup::App.new(
        env: base_env(
          "DATABASE_ADAPTER" => "sqlite",
          "SQLITE_DATABASE_PATH" => db,
          "BACKUP_PATHS" => files,
          "LOCAL_RESTORE_SOURCE_PATHS" => source_files,
          "KAMAL_BACKUP_STATE_DIR" => state
        ),
        restic: restic,
        database: database
      )

      result = app.drill_on_local_machine("latest", check_command: "exit 1")
      persisted = JSON.parse(File.read(File.join(state, "last_restore_drill.json")))

      assert_equal "failed", result.fetch(:status)
      assert_equal 1, result.fetch(:schema_version)
      assert_equal "drill_result", result.fetch(:kind)
      assert_equal "local", result.fetch(:scope)
      assert_equal "failed", result.fetch(:check).fetch(:status)
      assert_includes result.fetch(:error), "command failed"
      assert_equal "failed", persisted.fetch("status")
      assert_equal "failed", persisted.fetch("check").fetch("status")
    end
  end

  def test_restore_to_local_machine_reports_missing_restic_before_running
    Dir.mktmpdir do |dir|
      db = File.join(dir, "app_development.sqlite3")
      files = File.join(dir, "storage")
      File.write(db, "")
      FileUtils.mkdir_p(files)

      app = KamalBackup::App.new(
        env: base_env(
          "DATABASE_ADAPTER" => "sqlite",
          "SQLITE_DATABASE_PATH" => db,
          "BACKUP_PATHS" => files
        ),
        database: FakeDatabase.new(adapter_name: "sqlite", current_target_identifier: db)
      )

      app.define_singleton_method(:require_restic!) do
        raise KamalBackup::ConfigurationError,
          "restic is required on PATH for commands that run on this machine. Install restic locally and try again."
      end

      error = assert_raises(KamalBackup::ConfigurationError) do
        app.restore_to_local_machine("latest")
      end

      assert_includes error.message, "restic is required on PATH"
    end
  end
end
