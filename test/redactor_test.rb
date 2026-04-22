require_relative "test_helper"

class RedactorTest < Minitest::Test
  def test_redacts_url_credentials
    redactor = KamalBackup::Redactor.new(env: {})

    value = redactor.redact_string("postgres://user:secret@db.example/app")

    assert_equal "postgres://[REDACTED]@db.example/app", value
  end

  def test_redacts_url_credentials_when_password_contains_at
    redactor = KamalBackup::Redactor.new(env: {})

    value = redactor.redact_string("rest:https://backup:abc@def@backup.paolino.me/prod")

    assert_equal "rest:https://[REDACTED]@backup.paolino.me/prod", value
  end

  def test_redacts_query_secrets
    redactor = KamalBackup::Redactor.new(env: {})

    value = redactor.redact_string("s3:https://host/bucket?access_key_id=abc&secret_access_key=def")

    assert_includes value, "access_key_id=[REDACTED]"
    assert_includes value, "secret_access_key=[REDACTED]"
  end

  def test_redacts_known_env_secret_values
    redactor = KamalBackup::Redactor.new(env: { "RESTIC_PASSWORD" => "super-secret" })

    assert_equal "password is [REDACTED]", redactor.redact_string("password is super-secret")
  end

  def test_redacts_sensitive_hash_keys
    redactor = KamalBackup::Redactor.new(env: {})

    redacted = redactor.redact_hash("AWS_ACCESS_KEY_ID" => "abc", "APP_NAME" => "demo")

    assert_equal "[REDACTED]", redacted["AWS_ACCESS_KEY_ID"]
    assert_equal "demo", redacted["APP_NAME"]
  end
end
