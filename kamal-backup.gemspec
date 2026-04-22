require_relative "lib/kamal_backup/version"

Gem::Specification.new do |spec|
  spec.name = "kamal-backup"
  spec.version = KamalBackup::VERSION
  spec.authors = ["kamal-backup contributors"]

  spec.summary = "Kamal-first restic backups for databases and mounted application files."
  spec.description = "A small CLI and Docker image for encrypted, verifiable Kamal accessory backups using restic."
  spec.homepage = "https://github.com/crmne/kamal-backup"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir[
    "LICENSE",
    "README.md",
    "exe/kamal-backup",
    "lib/**/*.rb"
  ]
  spec.bindir = "exe"
  spec.executables = ["kamal-backup"]
  spec.require_paths = ["lib"]
end
