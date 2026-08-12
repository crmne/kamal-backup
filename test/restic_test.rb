# frozen_string_literal: true

require_relative 'test_helper'

class ResticTest < Minitest::Test
  class FakeRestic < KamalBackup::Restic
    attr_reader :calls, :last_args

    def initialize(config, json)
      super(config, redactor: KamalBackup::Redactor.new(env: {}))
      @json = json
      @calls = []
    end

    def run(args, **)
      @last_args = args
      @calls << args
      KamalBackup::CommandResult.new(stdout: @json, stderr: '', status: 0)
    end

    private

    def log(_message); end
  end

  class CapturingBackupRestic < KamalBackup::Restic
    attr_reader :backup_args, :backup_env

    private

    def run(args, env:, **)
      @backup_args = args
      @backup_env = env
      KamalBackup::CommandResult.new(stdout: '', stderr: '', status: 0)
    end

    def log(_message); end
  end

  def test_snapshots_json_requires_all_requested_tags
    config = KamalBackup::Config.new(env: base_env('APP_NAME' => 'demo'))
    json = [
      { 'short_id' => 'db', 'tags' => ['kamal-backup', 'app:demo', 'type:database'] },
      { 'short_id' => 'files', 'tags' => ['kamal-backup', 'app:demo', 'type:files'] },
      { 'short_id' => 'other', 'tags' => ['kamal-backup', 'app:other', 'type:database'] }
    ].to_json
    restic = FakeRestic.new(config, json)

    snapshots = restic.snapshots_json(tags: ['kamal-backup', 'app:demo', 'type:database'])

    assert_equal(['db'], snapshots.map { |snapshot| snapshot['short_id'] })
  end

  def test_backup_paths_adds_each_path_label_as_a_tag_and_uses_stable_host
    config = KamalBackup::Config.new(env: base_env('APP_NAME' => 'demo'))
    restic = FakeRestic.new(config, '[]')

    restic.backup_paths(['/data/storage', '/data/uploads'], tags: ['type:files'])

    assert_equal ['backup', '--host', 'demo-backup', '/data/storage', '/data/uploads'], restic.last_args.first(5)
    assert_includes restic.last_args, '--tag'
    assert_includes restic.last_args, 'path:data-storage'
    assert_includes restic.last_args, 'path:data-uploads'
  end

  def test_backup_paths_passes_configured_excludes_to_restic
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, 'config')
      FileUtils.mkdir_p(config_dir)
      File.write(
        File.join(config_dir, 'kamal-backup.yml'),
        <<~YAML
          app: demo
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
          restic:
            repository: /tmp/restic-repo
            password: restic-secret
        YAML
      )
      config = KamalBackup::Config.new(env: {}, cwd: dir, load_project_defaults: false)
      restic = FakeRestic.new(config, '[]')

      restic.backup_paths(config.backup_paths, tags: ['type:files'])

      exclude_pairs = restic.last_args.each_cons(2).select { |flag, _pattern| flag == '--exclude' }
      assert_equal [
        ['--exclude', '/rails/storage/*.sqlite3'],
        ['--exclude', '/rails/storage/*.sqlite3-wal'],
        ['--exclude', '/rails/storage/*.sqlite3-shm']
      ], exclude_pairs
    end
  end

  def test_backup_paths_passes_automatic_sqlite_excludes_to_restic
    config = KamalBackup::Config.new(env: base_env(
      'APP_NAME' => 'demo',
      'DATABASE_ADAPTER' => 'sqlite',
      'SQLITE_DATABASE_PATH' => '/data/storage/production.sqlite3',
      'BACKUP_PATHS' => '/data/storage'
    ))
    restic = FakeRestic.new(config, '[]')

    restic.backup_paths(config.backup_paths, tags: ['type:files'])

    exclude_pairs = restic.last_args.each_cons(2).select { |flag, _pattern| flag == '--exclude' }
    assert_equal [
      ['--exclude', '/data/storage/production.sqlite3'],
      ['--exclude', '/data/storage/production.sqlite3-wal'],
      ['--exclude', '/data/storage/production.sqlite3-shm']
    ], exclude_pairs
  end

  def test_backup_stream_does_not_apply_file_backup_excludes
    config = KamalBackup::Config.new(env: base_env(
      'APP_NAME' => 'demo',
      'DATABASE_ADAPTER' => 'sqlite',
      'SQLITE_DATABASE_PATH' => '/data/storage/production.sqlite3',
      'BACKUP_PATHS' => '/data/storage'
    ))
    restic = CapturingBackupRestic.new(config, redactor: KamalBackup::Redactor.new(env: {}))
    dump_command = KamalBackup::CommandSpec.new(
      argv: ['sqlite3', '/data/storage/production.sqlite3', '.dump'],
      env: { 'DATABASE_SECRET' => 'secret' }
    )

    restic.backup_stream(dump_command, filename: 'databases/demo/app/sqlite.sqlite3', tags: ['type:database'])

    refute_includes restic.backup_args, '--exclude'
    assert_includes restic.backup_args, '--stdin-from-command'
    delimiter = restic.backup_args.index('--')
    assert_equal dump_command.argv, restic.backup_args.drop(delimiter + 1)
    assert_equal 'secret', restic.backup_env.fetch('DATABASE_SECRET')
    assert_equal 'restic-secret', restic.backup_env.fetch('RESTIC_PASSWORD')
  end

  def test_backup_file_reports_restic_stderr_when_stdin_pipe_closes
    Dir.mktmpdir do |dir|
      bin_dir = File.join(dir, 'bin')
      FileUtils.mkdir_p(bin_dir)
      fake_restic = File.join(bin_dir, 'restic')
      File.write(fake_restic, "#!/bin/sh\necho restic exploded >&2\nexit 12\n")
      FileUtils.chmod('+x', fake_restic)

      path = File.join(dir, 'large.sqlite3')
      File.binwrite(path, 'x' * (16 * 1024 * 1024))
      config = KamalBackup::Config.new(env: base_env('APP_NAME' => 'demo'))
      restic = KamalBackup::Restic.new(config, redactor: KamalBackup::Redactor.new(env: {}))
      previous_path = ENV['PATH']
      ENV['PATH'] = "#{bin_dir}#{File::PATH_SEPARATOR}#{previous_path}"

      error = assert_raises(KamalBackup::CommandError) do
        restic.backup_file(path, filename: 'databases/demo/app/sqlite.sqlite3', tags: ['type:database'])
      end

      assert_equal 12, error.status
      assert_includes error.stderr, 'restic exploded'
      assert_includes error.message, 'restic exploded'
    ensure
      ENV['PATH'] = previous_path if previous_path
    end
  end

  def test_database_file_finds_the_database_dump_path
    config = KamalBackup::Config.new(env: base_env('APP_NAME' => 'demo'))
    json = [
      { 'type' => 'dir', 'path' => '/databases/demo/app' },
      { 'type' => 'file', 'path' => '/databases/demo/queue/postgres.pgdump' },
      { 'type' => 'file', 'path' => '/databases/demo/app/postgres.pgdump' }
    ].map(&:to_json).join("\n")
    restic = FakeRestic.new(config, json)

    assert_equal '/databases/demo/app/postgres.pgdump',
                 restic.database_file('snapshot', 'postgres', database_name: 'app')
  end

  def test_database_file_falls_back_to_legacy_dump_layouts
    config = KamalBackup::Config.new(env: base_env('APP_NAME' => 'demo'))
    json = [
      { 'type' => 'file', 'path' => '/databases-demo-app-postgres-20260422T120000Z.pgdump' }
    ].map(&:to_json).join("\n")
    restic = FakeRestic.new(config, json)

    assert_equal '/databases-demo-app-postgres-20260422T120000Z.pgdump',
                 restic.database_file('snapshot', 'postgres', database_name: 'app')
  end

  def test_prune_groups_database_snapshots_by_host
    config = KamalBackup::Config.new(env: base_env(
      'APP_NAME' => 'demo',
      'DATABASE_ADAPTER' => 'sqlite',
      'SQLITE_DATABASE_PATH' => '/tmp/demo.sqlite3',
      'BACKUP_PATHS' => '',
      'RESTIC_KEEP_LAST' => '2'
    ))
    restic = FakeRestic.new(config, '[]')

    restic.prune

    assert_equal 1, restic.calls.size
    args = restic.last_args
    assert_equal ['forget', '--prune', '--group-by', 'host'], args.first(4)
    assert_includes args, '--keep-last'
    assert_includes args, '2'
    assert_includes args, '--tag'
    assert_includes args, 'kamal-backup,app:demo,type:database,adapter:sqlite'
    refute_includes args, 'host,tags'
  end

  def test_prune_scopes_database_and_file_retention_separately
    config = KamalBackup::Config.new(env: base_env(
      'APP_NAME' => 'demo',
      'DATABASE_ADAPTER' => 'sqlite',
      'SQLITE_DATABASE_PATH' => '/tmp/demo.sqlite3',
      'BACKUP_PATHS' => '/data/storage'
    ))
    restic = FakeRestic.new(config, '[]')

    restic.prune

    tag_filters = restic.calls.filter_map do |args|
      tag_index = args.index('--tag')
      args[tag_index + 1] if tag_index
    end
    assert_equal 2, restic.calls.size
    assert_includes tag_filters, 'kamal-backup,app:demo,type:database,adapter:sqlite'
    assert_includes tag_filters, 'kamal-backup,app:demo,type:files'
  end

  def test_prune_keeps_same_adapter_databases_in_separate_retention_groups
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, 'config')
      FileUtils.mkdir_p(config_dir)
      File.write(
        File.join(config_dir, 'kamal-backup.yml'),
        <<~YAML
          app: demo
          databases:
            - name: app
              adapter: postgres
              url: postgres://app@postgres:5432/app
            - name: queue
              adapter: postgres
              url: postgres://queue@postgres:5432/queue
          restic:
            repository: /tmp/restic
            password: secret
        YAML
      )
      config = KamalBackup::Config.new(env: {}, cwd: dir, load_project_defaults: false)
      restic = FakeRestic.new(config, '[]')

      restic.prune

      tag_filters = restic.calls.filter_map do |args|
        tag_index = args.index('--tag')
        args[tag_index + 1] if tag_index
      end
      assert_equal 2, restic.calls.size
      assert_includes tag_filters, 'kamal-backup,app:demo,type:database,database:app,adapter:postgres'
      assert_includes tag_filters, 'kamal-backup,app:demo,type:database,database:queue,adapter:postgres'
      refute_includes tag_filters, 'kamal-backup,app:demo,type:database,adapter:postgres'
    end
  end

  def test_unlock_runs_restic_unlock
    config = KamalBackup::Config.new(env: base_env('APP_NAME' => 'demo'))
    restic = FakeRestic.new(config, 'removed stale locks')

    result = restic.unlock

    assert_equal %w[unlock], restic.last_args
    assert_equal 'removed stale locks', result.stdout
  end

  def test_snapshots_uses_one_filter_that_requires_all_tags
    config = KamalBackup::Config.new(env: base_env('APP_NAME' => 'demo'))
    restic = FakeRestic.new(config, '[]')

    restic.snapshots(tags: ['kamal-backup', 'app:demo'])

    assert_equal ['snapshots', '--tag', 'kamal-backup,app:demo'], restic.last_args
  end

  def test_restic_env_includes_yaml_restic_settings
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, 'config')
      FileUtils.mkdir_p(config_dir)
      File.write(
        File.join(config_dir, 'kamal-backup.yml'),
        <<~YAML
          app: demo
          restic:
            repository: s3:https://s3.example.com/demo
            password: yaml-secret
        YAML
      )

      config = KamalBackup::Config.new(env: {}, cwd: dir, load_project_defaults: false)
      restic = KamalBackup::Restic.new(config, redactor: KamalBackup::Redactor.new(env: config.env))
      restic_env = restic.send(:restic_env)

      assert_equal 's3:https://s3.example.com/demo', restic_env.fetch('RESTIC_REPOSITORY')
      assert_equal 'yaml-secret', restic_env.fetch('RESTIC_PASSWORD')
    end
  end

  def test_restic_env_includes_yaml_rest_backend_credentials
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, 'config')
      FileUtils.mkdir_p(config_dir)
      File.write(
        File.join(config_dir, 'kamal-backup.yml'),
        <<~YAML
          app: demo
          restic:
            repository: rest:https://backup.example.com/prod
            password: yaml-secret
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
          'RESTIC_REST_PASSWORD' => 'rest-secret'
        },
        cwd: dir,
        load_project_defaults: false
      )
      restic = KamalBackup::Restic.new(config, redactor: KamalBackup::Redactor.new(env: config.env))
      restic_env = restic.send(:restic_env)

      assert_equal 'rest:https://backup.example.com/prod', restic_env.fetch('RESTIC_REPOSITORY')
      assert_equal 'backup', restic_env.fetch('RESTIC_REST_USERNAME')
      assert_equal 'rest-secret', restic_env.fetch('RESTIC_REST_PASSWORD')
    end
  end

  def test_restic_env_passes_credentials_for_supported_backends
    config = KamalBackup::Config.new(env: base_env(
      'B2_ACCOUNT_KEY' => 'b2-secret',
      'AZURE_ACCOUNT_KEY' => 'azure-secret',
      'GOOGLE_APPLICATION_CREDENTIALS' => '/run/secrets/google.json',
      'OS_PASSWORD' => 'swift-secret',
      'ST_KEY' => 'swift-v1-secret',
      'HP_SECRET_KEY' => 'swift-legacy-secret',
      'RCLONE_CONFIG_PASS' => 'rclone-secret',
      'UNRELATED_VALUE' => 'excluded'
    ))
    restic = KamalBackup::Restic.new(config, redactor: KamalBackup::Redactor.new(env: config.env))
    restic_env = restic.send(:restic_env)

    assert_equal 'b2-secret', restic_env.fetch('B2_ACCOUNT_KEY')
    assert_equal 'azure-secret', restic_env.fetch('AZURE_ACCOUNT_KEY')
    assert_equal '/run/secrets/google.json', restic_env.fetch('GOOGLE_APPLICATION_CREDENTIALS')
    assert_equal 'swift-secret', restic_env.fetch('OS_PASSWORD')
    assert_equal 'swift-v1-secret', restic_env.fetch('ST_KEY')
    assert_equal 'swift-legacy-secret', restic_env.fetch('HP_SECRET_KEY')
    assert_equal 'rclone-secret', restic_env.fetch('RCLONE_CONFIG_PASS')
    refute restic_env.key?('UNRELATED_VALUE')
  end

  class InitTrackingRestic < KamalBackup::Restic
    attr_reader :calls

    def initialize(config)
      super(config, redactor: KamalBackup::Redactor.new(env: {}))
      @calls = []
    end

    private

    def run(args, **)
      @calls << args
      raise KamalBackup::CommandError.new('repository does not exist', command: nil, status: 10) if args.first == 'snapshots'

      KamalBackup::CommandResult.new(stdout: '', stderr: '', status: 0)
    end

    def log(_message); end
  end

  def test_ensure_repository_runs_init_when_missing_and_enabled
    config = KamalBackup::Config.new(env: base_env('RESTIC_INIT_IF_MISSING' => 'true'))
    restic = InitTrackingRestic.new(config)

    restic.ensure_repository

    assert_equal [%w[snapshots --json], %w[init]], restic.calls
  end

  def test_ensure_repository_raises_when_init_is_disabled
    config = KamalBackup::Config.new(env: base_env)
    restic = InitTrackingRestic.new(config)

    assert_raises(KamalBackup::CommandError) { restic.ensure_repository }
    assert_equal [%w[snapshots --json]], restic.calls
  end

  class CheckRestic < KamalBackup::Restic
    attr_accessor :fail_check
    attr_reader :last_args

    def initialize(config)
      super(config, redactor: KamalBackup::Redactor.new(env: {}))
    end

    private

    def run(args, **)
      @last_args = args
      raise KamalBackup::CommandError.new('check failed badly', command: nil, status: 1) if fail_check

      KamalBackup::CommandResult.new(stdout: 'repository is healthy', stderr: '', status: 0)
    end

    def log(_message); end
  end

  def test_check_writes_ok_status_to_the_state_file
    Dir.mktmpdir do |dir|
      config = KamalBackup::Config.new(env: base_env('KAMAL_BACKUP_STATE_DIR' => dir))
      restic = CheckRestic.new(config)

      result = restic.check

      assert_equal 'repository is healthy', result.stdout
      state = JSON.parse(File.read(File.join(dir, 'last_check.json')))
      assert_equal 'ok', state.fetch('status')
      assert_includes state.fetch('output'), 'repository is healthy'
    end
  end

  def test_check_records_failure_and_reraises
    Dir.mktmpdir do |dir|
      config = KamalBackup::Config.new(env: base_env('KAMAL_BACKUP_STATE_DIR' => dir))
      restic = CheckRestic.new(config)
      restic.fail_check = true

      assert_raises(KamalBackup::CommandError) { restic.check }

      state = JSON.parse(File.read(File.join(dir, 'last_check.json')))
      assert_equal 'failed', state.fetch('status')
      assert_includes state.fetch('error'), 'check failed badly'
    end
  end

  def test_check_passes_read_data_subset_when_configured
    Dir.mktmpdir do |dir|
      config = KamalBackup::Config.new(env: base_env(
        'KAMAL_BACKUP_STATE_DIR' => dir,
        'RESTIC_CHECK_READ_DATA_SUBSET' => '10%'
      ))
      restic = CheckRestic.new(config)

      restic.check

      assert_equal ['check', '--read-data-subset', '10%'], restic.last_args
    end
  end

  def test_check_succeeds_even_when_the_state_dir_is_not_writable
    Dir.mktmpdir do |dir|
      blocker = File.join(dir, 'not-a-dir')
      File.write(blocker, '')
      config = KamalBackup::Config.new(env: base_env('KAMAL_BACKUP_STATE_DIR' => File.join(blocker, 'state')))
      restic = CheckRestic.new(config)

      result = restic.check

      assert_equal 0, result.status
    end
  end

  def test_latest_snapshot_returns_nil_when_snapshot_output_is_not_json
    config = KamalBackup::Config.new(env: base_env('APP_NAME' => 'demo'))
    restic = FakeRestic.new(config, 'unable to open repository')

    assert_nil restic.latest_snapshot(tags: ['type:database'])
  end

  def test_latest_snapshot_returns_nil_when_there_are_no_snapshots
    config = KamalBackup::Config.new(env: base_env('APP_NAME' => 'demo'))
    restic = FakeRestic.new(config, '[]')

    assert_nil restic.latest_snapshot(tags: ['type:database'])
  end

  def plumbing_restic
    config = KamalBackup::Config.new(env: base_env('APP_NAME' => 'demo'))
    KamalBackup::Restic.new(config, redactor: KamalBackup::Redactor.new(env: {}))
  end

  def command_spec(argv)
    KamalBackup::CommandSpec.new(argv: argv, env: {})
  end

  def pipe(producer_argv, consumer_argv)
    plumbing_restic.send(
      :pipe_commands,
      command_spec(producer_argv),
      command_spec(consumer_argv),
      producer_label: 'producer',
      consumer_label: 'consumer'
    )
  end

  def test_pipe_commands_returns_the_consumer_output
    result = pipe(%w[printf dump-data], ['cat'])

    assert_equal 'dump-data', result.stdout
    assert_equal 0, result.status
  end

  def test_pipe_commands_raises_when_the_producer_fails
    error = assert_raises(KamalBackup::CommandError) do
      pipe(['sh', '-c', 'echo producer-broke >&2; exit 3'], ['cat'])
    end

    assert_equal 3, error.status
    assert_includes error.stderr, 'producer-broke'
  end

  def test_pipe_commands_raises_when_the_consumer_fails
    error = assert_raises(KamalBackup::CommandError) do
      pipe(%w[printf dump-data], ['sh', '-c', 'cat >/dev/null; echo consumer-broke >&2; exit 2'])
    end

    assert_equal 2, error.status
    assert_includes error.stderr, 'consumer-broke'
  end

  def test_pipe_commands_reports_broken_pipes_between_producer_and_consumer
    error = assert_raises(KamalBackup::CommandError) do
      pipe(['sh', '-c', 'sleep 0.2; printf late-data'], ['true'])
    end

    assert_includes error.message, 'failed to pipe producer to consumer'
  end

  def test_pipe_commands_reports_a_missing_producer_command
    error = assert_raises(KamalBackup::CommandError) do
      pipe(['kamal-backup-test-no-such-producer'], ['cat'])
    end

    assert_equal 127, error.status
    assert_includes error.message, 'command not found: kamal-backup-test-no-such-producer'
  end

  def test_pipe_commands_reports_a_missing_consumer_command
    error = assert_raises(KamalBackup::CommandError) do
      pipe(%w[printf dump-data], ['kamal-backup-test-no-such-consumer'])
    end

    assert_equal 127, error.status
    assert_includes error.message, 'command not found: kamal-backup-test-no-such-consumer'
  end

  def with_fake_restic(script)
    Dir.mktmpdir do |dir|
      bin_dir = File.join(dir, 'bin')
      FileUtils.mkdir_p(bin_dir)
      fake_restic = File.join(bin_dir, 'restic')
      File.write(fake_restic, script)
      FileUtils.chmod('+x', fake_restic)
      previous_path = ENV['PATH']
      ENV['PATH'] = "#{bin_dir}#{File::PATH_SEPARATOR}#{previous_path}"
      begin
        yield dir
      ensure
        ENV['PATH'] = previous_path
      end
    end
  end

  def test_write_dump_to_path_writes_the_dump_atomically
    with_fake_restic("#!/bin/sh\nprintf dump-bytes\n") do |dir|
      target = File.join(dir, 'restore', 'database.dump')

      written = plumbing_restic.write_dump_to_path('snap', 'database.dump', target)

      assert_equal target, written
      assert_equal 'dump-bytes', File.read(target)
      assert_empty Dir.glob("#{target}*.tmp")
    end
  end

  def test_write_dump_to_path_cleans_up_the_temp_file_when_restic_fails
    with_fake_restic("#!/bin/sh\necho dump-broke >&2\nexit 1\n") do |dir|
      target = File.join(dir, 'restore', 'database.dump')

      error = assert_raises(KamalBackup::CommandError) do
        plumbing_restic.write_dump_to_path('snap', 'database.dump', target)
      end

      assert_equal 1, error.status
      refute_path_exists target
      assert_empty Dir.glob(File.join(dir, 'restore', '*.tmp'))
    end
  end

  def test_write_dump_to_path_reports_a_missing_restic_binary
    Dir.mktmpdir do |dir|
      empty_bin = File.join(dir, 'empty-bin')
      FileUtils.mkdir_p(empty_bin)
      previous_path = ENV['PATH']
      ENV['PATH'] = empty_bin
      begin
        target = File.join(dir, 'database.dump')

        error = assert_raises(KamalBackup::CommandError) do
          plumbing_restic.write_dump_to_path('snap', 'database.dump', target)
        end

        assert_equal 127, error.status
        assert_includes error.message, 'command not found: restic'
      ensure
        ENV['PATH'] = previous_path
      end
    end
  end

  def test_backup_file_reports_a_missing_restic_binary
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'app.sqlite3')
      File.write(source, 'data')
      empty_bin = File.join(dir, 'empty-bin')
      FileUtils.mkdir_p(empty_bin)
      previous_path = ENV['PATH']
      ENV['PATH'] = empty_bin
      begin
        error = assert_raises(KamalBackup::CommandError) do
          plumbing_restic.backup_file(source, filename: 'databases/demo/app/sqlite.sqlite3', tags: ['type:database'])
        end

        assert_equal 127, error.status
        assert_includes error.message, 'command not found: restic'
      ensure
        ENV['PATH'] = previous_path
      end
    end
  end

  def test_restic_lock_errors_include_unlock_hint
    with_fake_restic("#!/bin/sh\necho 'unable to create lock in backend: repository is already locked' >&2\nexit 11\n") do
      error = assert_raises(KamalBackup::CommandError) do
        plumbing_restic.snapshots
      end

      assert_equal 11, error.status
      assert_includes error.message, 'run `kamal-backup unlock`'
    end
  end

  def test_backup_file_reports_stream_errors_when_restic_exits_early_but_successfully
    with_fake_restic("#!/bin/sh\nsleep 0.2\nexit 0\n") do |dir|
      source = File.join(dir, 'large.sqlite3')
      File.binwrite(source, 'x' * (16 * 1024 * 1024))

      error = assert_raises(KamalBackup::CommandError) do
        plumbing_restic.backup_file(source, filename: 'databases/demo/app/sqlite.sqlite3', tags: ['type:database'])
      end

      assert_includes error.message, 'failed to stream file'
    end
  end

  def test_backup_file_returns_the_restic_result_on_success
    with_fake_restic("#!/bin/sh\ncat >/dev/null\nprintf snapshot-saved\n") do |dir|
      source = File.join(dir, 'app.sqlite3')
      File.write(source, 'data')

      result = plumbing_restic.backup_file(source, filename: 'databases/demo/app/sqlite.sqlite3',
                                                   tags: ['type:database'])

      assert_equal 0, result.status
      assert_equal 'snapshot-saved', result.stdout
    end
  end
end
