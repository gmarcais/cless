require 'rake/testtask'

task :default => [:test]
 
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

task :cless do |t|
  ARGV.shift
  exec("ruby", "-Ilib", "./bin/cless", *ARGV)
end
