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
end
