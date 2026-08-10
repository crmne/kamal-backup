# frozen_string_literal: true

require_relative 'test_helper'
require 'timeout'

class SchedulerTest < Minitest::Test
  FakeConfig = Struct.new(:backup_start_delay_seconds, :backup_schedule_seconds, :backup_enabled) do
    def backup_enabled?
      backup_enabled
    end
  end

  def config(delay: 0, schedule: 0, enabled: true)
    FakeConfig.new(delay, schedule, enabled)
  end

  def with_restored_traps
    old_term = Signal.trap('TERM', 'DEFAULT')
    old_int = Signal.trap('INT', 'DEFAULT')
    Signal.trap('TERM', old_term)
    Signal.trap('INT', old_int)
    yield
  ensure
    Signal.trap('TERM', old_term)
    Signal.trap('INT', old_int)
  end

  def test_run_does_not_back_up_when_disabled
    calls = 0
    scheduler = KamalBackup::Scheduler.new(config(enabled: false)) { calls += 1 }

    with_restored_traps do
      thread = Thread.new { scheduler.run }
      sleep 0.2
      scheduler.instance_variable_set(:@stop, true)
      Timeout.timeout(5) { thread.join }
    end

    assert_equal 0, calls, 'scheduler must not take a backup while backups are disabled'
  end

  def test_run_invokes_backup_block_until_stopped
    calls = 0
    scheduler = nil
    scheduler = KamalBackup::Scheduler.new(config) do
      calls += 1
      scheduler.instance_variable_set(:@stop, true) if calls == 2
    end

    out, _err = with_restored_traps { capture_io { Timeout.timeout(10) { scheduler.run } } }

    assert_equal 2, calls
    assert_includes out, 'INFO [kamal-backup] backup started at'
    assert_includes out, 'INFO [kamal-backup] backup completed at'
    assert_includes out, 'INFO [kamal-backup] scheduler stopped at'
  end

  def test_run_warns_and_keeps_running_when_backup_raises
    calls = 0
    scheduler = nil
    scheduler = KamalBackup::Scheduler.new(config) do
      calls += 1
      scheduler.instance_variable_set(:@stop, true) if calls == 2
      raise 'boom' if calls == 1
    end

    out, err = with_restored_traps { capture_io { Timeout.timeout(10) { scheduler.run } } }

    assert_equal 2, calls
    assert_includes err, 'ERROR [kamal-backup] backup failed at'
    assert_includes err, 'RuntimeError: boom'
    assert_includes out, 'backup completed at'
  end

  def test_term_signal_stops_the_scheduler
    scheduler = KamalBackup::Scheduler.new(config(schedule: 60)) do
      Process.kill('TERM', Process.pid)
    end

    out, _err = with_restored_traps { capture_io { Timeout.timeout(10) { scheduler.run } } }

    assert_includes out, 'backup completed at'
    assert_includes out, 'scheduler stopped at'
  end

  def test_install_signal_handlers_tolerates_unsupported_signals
    scheduler = KamalBackup::Scheduler.new(config) { nil }

    Signal.stub(:trap, ->(*) { raise ArgumentError, 'unsupported signal' }) do
      scheduler.send(:install_signal_handlers)
    end
  end

  def test_sleep_interruptibly_returns_immediately_when_stopped
    scheduler = KamalBackup::Scheduler.new(config) { nil }
    scheduler.instance_variable_set(:@stop, true)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    scheduler.send(:sleep_interruptibly, 30)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 1
  end
end
