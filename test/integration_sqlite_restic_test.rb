# frozen_string_literal: true

require_relative 'test_helper'
require 'open3'

class IntegrationSqliteResticTest < Minitest::Test
  def test_production_drill_restores_sqlite_and_files_into_scratch_targets
    skip 'set KAMAL_BACKUP_RUN_INTEGRATION=1 to run restic integration tests' unless ENV['KAMAL_BACKUP_RUN_INTEGRATION'] == '1'
    skip 'sqlite3 is required' unless system('which', 'sqlite3', out: File::NULL)
    skip 'restic is required' unless system('which', 'restic', out: File::NULL)

    Dir.mktmpdir do |dir|
      db = File.join(dir, 'app.sqlite3')
      files = File.join(dir, 'files')
      repo = File.join(dir, 'repo')
      state = File.join(dir, 'state')
      restored_db = File.join(dir, 'restore', 'restored.sqlite3')
      restored_files = File.join(dir, 'restored-files')
      FileUtils.mkdir_p(files)
      FileUtils.mkdir_p(File.dirname(restored_db))
      File.write(File.join(files, 'hello.txt'), 'hello from files')
      system('sqlite3', db,
             "PRAGMA journal_mode=WAL; CREATE TABLE items (name text); INSERT INTO items VALUES ('stored');",
             exception: true)
      system('sqlite3', restored_db,
             'PRAGMA journal_mode=WAL; CREATE TABLE target_only (id integer); INSERT INTO target_only VALUES (1);',
             exception: true)

      env = base_env(
        'APP_NAME' => 'integration',
        'DATABASE_ADAPTER' => 'sqlite',
        'SQLITE_DATABASE_PATH' => db,
        'BACKUP_PATHS' => files,
        'RESTIC_REPOSITORY' => repo,
        'RESTIC_PASSWORD' => 'integration-secret',
        'RESTIC_INIT_IF_MISSING' => 'true',
        'KAMAL_BACKUP_STATE_DIR' => state
      )

      KamalBackup::App.new(env: env).backup
      KamalBackup::App.new(env: env).drill_on_production('latest', sqlite_path: restored_db,
                                                                   file_target: restored_files)

      output = `sqlite3 #{restored_db} "select name from items"`
      assert_equal 'stored', output.strip
      assert_equal '0', `sqlite3 #{restored_db} "select count(*) from sqlite_master where name = 'target_only'"`.strip
      assert_equal 'ok', `sqlite3 #{restored_db} "pragma quick_check"`.strip
      restored_file_path = File.join(restored_files, files.sub(%r{\A/}, ''), 'hello.txt')
      assert_equal 'hello from files', File.read(restored_file_path)
    end
  end

  def test_restore_local_rewinds_the_current_sqlite_database_and_files
    skip 'set KAMAL_BACKUP_RUN_INTEGRATION=1 to run restic integration tests' unless ENV['KAMAL_BACKUP_RUN_INTEGRATION'] == '1'
    skip 'sqlite3 is required' unless system('which', 'sqlite3', out: File::NULL)
    skip 'restic is required' unless system('which', 'restic', out: File::NULL)

    Dir.mktmpdir do |dir|
      db = File.join(dir, 'app_development.sqlite3')
      files = File.join(dir, 'storage')
      repo = File.join(dir, 'repo')
      state = File.join(dir, 'state')
      FileUtils.mkdir_p(files)
      File.write(File.join(files, 'hello.txt'), 'hello from files')
      system('sqlite3', db, "CREATE TABLE items (name text); INSERT INTO items VALUES ('stored');", exception: true)

      env = base_env(
        'APP_NAME' => 'integration',
        'DATABASE_ADAPTER' => 'sqlite',
        'SQLITE_DATABASE_PATH' => db,
        'BACKUP_PATHS' => files,
        'RESTIC_REPOSITORY' => repo,
        'RESTIC_PASSWORD' => 'integration-secret',
        'RESTIC_INIT_IF_MISSING' => 'true',
        'KAMAL_BACKUP_STATE_DIR' => state
      )

      KamalBackup::App.new(env: env).backup

      system('sqlite3', db,
             "DELETE FROM items; INSERT INTO items VALUES ('changed'); CREATE TABLE target_only (id integer);",
             exception: true)
      File.write(File.join(files, 'hello.txt'), 'changed')

      KamalBackup::App.new(env: env).restore_to_local_machine('latest')

      output = `sqlite3 #{db} "select name from items"`
      assert_equal 'stored', output.strip
      assert_equal '0', `sqlite3 #{db} "select count(*) from sqlite_master where name = 'target_only'"`.strip
      assert_equal 'ok', `sqlite3 #{db} "pragma quick_check"`.strip
      assert_equal 'hello from files', File.read(File.join(files, 'hello.txt'))
    end
  end

  def test_current_sqlite_restore_fails_safely_while_a_writer_holds_the_database
    skip 'set KAMAL_BACKUP_RUN_INTEGRATION=1 to run restic integration tests' unless ENV['KAMAL_BACKUP_RUN_INTEGRATION'] == '1'
    skip 'sqlite3 is required' unless system('which', 'sqlite3', out: File::NULL)
    skip 'restic is required' unless system('which', 'restic', out: File::NULL)

    Dir.mktmpdir do |dir|
      db = File.join(dir, 'app_development.sqlite3')
      system('sqlite3', db,
             "PRAGMA journal_mode=WAL; CREATE TABLE items (name text); INSERT INTO items VALUES ('stored');",
             exception: true)
      env = base_env(
        'APP_NAME' => 'integration',
        'DATABASE_ADAPTER' => 'sqlite',
        'SQLITE_DATABASE_PATH' => db,
        'BACKUP_PATHS' => '',
        'RESTIC_REPOSITORY' => File.join(dir, 'repo'),
        'RESTIC_PASSWORD' => 'integration-secret',
        'RESTIC_INIT_IF_MISSING' => 'true',
        'KAMAL_BACKUP_STATE_DIR' => File.join(dir, 'state')
      )

      KamalBackup::App.new(env: env).backup
      system('sqlite3', db, "UPDATE items SET name = 'changed';", exception: true)

      Open3.popen3('sqlite3', db) do |stdin, stdout, _stderr, wait_thread|
        stdin.sync = true
        stdin.puts('BEGIN IMMEDIATE;')
        stdin.puts('.print writer-ready')
        assert_equal 'writer-ready', stdout.gets&.strip

        error = assert_raises(KamalBackup::CommandError) do
          KamalBackup::App.new(env: env).restore_to_local_machine('latest')
        end
        assert_match(/busy|locked/i, error.message)
        assert_equal 'changed', `sqlite3 #{db} "select name from items"`.strip
      ensure
        begin
          stdin.puts('ROLLBACK;')
          stdin.puts('.quit')
        rescue IOError, SystemCallError
          nil
        ensure
          stdin.close unless stdin.closed?
        end
        wait_thread.value
      end

      KamalBackup::App.new(env: env).restore_to_local_machine('latest')
      assert_equal 'stored', `sqlite3 #{db} "select name from items"`.strip
      assert_equal 'ok', `sqlite3 #{db} "pragma quick_check"`.strip
    end
  end

  def test_failed_database_dump_does_not_create_a_restic_snapshot
    skip 'set KAMAL_BACKUP_RUN_INTEGRATION=1 to run restic integration tests' unless ENV['KAMAL_BACKUP_RUN_INTEGRATION'] == '1'
    skip 'restic is required' unless system('which', 'restic', out: File::NULL)

    Dir.mktmpdir do |dir|
      config = KamalBackup::Config.new(
        env: base_env(
          'APP_NAME' => 'integration',
          'BACKUP_PATHS' => '',
          'RESTIC_REPOSITORY' => File.join(dir, 'repo'),
          'RESTIC_PASSWORD' => 'integration-secret',
          'RESTIC_INIT_IF_MISSING' => 'true'
        )
      )
      restic = KamalBackup::Restic.new(config, redactor: KamalBackup::Redactor.new(env: config.env))
      restic.ensure_repository
      dump_command = KamalBackup::CommandSpec.new(
        argv: ['sh', '-c', 'printf partial-data; echo dump-failed >&2; exit 3']
      )

      error = assert_raises(KamalBackup::CommandError) do
        restic.backup_stream(
          dump_command,
          filename: 'databases/integration/app/mysql.sql',
          tags: ['type:database', 'database:app', 'adapter:mysql']
        )
      end

      assert_includes error.message, 'dump-failed'
      assert_nil restic.latest_snapshot(tags: ['type:database', 'database:app', 'adapter:mysql'])
    end
  end
end
