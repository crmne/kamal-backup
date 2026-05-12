require_relative "test_helper"

class CommandTest < Minitest::Test
  def test_command_spec_redacts_display
    spec = KamalBackup::CommandSpec.new(
      argv: ["pg_dump", "postgres://app:secret@db/app"],
      env: { "PGPASSWORD" => "secret" }
    )
    redactor = KamalBackup::Redactor.new(env: { "PGPASSWORD" => "secret" })

    display = spec.display(redactor)

    assert_includes display, "PGPASSWORD=[REDACTED]"
    assert_includes display, "postgres://[REDACTED]@db/app"
    refute_includes display, "secret"
  end

  def test_capture_returns_stdout
    spec = KamalBackup::CommandSpec.new(argv: [RbConfig.ruby, "-e", "print 'ok'"])

    result = KamalBackup::Command.capture(spec, redactor: KamalBackup::Redactor.new(env: {}))

    assert_equal "ok", result.stdout
    assert_equal 0, result.status
  end

  def test_capture_raises_command_error_on_failure
    spec = KamalBackup::CommandSpec.new(argv: [RbConfig.ruby, "-e", "warn 'boom'; exit 1"])

    error = assert_raises(KamalBackup::CommandError) do
      KamalBackup::Command.capture(spec, redactor: KamalBackup::Redactor.new(env: {}))
    end

    assert_equal 1, error.status
    assert_includes error.stderr, "boom"
    assert_includes error.message, "command failed (1)"
  end

  def test_capture_raises_command_error_for_missing_binary
    spec = KamalBackup::CommandSpec.new(argv: ["nonexistent_binary_xyz_12345"])

    error = assert_raises(KamalBackup::CommandError) do
      KamalBackup::Command.capture(spec, redactor: KamalBackup::Redactor.new(env: {}))
    end

    assert_equal 127, error.status
    assert_includes error.message, "command not found"
  end

  def test_capture_returns_stderr_on_success
    spec = KamalBackup::CommandSpec.new(argv: [RbConfig.ruby, "-e", "print 'out'; $stderr.print 'err'"])

    result = KamalBackup::Command.capture(spec, redactor: KamalBackup::Redactor.new(env: {}))

    assert_equal "out", result.stdout
    assert_equal "err", result.stderr
    assert_equal 0, result.status
  end

  def test_capture_passes_env_to_command
    spec = KamalBackup::CommandSpec.new(
      argv: [RbConfig.ruby, "-e", "print ENV['TEST_KAMAL_VAR']"],
      env: { "TEST_KAMAL_VAR" => "hello" }
    )

    result = KamalBackup::Command.capture(spec, redactor: KamalBackup::Redactor.new(env: {}))

    assert_equal "hello", result.stdout
  end

  def test_capture_passes_stdin_data
    spec = KamalBackup::CommandSpec.new(argv: [RbConfig.ruby, "-e", "print $stdin.read.upcase"])

    result = KamalBackup::Command.capture(spec, input: "hello", redactor: KamalBackup::Redactor.new(env: {}))

    assert_equal "HELLO", result.stdout
  end

  def test_capture_redacts_secrets_in_error_message
    spec = KamalBackup::CommandSpec.new(
      argv: [RbConfig.ruby, "-e", "warn 'password is supersecret123'; exit 1"],
      env: {}
    )
    redactor = KamalBackup::Redactor.new(env: { "RESTIC_PASSWORD" => "supersecret123" })

    error = assert_raises(KamalBackup::CommandError) do
      KamalBackup::Command.capture(spec, redactor: redactor)
    end

    refute_includes error.message, "supersecret123"
    assert_includes error.message, "[REDACTED]"
  end

  def test_command_spec_rejects_empty_argv
    assert_raises(ArgumentError) do
      KamalBackup::CommandSpec.new(argv: [])
    end
  end

  def test_command_spec_strips_nil_env_values
    spec = KamalBackup::CommandSpec.new(
      argv: ["echo"],
      env: { "KEEP" => "value", "DROP" => nil, "EMPTY" => "" }
    )

    assert_equal({ "KEEP" => "value" }, spec.env)
  end

  def test_available_returns_true_for_existing_binary
    assert KamalBackup::Command.available?(RbConfig.ruby.split("/").last)
  end

  def test_available_returns_false_for_nonexistent_binary
    refute KamalBackup::Command.available?("nonexistent_binary_xyz_12345")
  end
end
