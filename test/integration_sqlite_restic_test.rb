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

  def test_restore_local_from_an_older_file_snapshot_id_restores_the_matching_database
    skip 'set KAMAL_BACKUP_RUN_INTEGRATION=1 to run restic integration tests' unless ENV['KAMAL_BACKUP_RUN_INTEGRATION'] == '1'
    skip 'sqlite3 is required' unless system('which', 'sqlite3', out: File::NULL)
    skip 'restic is required' unless system('which', 'restic', out: File::NULL)

    Dir.mktmpdir do |dir|
      db = File.join(dir, 'app_development.sqlite3')
      files = File.join(dir, 'storage')
      FileUtils.mkdir_p(files)
      File.write(File.join(files, 'hello.txt'), 'first files')
      system('sqlite3', db, "CREATE TABLE items (name text); INSERT INTO items VALUES ('first');", exception: true)

      env = base_env(
        'APP_NAME' => 'integration',
        'DATABASE_ADAPTER' => 'sqlite',
        'SQLITE_DATABASE_PATH' => db,
        'BACKUP_PATHS' => files,
        'RESTIC_REPOSITORY' => File.join(dir, 'repo'),
        'RESTIC_PASSWORD' => 'integration-secret',
        'RESTIC_INIT_IF_MISSING' => 'true',
        'KAMAL_BACKUP_STATE_DIR' => File.join(dir, 'state')
      )

      first_files_snapshot = KamalBackup::App.new(env: env).backup(force: true).fetch(:files).fetch(:snapshot)

      system('sqlite3', db, "UPDATE items SET name = 'second';", exception: true)
      File.write(File.join(files, 'hello.txt'), 'second files')
      KamalBackup::App.new(env: env).backup(force: true)

      KamalBackup::App.new(env: env).restore_to_local_machine(first_files_snapshot)

      assert_equal 'first', `sqlite3 #{db} "select name from items"`.strip
      assert_equal 'first files', File.read(File.join(files, 'hello.txt'))
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

  def test_dump_downloads_sqlite_bytes_from_latest_and_an_older_files_snapshot
    skip 'set KAMAL_BACKUP_RUN_INTEGRATION=1 to run restic integration tests' unless ENV['KAMAL_BACKUP_RUN_INTEGRATION'] == '1'
    skip 'sqlite3 is required' unless system('which', 'sqlite3', out: File::NULL)
    skip 'restic is required' unless system('which', 'restic', out: File::NULL)

    Dir.mktmpdir do |dir|
      db = File.join(dir, 'app.sqlite3')
      files = File.join(dir, 'files')
      FileUtils.mkdir_p(files)
      File.write(File.join(files, 'hello.txt'), 'first')
      system(
        'sqlite3', db,
        "CREATE TABLE items (name text, payload blob); INSERT INTO items VALUES ('first', x'000102ff');",
        exception: true
      )
      env = base_env(
        'APP_NAME' => 'integration',
        'DATABASE_ADAPTER' => 'sqlite',
        'SQLITE_DATABASE_PATH' => db,
        'BACKUP_PATHS' => files,
        'RESTIC_REPOSITORY' => File.join(dir, 'repo'),
        'RESTIC_PASSWORD' => 'integration-secret',
        'RESTIC_INIT_IF_MISSING' => 'true',
        'KAMAL_BACKUP_STATE_DIR' => File.join(dir, 'state')
      )

      first_files_snapshot = KamalBackup::App.new(env: env).backup(force: true).fetch(:files).fetch(:snapshot)
      system('sqlite3', db, "UPDATE items SET name = 'second', payload = x'0a0b0c';", exception: true)
      KamalBackup::App.new(env: env).backup(force: true)
      FileUtils.rm_f(db)

      latest = File.join(dir, 'latest.sqlite3')
      older = File.join(dir, 'older.sqlite3')
      KamalBackup::App.new(env: env).dump_database(snapshot: 'latest', output_path: latest)
      KamalBackup::App.new(env: env).dump_database(snapshot: first_files_snapshot, output_path: older)

      assert_equal 'second', sqlite_scalar(latest, 'SELECT name FROM items')
      assert_equal '0A0B0C', sqlite_scalar(latest, 'SELECT hex(payload) FROM items')
      assert_equal 'first', sqlite_scalar(older, 'SELECT name FROM items')
      assert_equal '000102FF', sqlite_scalar(older, 'SELECT hex(payload) FROM items')
      refute_path_exists db
    end
  end

  def test_accessory_run_restic_dumps_mounted_yaml_and_a_failure_publishes_nothing
    skip 'set KAMAL_BACKUP_RUN_INTEGRATION=1 to run restic integration tests' unless ENV['KAMAL_BACKUP_RUN_INTEGRATION'] == '1'
    skip 'sqlite3 is required' unless system('which', 'sqlite3', out: File::NULL)
    skip 'restic is required' unless system('which', 'restic', out: File::NULL)

    Dir.mktmpdir do |dir|
      db = File.join(dir, 'app.sqlite3')
      repo = File.join(dir, 'repo')
      system(
        'sqlite3', db,
        "CREATE TABLE items (name text, payload blob); INSERT INTO items VALUES ('stored', x'000102ff');",
        exception: true
      )
      env = base_env(
        'APP_NAME' => 'integration',
        'DATABASE_ADAPTER' => 'sqlite',
        'SQLITE_DATABASE_PATH' => db,
        'BACKUP_PATHS' => '',
        'RESTIC_REPOSITORY' => repo,
        'RESTIC_PASSWORD' => 'integration-secret',
        'RESTIC_INIT_IF_MISSING' => 'true',
        'KAMAL_BACKUP_STATE_DIR' => File.join(dir, 'state')
      )
      app = KamalBackup::App.new(env: env)
      app.backup(force: true)
      located = app.locate_database_dump(snapshot: 'latest')
      FileUtils.rm_f(db)

      config_dir = File.join(dir, 'config')
      FileUtils.mkdir_p(config_dir)
      File.write(
        File.join(config_dir, 'kamal-backup.yml'),
        <<~YAML
          app: integration
          databases:
            - name: app
              adapter: sqlite
              path: #{db}
          restic:
            repository: #{repo}
            password: integration-secret
        YAML
      )
      published = File.join(dir, 'published.sqlite3')
      KamalBackup::App.new(env: env).dump_database(snapshot: 'latest', output_path: published)

      stdout, status = Open3.capture2(
        yaml_only_env,
        RbConfig.ruby, '-I', lib_dir, '-e', 'require "kamal_backup"; KamalBackup::CLI.start(ARGV)',
        'run-restic', '--', 'dump', located.fetch(:snapshot), located.fetch(:filename),
        chdir: dir
      )
      assert_equal true, status.success?, stdout
      stdout = stdout.dup.force_encoding(Encoding::ASCII_8BIT)
      assert_equal File.binread(published), stdout
      assert_equal '000102FF', sqlite_scalar(published, 'SELECT hex(payload) FROM items')

      _failed_out, failed_err, failed = Open3.capture3(
        yaml_only_env,
        RbConfig.ruby, '-I', lib_dir, '-e', 'require "kamal_backup"; KamalBackup::CLI.start(ARGV)',
        'run-restic', '--', 'dump', 'does-not-exist', located.fetch(:filename),
        chdir: dir
      )
      refute failed.success?
      refute_includes failed_err, 'integration-secret'

      partial = File.join(dir, 'partial.sqlite3')
      Dir.chdir(dir) do
        capture_io do
          error = assert_raises(SystemExit) do
            KamalBackup::CLI.start(['dump', 'does-not-exist', '-o', partial], env: env)
          end
          assert_equal 1, error.status
        end
      end
      refute_path_exists partial
      assert_empty Dir.glob("#{partial}*")
    end
  end

  def sqlite_scalar(db, sql)
    output, status = Open3.capture2('sqlite3', db, sql)
    flunk(output) unless status.success?

    output.strip
  end

  def lib_dir
    File.expand_path('../lib', __dir__)
  end

  def yaml_only_env
    ENV.to_h.merge(
      'RESTIC_REPOSITORY' => nil,
      'RESTIC_PASSWORD' => nil,
      'RESTIC_REPOSITORY_FILE' => nil,
      'RESTIC_PASSWORD_FILE' => nil,
      'RESTIC_PASSWORD_COMMAND' => nil
    )
  end
end
