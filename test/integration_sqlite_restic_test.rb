require_relative "test_helper"

class IntegrationSqliteResticTest < Minitest::Test
  def test_sqlite_and_file_backup_restore_with_local_restic_repository
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

      KamalBackup::CLI.new(env: env).backup
      KamalBackup::CLI.new(env: env.merge(
        "KAMAL_BACKUP_ALLOW_RESTORE" => "true",
        "RESTORE_SQLITE_DATABASE_PATH" => restored_db
      )).restore_db("latest")
      KamalBackup::CLI.new(env: env.merge("KAMAL_BACKUP_ALLOW_RESTORE" => "true")).restore_files("latest", restored_files)

      output = `sqlite3 #{restored_db} "select name from items"`
      assert_equal "stored", output.strip
      restored_file_path = File.join(restored_files, files.sub(%r{\A/}, ""), "hello.txt")
      assert_equal "hello from files", File.read(restored_file_path)
    end
  end
end
