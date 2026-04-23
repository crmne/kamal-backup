require_relative "test_helper"

class IntegrationSqliteResticTest < Minitest::Test
  def test_production_drill_restores_sqlite_and_files_into_scratch_targets
    skip "set KAMAL_BACKUP_RUN_INTEGRATION=1 to run restic integration tests" unless ENV["KAMAL_BACKUP_RUN_INTEGRATION"] == "1"
    skip "sqlite3 is required" unless system("which", "sqlite3", out: File::NULL)
    skip "restic is required" unless system("which", "restic", out: File::NULL)

    Dir.mktmpdir do |dir|
      db = File.join(dir, "app.sqlite3")
      files = File.join(dir, "files")
      repo = File.join(dir, "repo")
      state = File.join(dir, "state")
      restored_db = File.join(dir, "restore", "restored.sqlite3")
      restored_files = File.join(dir, "restored-files")
      FileUtils.mkdir_p(files)
      File.write(File.join(files, "hello.txt"), "hello from files")
      system("sqlite3", db, "CREATE TABLE items (name text); INSERT INTO items VALUES ('stored');", exception: true)

      env = base_env(
        "APP_NAME" => "integration",
        "DATABASE_ADAPTER" => "sqlite",
        "SQLITE_DATABASE_PATH" => db,
        "BACKUP_PATHS" => files,
        "RESTIC_REPOSITORY" => repo,
        "RESTIC_PASSWORD" => "integration-secret",
        "RESTIC_INIT_IF_MISSING" => "true",
        "KAMAL_BACKUP_STATE_DIR" => state
      )

      KamalBackup::App.new(env: env).backup
      KamalBackup::App.new(env: env).drill_on_production("latest", sqlite_path: restored_db, file_target: restored_files)

      output = `sqlite3 #{restored_db} "select name from items"`
      assert_equal "stored", output.strip
      restored_file_path = File.join(restored_files, files.sub(%r{\A/}, ""), "hello.txt")
      assert_equal "hello from files", File.read(restored_file_path)
    end
  end

  def test_restore_local_rewinds_the_current_sqlite_database_and_files
    skip "set KAMAL_BACKUP_RUN_INTEGRATION=1 to run restic integration tests" unless ENV["KAMAL_BACKUP_RUN_INTEGRATION"] == "1"
    skip "sqlite3 is required" unless system("which", "sqlite3", out: File::NULL)
    skip "restic is required" unless system("which", "restic", out: File::NULL)

    Dir.mktmpdir do |dir|
      db = File.join(dir, "app_development.sqlite3")
      files = File.join(dir, "storage")
      repo = File.join(dir, "repo")
      state = File.join(dir, "state")
      FileUtils.mkdir_p(files)
      File.write(File.join(files, "hello.txt"), "hello from files")
      system("sqlite3", db, "CREATE TABLE items (name text); INSERT INTO items VALUES ('stored');", exception: true)

      env = base_env(
        "APP_NAME" => "integration",
        "DATABASE_ADAPTER" => "sqlite",
        "SQLITE_DATABASE_PATH" => db,
        "BACKUP_PATHS" => files,
        "RESTIC_REPOSITORY" => repo,
        "RESTIC_PASSWORD" => "integration-secret",
        "RESTIC_INIT_IF_MISSING" => "true",
        "KAMAL_BACKUP_STATE_DIR" => state
      )

      KamalBackup::App.new(env: env).backup

      system("sqlite3", db, "DELETE FROM items; INSERT INTO items VALUES ('changed');", exception: true)
      File.write(File.join(files, "hello.txt"), "changed")

      KamalBackup::App.new(env: env).restore_to_local_machine("latest")

      output = `sqlite3 #{db} "select name from items"`
      assert_equal "stored", output.strip
      assert_equal "hello from files", File.read(File.join(files, "hello.txt"))
    end
  end
end
