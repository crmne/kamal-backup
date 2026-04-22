module KamalBackup
  class Error < StandardError; end
  class ConfigurationError < Error; end

  class CommandError < Error
    attr_reader :command, :status, :stdout, :stderr

    def initialize(message, command:, status: nil, stdout: "", stderr: "")
      super(message)
      @command = command
      @status = status
      @stdout = stdout.to_s
      @stderr = stderr.to_s
    end
  end
end
