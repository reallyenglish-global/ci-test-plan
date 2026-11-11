require 'rake/testtask'

Rake::TestTask.new do |task|
  task.libs << 'lib'
  task.pattern = 'test/**/*_test.rb'
  task.warning = true
end

task default: :test
