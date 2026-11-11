require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'
require_relative '../lib/ci_test_plan' if File.file?(File.expand_path('../lib/ci_test_plan.rb', __dir__))

class PlanTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('ci-test-plan-')
    git('init', '-q')
    git('config', 'user.email', 'test@example.invalid')
    git('config', 'user.name', 'Synthetic Fixture')
    write('README.md', 'synthetic')
    commit
    @base = git('rev-parse', 'HEAD').strip
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def git(*args)
    out, err, status = Open3.capture3('git', '-C', @root, *args)
    raise err unless status.success?
    out
  end

  def write(path, content = 'synthetic')
    FileUtils.mkdir_p(File.dirname(File.join(@root, path)))
    File.write(File.join(@root, path), content)
  end

  def commit
    git('add', '--all')
    git('commit', '-qm', 'synthetic change', '--allow-empty')
  end

  def plan(**args)
    CITestPlan.plan(base: @base, root: @root, change_type: 'chore', **args)
  end

  def test_conventional_sources_select_existing_specs
    %w[models services jobs mailers helpers forms policies serializers decorators queries value_objects].each do |kind|
      write("app/#{kind}/nested/widget.rb")
      write("spec/#{kind}/nested/widget_spec.rb")
    end
    write('app/controllers/widgets_controller.rb')
    %w[requests controllers features].each { |kind| write("spec/#{kind}/widgets_spec.rb") }
    write('spec/controllers/widgets_controller_spec.rb')
    write('lib/tasks/refresh.rake')
    write('spec/tasks/refresh_spec.rb')
    write('app/graphql/types/widget.rb')
    write('spec/graphql/types/widget_spec.rb')
    commit
    @base = git('rev-parse', 'HEAD').strip
    git('ls-files', 'app', 'lib').split("\n").each { |path| write(path, 'changed synthetic source') }
    commit
    result = plan
    assert_equal 'affected', result[:mode]
    assert_equal 1, result[:required_level]
    assert_equal git('ls-files', 'spec').split("\n").sort, result[:selected_tests]
  end

  def test_unmapped_or_high_risk_changes_require_full_selection
    %w[app/mystery/widget.rb app/models/uncovered.rb Gemfile Gemfile.lock config/routes.rb db/migrate/001_add.rb .github/workflows/ci.yml bin/check spec/spec_helper.rb spec/support/helper.rb test/test_helper.rb package.json yarn.lock Dockerfile lib/ci_test_plan.rb Rakefile].each do |path|
      write(path)
      commit
      result = plan
      assert_equal 'full', result[:mode], path
      assert_operator result[:required_level], :>=, 3, path
      git('reset', '--hard', @base)
    end
  end

  def test_minimum_risk_is_separate_from_selection_and_labels_only_escalate
    write('docs/guide.md')
    commit
    { 'chore' => 0, 'bugfix' => 0, 'feat' => 2, 'unknown' => 3, 'release' => 5 }.each do |type, level|
      result = plan(change_type: type)
      assert_equal level, result[:required_level], type
      assert_equal(level >= 3 ? 'full' : 'skip', result[:mode], type)
    end
    { 'ci:static' => 0, 'ci:affected' => 1, 'ci:smoke' => 2, 'ci:full' => 3, 'ci:full_e2e' => 4, 'ci:performance' => 5 }.each do |label, level|
      assert_equal level, plan(labels: [label])[:required_level], label
      assert_equal 5, plan(change_type: 'release', labels: [label])[:required_level]
    end
    write('app/controllers/widgets_controller.rb')
    write('spec/requests/widgets_spec.rb')
    commit
    @base = git('rev-parse', 'HEAD').strip
    write('app/controllers/widgets_controller.rb', 'updated')
    commit
    result = plan(change_type: 'bugfix')
    assert_equal 2, result[:required_level]
    assert_equal 'affected', result[:mode]
    assert_equal ['spec/requests/widgets_spec.rb'], result[:selected_tests]
  end

  def test_invalid_git_inputs_never_produce_a_successful_plan
    ['does-not-exist', '--help', "HEAD\0secret"].each do |ref|
      assert_raises(StandardError, ref) { plan(base: ref) }
    end
    assert_raises(StandardError) { plan(root: File.join(@root, 'missing')) }
    write('README.md', 'second')
    commit
    assert_raises(StandardError) { plan(head: @base) }
    write('README.md', 'dirty tracked')
    assert_raises(StandardError) { plan }
    git('add', 'README.md')
    assert_raises(StandardError) { plan }
    git('reset', '--hard', 'HEAD')
    write('.gitignore', "build/\n")
    commit
    write('build/output', 'ignored')
    assert_equal 'build/output', git('check-ignore', 'build/output').strip
    assert_equal 'full', plan[:mode] # .gitignore is intentionally unmapped
  end

  def test_non_document_renames_and_deletes_force_full
    write('app/models/widget.rb')
    write('spec/models/widget_spec.rb')
    write('docs/old.md')
    commit
    @base = git('rev-parse', 'HEAD').strip
    git('mv', 'app/models/widget.rb', 'app/models/gadget.rb')
    commit
    result = plan
    assert_equal 'full', result[:mode]
    assert_equal ['app/models/gadget.rb', 'app/models/widget.rb'], result[:changed_files]
    assert_includes result[:reasons], 'non_document_rename_or_delete'
    git('reset', '--hard', @base)
    git('rm', 'spec/models/widget_spec.rb')
    commit
    assert_equal 'full', plan[:mode]
    git('reset', '--hard', @base)
    git('mv', 'docs/old.md', 'docs/new.md')
    commit
    assert_equal 'skip', plan[:mode]
    git('rm', 'docs/new.md')
    commit
    assert_equal 'skip', plan[:mode]
  end

  def test_configuration_adds_tests_and_risk_but_cannot_rescue_fallback
    write('app/models/widget.rb')
    write('spec/models/widget_spec.rb')
    write('spec/extra/widget_spec.rb')
    write('planner.yml', "preset: rails_rspec\nmappings:\n  - source: app/models/*.rb\n    tests: [spec/extra/*_spec.rb]\nhigh_risk: [app/services/**]\n")
    commit
    @base = git('rev-parse', 'HEAD').strip
    write('app/models/widget.rb', 'updated')
    commit
    result = plan(config: 'planner.yml')
    assert_equal ['spec/extra/widget_spec.rb', 'spec/models/widget_spec.rb'], result[:selected_tests]
    assert_equal 'affected', result[:mode]
    write('app/models/uncovered.rb')
    commit
    assert_equal 'full', plan(config: 'planner.yml')[:mode]
    git('reset', '--hard', @base)
    write('app/services/widget.rb')
    write('spec/services/widget_spec.rb')
    commit
    assert_equal 'full', plan(config: 'planner.yml')[:mode]
  end

  def test_invalid_configuration_is_a_hard_sanitized_error
    invalid = [
      '', '[]', "preset: wrong\n", "preset: rails_rspec\nunknown: true\n",
      "preset: rails_rspec\npreset: rails_rspec\n", "preset: rails_rspec\nhigh_risk: nope\n",
      "preset: rails_rspec\nhigh_risk: [../outside]\n", "preset: rails_rspec\nmappings: [{source: 'app/**', tests: ['--bad']}]\n",
      "preset: rails_rspec\nmappings: [{source: 'app/**', tests: ['spec/**'], mode: skip}]\n",
      "preset: rails_rspec\nx: &secret secret\ny: *secret\n", "--- !ruby/object:Object {}\n", "preset: [broken\n"
    ]
    invalid.each do |yaml|
      write('planner.yml', yaml)
      commit
      error = assert_raises(CITestPlan::Error) { plan(config: 'planner.yml') }
      assert_equal 'invalid configuration', error.message
    end
    assert_raises(CITestPlan::Error) { plan(config: 'missing.yml') }
    assert_raises(CITestPlan::Error) { plan(config: '../outside.yml') }
    write('untracked.yml', "preset: rails_rspec\n")
    assert_raises(CITestPlan::Error) { plan(config: 'untracked.yml') }
    git('rm', 'planner.yml')
    File.symlink('README.md', File.join(@root, 'planner.yml'))
    commit
    assert_raises(CITestPlan::Error) { plan(config: 'planner.yml') }
  end

  def test_symlink_and_option_like_paths_never_escape_in_selected_tests
    File.symlink('README.md', File.join(@root, 'docs-link'))
    FileUtils.mkdir_p(File.join(@root, 'docs'))
    File.symlink('../README.md', File.join(@root, 'docs/link.md'))
    commit
    assert_equal 'full', plan[:mode]
    git('reset', '--hard', @base)
    write('app/models/widget.rb')
    write('spec/models/target_spec.rb')
    File.symlink('target_spec.rb', File.join(@root, 'spec/models/widget_spec.rb'))
    commit
    @base = git('rev-parse', 'HEAD').strip
    write('app/models/widget.rb', 'updated')
    commit
    result = plan
    assert_equal 'full', result[:mode]
    refute_includes result[:selected_tests], 'spec/models/widget_spec.rb'
    write('spec/models/-option_spec.rb')
    write("spec/models/line\nbreak_spec.rb")
    commit
    result = plan
    assert_equal 'full', result[:mode]
    refute_includes result[:selected_tests], 'spec/models/-option_spec.rb'
    refute_includes result[:selected_tests], "spec/models/line\nbreak_spec.rb"
    assert_includes result[:changed_files], "spec/models/line\nbreak_spec.rb"
  end

  def test_nul_diff_preserves_spaces_and_quotes_in_filenames
    path = "spec/models/a 'quoted' name_spec.rb"
    write(path)
    commit
    assert_equal [path], plan[:changed_files]
    assert_equal [path], plan[:selected_tests]
    assert_equal 'affected', plan[:mode]
  end

  def test_library_rejects_invalid_public_argument_types
    [nil, 'fix', :feat, 42].each { |type| assert_raises(CITestPlan::Error) { plan(change_type: type) } }
    [nil, 'ci:full', [nil], [42], ["ci:full\nsecret"]].each do |labels|
      assert_raises(CITestPlan::Error) { plan(labels: labels) }
    end
    assert_raises(CITestPlan::Error) { plan(root: nil) }
    assert_raises(CITestPlan::Error) { plan(config: 42) }
  end

  def test_cli_emits_deterministic_json_and_sanitizes_errors
    write('docs/guide.md')
    commit
    executable = File.expand_path('../exe/ci-test-plan', __dir__)
    assert File.file?(executable), 'CLI executable must exist'
    args = [RbConfig.ruby, executable, 'plan', '--base', @base, '--root', @root, '--type', 'chore']
    out, err, status = Open3.capture3(*args)
    assert status.success?, err
    assert_equal '', err
    assert_equal 'skip', JSON.parse(out)['mode']
    assert_equal out, Open3.capture3(*args).first
    out, err, status = Open3.capture3(RbConfig.ruby, executable, '--help')
    assert status.success?
    assert_includes out, 'Usage:'
    assert_equal '', err
    [[], ['plan'], ['wrong'], ['plan', '--base', 'secret-does-not-exist', '--root', @root],
      ['plan', '--base', @base, '--root', @root, '--type', 'secret-invalid'],
      ['plan', '--base', @base, '--root', @root, '--unexpected-secret'],
      ['plan', '--base', @base, '--root', @root, 'extra-secret']].each do |invalid|
      out, err, status = Open3.capture3(RbConfig.ruby, executable, *invalid)
      assert_equal 2, status.exitstatus, invalid.inspect
      assert_equal '', out
      assert_equal "ci-test-plan: invalid input or repository state\n", err
    end
  end

  def test_built_gem_installs_and_runs_without_runtime_dependencies
    project = File.expand_path('..', __dir__)
    gemspec = File.join(project, 'ci-test-plan.gemspec')
    assert File.file?(gemspec), 'gemspec must exist'
    spec = Gem::Specification.load(gemspec)
    assert_equal 'ci-test-plan', spec.name
    assert_equal '0.1.0', spec.version.to_s
    assert_equal [], spec.runtime_dependencies
    assert_equal ['MIT'], spec.licenses
    assert spec.required_ruby_version.satisfied_by?(Gem::Version.new('3.2.0'))
    refute spec.required_ruby_version.satisfied_by?(Gem::Version.new('3.1.9'))
    assert_equal [], spec.files.grep(%r{\A(?:test/|docs/|\.github/)|evidence})
    Dir.mktmpdir('ci-test-plan-package-', ENV.fetch('TMPDIR')) do |dir|
      package = File.join(dir, 'ci-test-plan.gem')
      out, err, status = Open3.capture3(RbConfig.ruby, '-S', 'gem', 'build', gemspec, '--output', package, chdir: project)
      assert status.success?, out + err
      home = File.join(dir, 'gems')
      out, err, status = Open3.capture3(RbConfig.ruby, '-S', 'gem', 'install', '--local', package, '--install-dir', home, '--bindir', File.join(dir, 'bin'), '--ignore-dependencies', '--no-document')
      assert status.success?, out + err
      write('docs/installed.md')
      commit
      out, err, status = Open3.capture3({ 'GEM_HOME' => home, 'GEM_PATH' => home }, RbConfig.ruby, File.join(dir, 'bin/ci-test-plan'), 'plan', '--base', @base, '--root', @root, '--type', 'chore')
      assert status.success?, out + err
      assert_equal '', err
      assert_equal 'skip', JSON.parse(out)['mode']
      write('README.rb', 'synthetic runtime input')
      commit
      out, err, status = Open3.capture3({ 'GEM_HOME' => home, 'GEM_PATH' => home }, RbConfig.ruby, File.join(dir, 'bin/ci-test-plan'), 'plan', '--base', @base, '--root', @root, '--type', 'chore')
      assert status.success?, out + err
      assert_equal 'full', JSON.parse(out)['mode']
      git('config', 'filter.secret-review.clean', 'secret-command-must-not-run')
      out, err, status = Open3.capture3({ 'GEM_HOME' => home, 'GEM_PATH' => home }, RbConfig.ruby, File.join(dir, 'bin/ci-test-plan'), 'plan', '--base', @base, '--root', @root, '--type', 'chore')
      assert_equal 2, status.exitstatus
      assert_equal '', out
      assert_equal "ci-test-plan: invalid input or repository state\n", err
    end
  end

  def test_configured_high_risk_precedes_documentation_and_config_itself_is_high_risk
    write('docs/planner.yml', "preset: rails_rspec\nhigh_risk: [docs/security.md]\n")
    commit
    @base = git('rev-parse', 'HEAD').strip
    write('docs/security.md')
    commit
    assert_equal 'full', plan(config: 'docs/planner.yml')[:mode]
    git('reset', '--hard', @base)
    write('docs/planner.yml', "preset: rails_rspec\nhigh_risk: []\n")
    commit
    assert_equal 'full', plan(config: 'docs/planner.yml')[:mode]
  end

  def test_deleting_a_document_named_symlink_remains_full
    FileUtils.mkdir_p(File.join(@root, 'docs'))
    File.symlink('../README.md', File.join(@root, 'docs/link.md'))
    commit
    @base = git('rev-parse', 'HEAD').strip
    git('rm', 'docs/link.md')
    commit
    assert_equal 'full', plan[:mode]
  end

  def test_shared_test_helpers_are_high_risk_even_when_named_like_specs
    %w[support factories fixtures shared_examples shared_contexts].each do |kind|
      path = "spec/#{kind}/widget_spec.rb"
      write(path)
      commit
      assert_equal 'full', plan[:mode], path
      assert_includes plan[:reasons], 'high_risk_change'
      git('reset', '--hard', @base)
    end
  end

  def test_git_status_does_not_execute_repository_fsmonitor_commands
    write('docs/guide.md')
    commit
    write('monitor.sh', "#!/bin/sh\nprintf invoked > '#{@root}/monitor-ran'\nexit 1\n")
    File.chmod(0o755, File.join(@root, 'monitor.sh'))
    git('config', 'core.fsmonitor', File.join(@root, 'monitor.sh'))
    plan
    refute File.exist?(File.join(@root, 'monitor-ran')), 'planner must disable repository fsmonitor execution'
  end

  def test_configuration_rejects_multiple_documents_and_deep_nesting
    write('planner.yml', "preset: rails_rspec\n---\npreset: wrong\n")
    commit
    assert_raises(CITestPlan::Error) { plan(config: 'planner.yml') }
    write('planner.yml', 'preset: rails_rspec' + "\nhigh_risk: " + ('[' * 1000) + 'x' + (']' * 1000))
    commit
    assert_raises(CITestPlan::Error) { plan(config: 'planner.yml') }
  end

  def test_three_dot_comparison_uses_merge_base_not_base_branch_tip
    common = @base
    git('checkout', '-qb', 'base-side')
    write('Gemfile')
    commit
    @base = git('rev-parse', 'HEAD').strip
    git('checkout', '-qb', 'head-side', common)
    write('spec/models/widget_spec.rb', "raise 'must not load this synthetic spec'")
    commit
    result = plan
    assert_equal common, result[:merge_base_sha]
    assert_equal ['spec/models/widget_spec.rb'], result[:changed_files]
    assert_equal ['spec/models/widget_spec.rb'], result[:selected_tests]
    assert_equal 'affected', result[:mode]
    assert_equal 3, plan(change_type: 'unknown')[:required_level]
    assert_equal 'full', plan(change_type: 'unknown')[:mode]
  end

  def test_cli_accepts_explicit_head_config_and_comma_labels
    write('planner.yml', "preset: rails_rspec\n")
    commit
    @base = git('rev-parse', 'HEAD').strip
    write('docs/cli.md')
    commit
    executable = File.expand_path('../exe/ci-test-plan', __dir__)
    out, err, status = Open3.capture3(RbConfig.ruby, executable, 'plan', '--base', @base, '--head', 'HEAD', '--type', 'chore', '--labels', 'ci:smoke,ci:full_e2e,unrelated', '--config', 'planner.yml', chdir: @root)
    assert status.success?, err
    assert_equal '', err
    result = JSON.parse(out)
    assert_equal 'full', result['mode']
    assert_equal 4, result['required_level']
    assert_equal 'full_e2e', result['level_name']
  end

  def test_reasons_do_not_mislabel_unmapped_source_as_documentation
    write('app/mystery/widget.rb')
    commit
    refute_includes plan[:reasons], 'documentation_only'
    assert_includes plan[:reasons], 'unmapped_source'
    @base = git('rev-parse', 'HEAD').strip
    assert_equal ['no_changes'], plan[:reasons]
  end

  def test_index_flags_cannot_hide_dirty_runtime_inputs
    write('app/models/widget.rb')
    write('spec/models/widget_spec.rb')
    commit
    @base = git('rev-parse', 'HEAD').strip
    %w[assume-unchanged skip-worktree].each do |flag|
      git('update-index', "--#{flag}", 'app/models/widget.rb')
      write('app/models/widget.rb', 'hidden dirty source')
      assert_raises(CITestPlan::Error) { plan }
      git('update-index', "--no-#{flag}", 'app/models/widget.rb')
      git('reset', '--hard', 'HEAD')
    end
  end

  def test_rake_tasks_also_map_to_spec_lib_tasks_layout
    write('lib/tasks/nested/refresh.rake')
    write('spec/lib/tasks/nested/refresh_spec.rb')
    commit
    @base = git('rev-parse', 'HEAD').strip
    write('lib/tasks/nested/refresh.rake', 'changed task')
    commit
    assert_equal ['spec/lib/tasks/nested/refresh_spec.rb'], plan[:selected_tests]
    assert_equal 'affected', plan[:mode]
  end

  def test_invalid_utf8_git_paths_are_a_hard_error
    write("spec/models/bad\xFF_spec.rb".b)
    commit
    assert_raises(CITestPlan::Error) { plan }
  end

  def test_documentation_allowlist_does_not_skip_runtime_files
    %w[docs/deploy.rb docs/config.yml README.rb LICENSE.sh docs/guide.rst docs/no_extension].each do |path|
      write(path)
      commit
      result = plan
      assert_equal 'full', result[:mode], path
      refute_includes result[:reasons], 'documentation_only', path
      git('reset', '--hard', @base)
    end
    %w[docs/nested/guide.md docs/guide.txt README CHANGELOG.md CONTRIBUTING.txt LICENSE CODE_OF_CONDUCT.md].each do |path|
      write(path, 'changed documentation')
      commit
      assert_equal 'skip', plan[:mode], path
      git('reset', '--hard', @base)
    end
  end

  def test_gitlink_changes_cannot_be_hidden_by_diff_configuration
    old_sha = @base
    commit
    new_sha = git('rev-parse', 'HEAD').strip
    git('update-index', '--add', '--cacheinfo', "160000,#{old_sha},vendor/widget")
    git('commit', '-qm', 'synthetic gitlink baseline')
    @base = git('rev-parse', 'HEAD').strip
    git('update-index', '--cacheinfo', "160000,#{new_sha},vendor/widget")
    git('commit', '-qm', 'synthetic gitlink change')
    git('config', 'diff.ignoreSubmodules', 'all')
    result = plan
    assert_equal ['vendor/widget'], result[:changed_files]
    assert_equal 'full', result[:mode]
    assert_includes result[:reasons], 'unsafe_path_or_symlink'
  end

  def test_clean_filter_is_rejected_before_status_without_execution
    write('.gitattributes', "README.md filter=review\n")
    commit
    marker = File.join(@root, 'filter-ran')
    write('clean.sh', "#!/bin/sh\nprintf invoked > '#{marker}'\ncat\n")
    File.chmod(0o755, File.join(@root, 'clean.sh'))
    git('config', 'filter.review.clean', File.join(@root, 'clean.sh'))
    write('README.md', 'dirty runtime bytes longer than baseline')
    trace = File.join(@root, 'git-trace')
    previous = ENV['GIT_TRACE']
    ENV['GIT_TRACE'] = trace
    error = assert_raises(CITestPlan::Error) { plan }
    assert_equal 'unsupported git filter drivers', error.message
    refute File.exist?(marker), 'clean filter must never execute'
    refute_match(/built-in: git .*status/, File.read(trace))
  ensure
    ENV['GIT_TRACE'] = previous
  end

  def test_lib_sources_map_to_existing_specs_without_changing_specs
    write('lib/nested/widget.rb')
    write('spec/lib/nested/widget_spec.rb')
    commit
    @base = git('rev-parse', 'HEAD').strip
    write('lib/nested/widget.rb', 'changed source only')
    commit
    result = plan
    assert_equal ['lib/nested/widget.rb'], result[:changed_files]
    assert_equal ['spec/lib/nested/widget_spec.rb'], result[:selected_tests]
    assert_equal 'affected', result[:mode]
    assert_equal 1, result[:required_level]
  end

  def test_planner_entrypoints_are_explicitly_high_risk_even_with_mapped_tests
    paths = %w[lib/ci_test_plan.rb exe/ci-test-plan ci/nested/check.rb]
    paths.each { |path| write(path) }
    write('spec/lib/ci_test_plan_spec.rb')
    write('spec/entrypoints_spec.rb')
    write('planner.yml', "preset: rails_rspec\nmappings:\n  - source: '**/*'\n    tests: [spec/entrypoints_spec.rb]\n")
    commit
    @base = git('rev-parse', 'HEAD').strip
    paths.each do |path|
      write(path, 'changed entrypoint')
      commit
      result = plan(config: 'planner.yml')
      assert_includes result[:selected_tests], 'spec/entrypoints_spec.rb'
      assert_equal 'full', result[:mode], path
      assert_includes result[:reasons], 'high_risk_change', path
      git('reset', '--hard', @base)
    end
  end

  def with_environment(values)
    previous = values.to_h { |key, _value| [key, ENV[key]] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end

  def test_effective_filter_drivers_are_rejected_from_all_configuration_sources
    %w[clean smudge process].each do |driver|
      key = "filter.secret-review.#{driver}"
      git('config', key, '') # Even an unused, empty driver is unsupported.
      assert_equal 'unsupported git filter drivers', assert_raises(CITestPlan::Error) { plan }.message
      git('config', '--unset-all', key)
    end

    write('included-config', "[filter \"secret-review\"]\n  smudge = secret-command\n")
    git('config', 'include.path', File.join(@root, 'included-config'))
    assert_equal 'unsupported git filter drivers', assert_raises(CITestPlan::Error) { plan }.message
    git('config', '--unset-all', 'include.path')

    write('global-config', "[include]\n  path = #{@root}/included-config\n")
    environments = [
      { 'GIT_CONFIG_GLOBAL' => File.join(@root, 'global-config') },
      { 'GIT_CONFIG_COUNT' => '1', 'GIT_CONFIG_KEY_0' => 'filter.secret-review.process', 'GIT_CONFIG_VALUE_0' => 'secret-command' },
      { 'GIT_CONFIG_PARAMETERS' => "'filter.secret-review.clean'='secret-command'" }
    ]
    environments.each do |environment|
      with_environment(environment) do
        assert_equal 'unsupported git filter drivers', assert_raises(CITestPlan::Error) { plan }.message
        executable = File.expand_path('../exe/ci-test-plan', __dir__)
        out, err, status = Open3.capture3(RbConfig.ruby, executable, 'plan', '--base', @base, '--root', @root)
        assert_equal 2, status.exitstatus
        assert_equal '', out
        assert_equal "ci-test-plan: invalid input or repository state\n", err
      end
    end
  end

  def test_unconfigured_attributes_do_not_execute_commands_or_block_planning
    write('.gitattributes', "README.md filter=unconfigured\n")
    commit
    @base = git('rev-parse', 'HEAD').strip
    write('docs/guide.md')
    commit
    assert_equal 'skip', plan[:mode]
  end

  def test_status_does_not_execute_hooks_from_core_hooks_path
    write('docs/guide.md')
    commit
    marker = File.join(@root, 'hook-ran')
    %w[post-index-change pre-commit post-checkout fsmonitor-watchman].each do |hook|
      path = "custom-hooks/#{hook}"
      write(path, "#!/bin/sh\nprintf invoked > '#{marker}'\nexit 1\n")
      File.chmod(0o755, File.join(@root, path))
    end
    git('config', 'core.hooksPath', File.join(@root, 'custom-hooks'))
    git('config', 'core.fsmonitor', File.join(@root, 'custom-hooks/fsmonitor-watchman'))
    # Force stat refresh; GIT_OPTIONAL_LOCKS=0 must prevent an index rewrite
    # and therefore post-index-change, even with a custom hooks directory.
    File.utime(Time.now + 2, Time.now + 2, File.join(@root, 'README.md'))
    assert_equal 'skip', plan[:mode]
    refute File.exist?(marker)
    with_environment('GIT_CONFIG_COUNT' => '1', 'GIT_CONFIG_KEY_0' => 'core.fsmonitor',
      'GIT_CONFIG_VALUE_0' => File.join(@root, 'custom-hooks/fsmonitor-watchman')) do
      assert_equal 'skip', plan[:mode]
      refute File.exist?(marker)
    end
  end

  def test_docs_only_chore_emits_static_plan
    write('docs/guide.md')
    commit
    assert defined?(CITestPlan), 'planner API must exist'
    result = plan
    assert_equal 1, result[:schema_version]
    assert_equal 'skip', result[:mode]
    assert_equal 0, result[:required_level]
    assert_equal 'static', result[:level_name]
    assert_equal [], result[:selected_tests]
    assert_equal ['docs/guide.md'], result[:changed_files]
    assert_equal @base, result[:base_sha]
    assert_equal @base, result[:merge_base_sha]
    assert_equal git('rev-parse', 'HEAD').strip, result[:head_sha]
    assert_equal result, plan
  end
end
