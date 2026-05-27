$LOAD_PATH.unshift(File.expand_path("lib", __dir__))
require "kamal_backup/version"

Gem::Specification.new do |spec|
  spec.name = "kamal-backup"
  spec.version = KamalBackup::VERSION
  spec.authors = ["crmne"]
  spec.summary = "Scheduled backups, restore drills, and evidence for Rails apps deployed with Kamal"
  spec.description = "Back up PostgreSQL, MySQL, SQLite, and file-backed Active Storage files into restic on a schedule, then run restore drills and produce review evidence."
  spec.homepage = "https://github.com/crmne/kamal-backup"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/releases",
    "rubygems_mfa_required" => "true"
  }

  spec.post_install_message = <<~MESSAGE
    kamal-backup 0.3 changes config/kamal-backup.yml.

    If you are upgrading from 0.2, migrate the old flat YAML keys to the new grouped shape:
      https://kamal-backup.dev/upgrading/#upgrading-to-03

    Run `bundle exec kamal-backup validate` before rebooting the backup accessory.
  MESSAGE

  spec.files = Dir.chdir(__dir__) do
    Dir["lib/**/*", "exe/*", "README.md", "LICENSE"]
  end
  spec.bindir = "exe"
  spec.executables = ["kamal-backup"]
  spec.require_paths = ["lib"]

  spec.add_dependency "thor", "~> 1.5"
  spec.add_development_dependency "minitest"
end
