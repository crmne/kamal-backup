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

  def test_ignores_short_secret_values
    redactor = KamalBackup::Redactor.new(env: { "RESTIC_PASSWORD" => "abc" })

    assert_equal "value is abc", redactor.redact_string("value is abc")
  end

  def test_redacts_explicit_secret_values
    redactor = KamalBackup::Redactor.new(secret_values: ["my-token-123"])

    assert_equal "token: [REDACTED]", redactor.redact_string("token: my-token-123")
  end

  def test_redact_string_handles_nil_coercion
    redactor = KamalBackup::Redactor.new(env: {})

    assert_equal "", redactor.redact_string(nil)
  end

  def test_redact_value_returns_nil_for_nil
    redactor = KamalBackup::Redactor.new(env: {})

    assert_nil redactor.redact_value("APP_NAME", nil)
  end

  def test_redact_value_redacts_password_keys_regardless_of_case
    redactor = KamalBackup::Redactor.new(env: {})

    assert_equal "[REDACTED]", redactor.redact_value("DB_PASSWORD", "visible")
    assert_equal "[REDACTED]", redactor.redact_value("db_password", "visible")
    assert_equal "[REDACTED]", redactor.redact_value("MySecret", "visible")
    assert_equal "[REDACTED]", redactor.redact_value("API_TOKEN", "visible")
    assert_equal "[REDACTED]", redactor.redact_value("aws_secret_access_key", "visible")
  end

  def test_redact_value_passes_through_non_secret_keys
    redactor = KamalBackup::Redactor.new(env: {})

    assert_equal "demo", redactor.redact_value("APP_NAME", "demo")
    assert_equal "postgres", redactor.redact_value("DATABASE_ADAPTER", "postgres")
  end

  def test_redacts_multiple_secrets_in_one_string
    redactor = KamalBackup::Redactor.new(env: {
      "RESTIC_PASSWORD" => "restic-pass",
      "AWS_SECRET_ACCESS_KEY" => "aws-secret-key"
    })

    result = redactor.redact_string("restic: restic-pass, aws: aws-secret-key")

    refute_includes result, "restic-pass"
    refute_includes result, "aws-secret-key"
    assert_includes result, "[REDACTED]"
  end

  def test_redacts_url_with_user_only_no_password
    redactor = KamalBackup::Redactor.new(env: {})

    value = redactor.redact_string("postgres://admin@db.example/app")

    assert_equal "postgres://[REDACTED]@db.example/app", value
  end

  def test_redacts_multiple_query_params
    redactor = KamalBackup::Redactor.new(env: {})

    value = redactor.redact_string("https://host/path?token=abc123&password=xyz&name=app")

    assert_includes value, "token=[REDACTED]"
    assert_includes value, "password=[REDACTED]"
    assert_includes value, "name=app"
  end

end
