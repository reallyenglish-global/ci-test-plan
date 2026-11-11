# frozen_string_literal: true

require 'open3'
require 'yaml'

module CITestPlan
  VERSION = '0.1.0'
  LEVELS = %w[static affected smoke full full_e2e performance].freeze

  class Error < StandardError; end

  # Only immutable object IDs cross into diff/tree operations. Git diagnostics are
  # intentionally discarded: refs and repository contents can contain secrets.
  def self.git(root, *args)
    out, _err, status = Open3.capture3({ 'GIT_OPTIONAL_LOCKS' => '0', 'GIT_NO_REPLACE_OBJECTS' => '1' },
      'git', '-c', 'core.fsmonitor=false', '-C', root, *args)
    raise Error, 'git operation failed' unless status.success?
    raise Error, 'invalid git output encoding' unless out.valid_encoding?
    out
  rescue SystemCallError, ArgumentError
    raise Error, 'git operation failed'
  end

  def self.plan(base:, root:, head: 'HEAD', change_type: 'unknown', labels: [], config: nil)
    raise Error, 'invalid change type' unless %w[chore bugfix feat unknown release].include?(change_type)
    raise Error, 'invalid labels' unless labels.is_a?(Array) && labels.all? { |label| label.is_a?(String) && label.valid_encoding? && !label.match?(/[\x00-\x1f\x7f]/) }
    raise Error, 'invalid repository root' unless root.is_a?(String) && !root.include?("\0") && File.directory?(root)
    root = File.realpath(root)
    git = ->(*args) { self.git(root, *args) }
    # Inspect effective configuration (including includes and inherited GIT_CONFIG_*
    # overrides) without invoking conversion drivers. Even unused/empty drivers
    # are unsupported in this release; never echo their names or values.
    config_keys = git.call('config', '--includes', '--null', '--list', '--name-only').split("\0")
    raise Error, 'unsupported git filter drivers' if config_keys.any? { |key| key.match?(/\Afilter\..*\.(?:clean|smudge|process)\z/i) }
    raise Error, 'root must be repository top level' unless File.realpath(git.call('rev-parse', '--show-toplevel').strip) == root
    [base, head].each do |ref|
      raise Error, 'invalid revision' unless ref.is_a?(String) && !ref.empty? && !ref.start_with?('-') && !ref.include?("\0")
    end
    base_sha = git.call('rev-parse', '--verify', '--end-of-options', "#{base}^{commit}").strip
    head_sha = git.call('rev-parse', '--verify', '--end-of-options', "#{head}^{commit}").strip
    raise Error, 'head must equal checkout HEAD' unless head_sha == git.call('rev-parse', '--verify', 'HEAD').strip
    raise Error, 'tracked working tree or index is dirty' unless git.call('status', '--porcelain=v1', '-z', '--untracked-files=no').empty?
    raise Error, 'unsupported index flags' unless git.call('ls-files', '-v', '-z', '--').split("\0").all? { |entry| entry.start_with?('H ') }
    merge_base = git.call('merge-base', '--', base_sha, head_sha).strip
    changes = parse_changes(git.call('diff', '--no-ext-diff', '--ignore-submodules=none', '--find-renames', '--name-status', '-z', "#{merge_base}...#{head_sha}", '--'))
    files = changes.flat_map { |change| change[:paths] }.uniq.sort
    tree = tree_modes(git.call('ls-tree', '-rz', head_sha, '--'))
    old_tree = tree_modes(git.call('ls-tree', '-rz', merge_base, '--'))
    tracked = tree.keys
    settings = config ? load_config(root, config, tracked) : {}
    tests = files.flat_map { |file| conventional_tests(file, tracked) }.uniq.sort
    settings.fetch('mappings', []).each do |mapping|
      next unless files.any? { |file| glob?(mapping['source'], file) }
      tests |= tracked.select { |file| mapping['tests'].any? { |pattern| glob?(pattern, file) } }
    end
    tests.sort!
    unsafe_tests = tests.reject { |file| safe_checkout_file?(root, file) }
    tests -= unsafe_tests
    unsafe_changes = files.any? do |file|
      unsafe_path?(file) || [tree[file], old_tree[file]].compact.any? { |mode| !%w[100644 100755].include?(mode) } ||
        tracked.include?(file) && !safe_checkout_file?(root, file)
    end
    level = tests.empty? ? 0 : 1
    reasons = []
    reasons << 'affected_tests' unless tests.empty?
    reasons << 'no_changes' if files.empty?
    reasons << 'documentation_only' if !files.empty? && files.all? { |file| documentation?(file) } && !unsafe_changes
    if unsafe_changes || !unsafe_tests.empty?
      level = 3
      reasons << 'unsafe_path_or_symlink'
    end
    files.each do |file|
      configured_risk = settings.fetch('high_risk', []).any? { |pattern| glob?(pattern, file) }
      config_changed = config && File.expand_path(config, root) == File.join(root, file)
      if high_risk?(file) || configured_risk || config_changed
        level = 3
        reasons << 'high_risk_change'
      elsif !documentation?(file) && conventional_tests(file, tracked).empty?
        level = 3
        reasons << 'unmapped_source'
      end
    end
    if changes.any? { |change| change[:status].match?(/\A[DRCT]/) && change[:paths].any? { |file| !documentation?(file) } }
      level = 3
      reasons << 'non_document_rename_or_delete'
    end
    minimum = { 'chore' => 0, 'bugfix' => 0, 'feat' => 2, 'unknown' => 3, 'release' => 5 }.fetch(change_type)
    if change_type == 'bugfix' && files.any? { |file| file.match?(%r{\Aapp/(?:controllers|graphql|views|assets|javascript)/}) }
      minimum = 2
    end
    reasons << "change_type:#{change_type}" if minimum.positive?
    labels.each do |label|
      index = LEVELS.index(label.delete_prefix('ci:')) if label.start_with?('ci:')
      next unless index
      minimum = [minimum, index].max
      reasons << "label:#{label}" if index.positive?
    end
    mode = level >= 3 ? 'full' : (tests.empty? ? 'skip' : 'affected')
    level = [level, minimum].max
    mode = 'full' if level >= 3
    { schema_version: 1, base_sha: base_sha, head_sha: head_sha, merge_base_sha: merge_base,
      changed_files: files, selected_tests: tests, mode: mode, required_level: level,
      level_name: LEVELS[level], reasons: reasons.uniq.sort }
  end

  def self.tree_modes(output)
    output.split("\0").to_h do |record|
      metadata, path = record.split("\t", 2)
      raise Error, 'invalid git tree' unless path
      [path, metadata.split(' ', 2).first]
    end
  end

  def self.unsafe_path?(path)
    raise Error, 'invalid repository path encoding' unless path.dup.force_encoding(Encoding::UTF_8).valid_encoding?
    path.empty? || path.start_with?('/') || path.match?(/[\x00-\x1f\x7f\\]/) ||
      path.split('/', -1).any? { |part| part.empty? || %w[. ..].include?(part) || part.start_with?('-') }
  end

  def self.safe_checkout_file?(root, path)
    return false if unsafe_path?(path)
    parts = path.split('/')
    return false if parts.each_index.any? { |i| File.symlink?(File.join(root, *parts[0..i])) }
    absolute = File.join(root, path)
    File.file?(absolute) && File.realpath(absolute).start_with?("#{root}/")
  rescue SystemCallError
    false
  end

  def self.load_config(root, path, tracked)
    raise Error unless path.is_a?(String)
    full_path = File.expand_path(path, root)
    relative = full_path.delete_prefix("#{root}/")
    raise Error unless full_path.start_with?("#{root}/") && tracked.include?(relative)
    raise Error if relative.split('/').each_index.any? { |i| File.symlink?(File.join(root, *relative.split('/')[0..i])) }
    raise Error unless File.file?(full_path) && File.size(full_path) <= 65_536
    text = File.read(full_path)
    tree = Psych.parse_stream(text)
    raise Error unless tree.children.length == 1
    validate_yaml_nodes(tree)
    data = YAML.safe_load(text, permitted_classes: [], permitted_symbols: [], aliases: false)
    raise Error unless data.is_a?(Hash) && (data.keys - %w[preset high_risk mappings]).empty? && data['preset'] == 'rails_rspec'
    risk = data.fetch('high_risk', [])
    mappings = data.fetch('mappings', [])
    raise Error unless risk.is_a?(Array) && risk.all? { |pattern| valid_glob?(pattern) }
    raise Error unless mappings.is_a?(Array) && mappings.all? do |mapping|
      mapping.is_a?(Hash) && mapping.keys.sort == %w[source tests] && valid_glob?(mapping['source']) &&
        mapping['tests'].is_a?(Array) && !mapping['tests'].empty? && mapping['tests'].all? do |pattern|
          valid_glob?(pattern) && pattern.start_with?('spec/') && pattern.end_with?('_spec.rb')
        end
    end
    data
  rescue Error, Psych::Exception, SystemCallError, ArgumentError
    raise Error, 'invalid configuration'
  end

  def self.validate_yaml_nodes(node, depth = 0)
    raise Error if depth > 32 || node.is_a?(Psych::Nodes::Alias)
    if node.is_a?(Psych::Nodes::Mapping)
      keys = node.children.each_slice(2).map(&:first)
      raise Error unless keys.all? { |key| key.is_a?(Psych::Nodes::Scalar) }
      raise Error unless keys.map(&:value).uniq.length == keys.length
    end
    (node.children || []).each { |child| validate_yaml_nodes(child, depth + 1) } if node.respond_to?(:children)
  end

  # Intentionally small glob language: relative paths, *, ** and ? only.
  def self.valid_glob?(pattern)
    pattern.is_a?(String) && !pattern.empty? && pattern.match?(%r{\A[a-zA-Z0-9_.*?/-]+\z}) &&
      !pattern.start_with?('/') && pattern.split('/', -1).none? { |part| part.empty? || %w[. ..].include?(part) || part.start_with?('-') }
  end

  def self.glob?(pattern, file)
    File.fnmatch?(pattern, file, File::FNM_PATHNAME | File::FNM_DOTMATCH)
  end

  def self.parse_changes(output)
    fields = output.split("\0")
    changes = []
    until fields.empty?
      status = fields.shift
      count = status.start_with?('R', 'C') ? 2 : 1
      paths = fields.shift(count)
      raise Error, 'invalid git diff' unless paths.length == count
      changes << { status: status, paths: paths }
    end
    changes
  end

  def self.documentation?(file)
    file.match?(%r{\Adocs/.+\.(?:md|txt)\z}i) ||
      file.match?(%r{\A(?:README|CHANGELOG|CONTRIBUTING|LICENSE|CODE_OF_CONDUCT)(?:\.(?:md|txt))?\z}i)
  end

  def self.high_risk?(file)
    file == 'lib/ci_test_plan.rb' || file.start_with?('exe/', 'ci/') ||
      file.match?(%r{\A(?:config/|db/|\.github/|bin/|script/|(?:spec|test)/(?:support|factories|fixtures|shared_examples|shared_contexts)/|spec/(?:spec_helper|rails_helper)\.rb|test/test_helper\.rb|Gemfile|gems\.rb|gems\.locked|Rakefile|Dockerfile|package(?:-lock)?\.json|yarn\.lock|pnpm-lock\.yaml|[^/]+\.gemspec)})
  end

  def self.conventional_tests(file, tracked)
    candidates = []
    if file.match?(%r{\Aspec/.+_spec\.rb\z})
      candidates << file
    elsif (match = file.match(%r{\Aapp/(models|services|jobs|mailers|helpers|forms|policies|serializers|decorators|queries|value_objects|graphql)/(.+)\.rb\z}))
      candidates << "spec/#{match[1]}/#{match[2]}_spec.rb"
    elsif (match = file.match(%r{\Aapp/controllers/(.+)_controller\.rb\z}))
      stem = match[1]
      candidates << "spec/controllers/#{stem}_controller_spec.rb"
      %w[requests controllers features].each { |kind| candidates << "spec/#{kind}/#{stem}_spec.rb" }
    elsif (match = file.match(%r{\Alib/(.+)\.rb\z}))
      candidates << "spec/lib/#{match[1]}_spec.rb"
    elsif (match = file.match(%r{\Alib/tasks/(.+)\.rake\z}))
      candidates << "spec/tasks/#{match[1]}_spec.rb"
      candidates << "spec/lib/tasks/#{match[1]}_spec.rb"
    end
    candidates & tracked
  end
end
