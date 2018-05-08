# coding: utf-8
require 'rake/testtask'
require 'rubygems/package_task'
load 'lib/cless/version.rb'

task :default => :cless

# Run test (probably outdated)
Rake::TestTask.new
begin
  require 'rcov/rcovtask'
  Rcov::RcovTask.new do |t|
    t.test_files = FileList['test/test*.rb']
    # t.verbose = true     # uncomment to see the executed command
  end
rescue LoadError
  # rcov not installed!
end

# Create gem
spec = Gem::Specification.new do |s|
  s.name        = "cless"
  s.version     = Version.join(".")
  s.platform    = Gem::Platform::RUBY
  s.authors     = ["Guillaume Marçais"]
  s.email       = ["gmarcais@cs.cmu.edu"]
  s.homepage    = "https://github.com/gmarcais/cless"
  s.summary     = "A column oriented less"
  s.licenses    = ['GPL-3.0']
  s.description = "cless displays column oriented files."

  # If you need to check in files that aren't .rb files, add them here
  s.files        = Dir["{lib}/**/*.rb", "bin/*", "LICENSE", "*.md"]
  s.require_path = 'lib'

  # If you need an executable, add it here
  s.executables = ["cless"]

  # Depends on ncursesw
  s.add_runtime_dependency "ncursesw"
end
Gem::PackageTask.new(spec) do |pkg|
  pkg.need_zip = false
  pkg.need_tar = true
end


desc "Run cless from local directory"
task :cless do |t|
  ARGV.shift
  ruby("-I./lib", "./bin/cless", *ARGV)
end
