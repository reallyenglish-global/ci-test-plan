# frozen_string_literal: true
require_relative 'lib/ci_test_plan'

Gem::Specification.new do |spec|
  spec.name = 'ci-test-plan'
  spec.version = CITestPlan::VERSION
  spec.authors = ['ReallyEnglish contributors']
  spec.summary = 'Conservative, deterministic Rails/RSpec CI test selection plans'
  spec.description = 'Produces JSON test plans from immutable Git changes without loading an application or executing tests. Conservative fallback is not a dependency-impact proof.'
  spec.homepage = 'https://github.com/reallyenglish-global/ci-test-plan'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.2'
  spec.files = %w[lib/ci_test_plan.rb exe/ci-test-plan README.md LICENSE].select { |path| File.file?(File.join(__dir__, path)) }
  spec.bindir = 'exe'
  spec.executables = ['ci-test-plan']
  spec.require_paths = ['lib']
  spec.metadata = {
    'source_code_uri' => spec.homepage,
    'bug_tracker_uri' => "#{spec.homepage}/issues",
    'rubygems_mfa_required' => 'true'
  }
end
