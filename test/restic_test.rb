require_relative "test_helper"

class ResticTest < Minitest::Test
  class FakeRestic < KamalBackup::Restic
    attr_reader :last_args

    def initialize(config, json)
      super(config, redactor: KamalBackup::Redactor.new(env: {}))
      @json = json
    end

    def run(args)
      @last_args = args
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

  def test_backup_paths_adds_each_path_label_as_a_tag
    config = KamalBackup::Config.new(env: base_env("APP_NAME" => "demo"))
    restic = FakeRestic.new(config, "[]")

    restic.backup_paths(["/data/storage", "/data/uploads"], tags: ["type:files", "run:20260422T120000Z"])

    assert_includes restic.last_args, "--tag"
    assert_includes restic.last_args, "path:data-storage"
    assert_includes restic.last_args, "path:data-uploads"
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
