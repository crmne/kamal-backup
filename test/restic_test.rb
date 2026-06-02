require_relative "test_helper"

class ResticTest < Minitest::Test
  class FakeRestic < KamalBackup::Restic
    attr_reader :calls, :last_args

    def initialize(config, json)
      super(config, redactor: KamalBackup::Redactor.new(env: {}))
      @json = json
      @calls = []
    end

    def run(args, log_output: true)
      @last_args = args
      @calls << args
      KamalBackup::CommandResult.new(stdout: @json, stderr: "", status: 0)
    end

    private

    def log(_message)
    end
  end

  def test_snapshots_json_requires_all_requested_tags
    config = KamalBackup::Config.new(env: base_env("APP_NAME" => "demo"))
    json = [
      { "short_id" => "db", "tags" => ["kamal-backup", "app:demo", "type:database"] },
      { "short_id" => "files", "tags" => ["kamal-backup", "app:demo", "type:files"] },
      { "short_id" => "other", "tags" => ["kamal-backup", "app:other", "type:database"] }
    ].to_json
    restic = FakeRestic.new(config, json)

    snapshots = restic.snapshots_json(tags: ["kamal-backup", "app:demo", "type:database"])

    assert_equal ["db"], snapshots.map { |snapshot| snapshot["short_id"] }
  end

  def test_backup_paths_adds_each_path_label_as_a_tag_and_uses_stable_host
    config = KamalBackup::Config.new(env: base_env("APP_NAME" => "demo"))
    restic = FakeRestic.new(config, "[]")

    restic.backup_paths(["/data/storage", "/data/uploads"], tags: ["type:files"])

    assert_equal ["backup", "--host", "demo-backup", "/data/storage", "/data/uploads"], restic.last_args.first(5)
    assert_includes restic.last_args, "--tag"
    assert_includes restic.last_args, "path:data-storage"
    assert_includes restic.last_args, "path:data-uploads"
  end

  def test_database_file_finds_stable_and_legacy_dump_paths
    config = KamalBackup::Config.new(env: base_env("APP_NAME" => "demo"))
    json = [
      { "type" => "file", "path" => "/databases/demo/app/postgres.pgdump" },
      { "type" => "file", "path" => "/databases-demo-app-postgres-20260422T120000Z.pgdump" }
    ].map(&:to_json).join("\n")
    restic = FakeRestic.new(config, json)

    assert_equal "/databases/demo/app/postgres.pgdump", restic.database_file("snapshot", "postgres", database_name: "app")
  end

  def test_forget_after_success_groups_database_snapshots_by_host
    config = KamalBackup::Config.new(env: base_env(
      "APP_NAME" => "demo",
      "DATABASE_ADAPTER" => "sqlite",
      "SQLITE_DATABASE_PATH" => "/tmp/demo.sqlite3",
      "BACKUP_PATHS" => "",
      "RESTIC_KEEP_LAST" => "2"
    ))
    restic = FakeRestic.new(config, "[]")

    restic.forget_after_success

    assert_equal 1, restic.calls.size
    args = restic.last_args
    assert_equal ["forget", "--prune", "--group-by", "host"], args.first(4)
    assert_includes args, "--keep-last"
    assert_includes args, "2"
    assert_includes args, "--tag"
    assert_includes args, "kamal-backup,app:demo,type:database,adapter:sqlite"
    refute_includes args, "host,tags"
  end

  def test_forget_after_success_scopes_database_and_file_retention_separately
    config = KamalBackup::Config.new(env: base_env(
      "APP_NAME" => "demo",
      "DATABASE_ADAPTER" => "sqlite",
      "SQLITE_DATABASE_PATH" => "/tmp/demo.sqlite3",
      "BACKUP_PATHS" => "/data/storage"
    ))
    restic = FakeRestic.new(config, "[]")

    restic.forget_after_success

    tag_filters = restic.calls.filter_map do |args|
      tag_index = args.index("--tag")
      args[tag_index + 1] if tag_index
    end
    assert_equal 2, restic.calls.size
    assert_includes tag_filters, "kamal-backup,app:demo,type:database,adapter:sqlite"
    assert_includes tag_filters, "kamal-backup,app:demo,type:files"
  end

  def test_forget_after_success_keeps_same_adapter_databases_in_separate_retention_groups
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, "config")
      FileUtils.mkdir_p(config_dir)
      File.write(
        File.join(config_dir, "kamal-backup.yml"),
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
      restic = FakeRestic.new(config, "[]")

      restic.forget_after_success

      tag_filters = restic.calls.filter_map do |args|
        tag_index = args.index("--tag")
        args[tag_index + 1] if tag_index
      end
      assert_equal 2, restic.calls.size
      assert_includes tag_filters, "kamal-backup,app:demo,type:database,database:app,adapter:postgres"
      assert_includes tag_filters, "kamal-backup,app:demo,type:database,database:queue,adapter:postgres"
      refute_includes tag_filters, "kamal-backup,app:demo,type:database,adapter:postgres"
    end
  end

  def test_snapshots_uses_one_filter_that_requires_all_tags
    config = KamalBackup::Config.new(env: base_env("APP_NAME" => "demo"))
    restic = FakeRestic.new(config, "[]")

    restic.snapshots(tags: ["kamal-backup", "app:demo"])

    assert_equal ["snapshots", "--tag", "kamal-backup,app:demo"], restic.last_args
  end

  def test_restic_env_includes_yaml_restic_settings
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, "config")
      FileUtils.mkdir_p(config_dir)
      File.write(
        File.join(config_dir, "kamal-backup.yml"),
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

      assert_equal "s3:https://s3.example.com/demo", restic_env.fetch("RESTIC_REPOSITORY")
      assert_equal "yaml-secret", restic_env.fetch("RESTIC_PASSWORD")
    end
  end

  def test_restic_env_includes_yaml_rest_backend_credentials
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, "config")
      FileUtils.mkdir_p(config_dir)
      File.write(
        File.join(config_dir, "kamal-backup.yml"),
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
          "RESTIC_REST_USER" => "backup",
          "RESTIC_REST_PASSWORD" => "rest-secret"
        },
        cwd: dir,
        load_project_defaults: false
      )
      restic = KamalBackup::Restic.new(config, redactor: KamalBackup::Redactor.new(env: config.env))
      restic_env = restic.send(:restic_env)

      assert_equal "rest:https://backup.example.com/prod", restic_env.fetch("RESTIC_REPOSITORY")
      assert_equal "backup", restic_env.fetch("RESTIC_REST_USERNAME")
      assert_equal "rest-secret", restic_env.fetch("RESTIC_REST_PASSWORD")
    end
  end
end
