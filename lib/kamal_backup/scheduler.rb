require "time"

module KamalBackup
  class Scheduler
    def initialize(config, &backup_block)
      @config = config
      @backup_block = backup_block
      @stop = false
    end

    def run
      install_signal_handlers
      sleep_interruptibly(@config.backup_start_delay_seconds)

      until @stop
        started_at = Time.now.utc
        log("backup started at #{started_at.iso8601}")
        begin
          @backup_block.call
          log("backup completed at #{Time.now.utc.iso8601}")
        rescue StandardError => e
          warn("[kamal-backup] backup failed at #{Time.now.utc.iso8601}: #{e.class}: #{e.message}")
        end

        sleep_interruptibly(@config.backup_schedule_seconds)
      end

      log("scheduler stopped at #{Time.now.utc.iso8601}")
    end

    private

    def install_signal_handlers
      %w[TERM INT].each do |signal|
        Signal.trap(signal) { @stop = true }
      rescue ArgumentError
        nil
      end
    end

    def sleep_interruptibly(seconds)
      deadline = Time.now + seconds
      sleep([deadline - Time.now, 1].min) while !@stop && Time.now < deadline
    end

    def log(message)
      $stdout.puts("[kamal-backup] #{message}")
    end
  end
end
