# ci-test-plan

Conservative, explainable CI test planning for Rails/RSpec repositories.

`ci-test-plan` compares exact Git commits, finds conventionally related specs,
and emits a deterministic JSON plan with a minimum required test level. It does
not boot Rails, execute application code, run tests, or prove complete dependency
coverage. No runtime gem dependencies. Ruby 3.2+ and Git required.

## Install

The source is available on GitHub; a RubyGems.org release is not required:

```ruby
# Gemfile: replace the placeholder with a reviewed full commit SHA.
gem 'ci-test-plan', git: 'https://github.com/reallyenglish-global/ci-test-plan',
                    ref: '<reviewed-full-commit-sha>', require: false
```

Or build and install locally:

```sh
gem build ci-test-plan.gemspec
gem install --local ci-test-plan-0.1.0.gem
ci-test-plan --help
```

## Plan a change

Use a stable isolated checkout with complete Git history. The head must equal
the checked-out commit; tracked files and the index must be clean.

```sh
ci-test-plan plan --base origin/main --head HEAD --type bugfix
ci-test-plan plan --base origin/main --type chore --labels ci:full
ci-test-plan plan --base origin/main --type feat --config config/ci-test-plan.yml
```

The base is resolved to an immutable commit, then the diff is taken from its
merge-base with head. Untracked and ignored files are not included: use clean,
committed CI checkouts, not a working development tree with runtime additions.
Sparse and assume-unchanged checkouts are unsupported. Repositories with
configured Git clean, smudge, or process filter drivers are rejected before
status checks, including Git LFS and unused globally configured drivers, because
those drivers can execute commands or normalize away runtime-file differences. Missing refs/history, dirty tracked inputs, and invalid
configuration are errors, not successful skips.

Library API:

```ruby
require 'ci_test_plan'
plan = CITestPlan.plan(base: 'origin/main', head: 'HEAD', root: Dir.pwd,
                       change_type: 'bugfix', labels: ['ci:smoke'])
puts plan.fetch(:mode)
```

The JSON contract (`schema_version: 1`) includes:

- `base_sha`, `head_sha`, `merge_base_sha`: immutable selection context.
- `changed_files`: sorted paths, including both sides of renames.
- `selected_tests`: sorted, tracked, safe affected-spec candidates.
- `mode`: `skip`, `affected`, or `full`.
- `required_level`, `level_name`: minimum coverage required by policy.
- `reasons`: sorted explanation codes.

**Interpret both mode and required level.** `skip` only means no affected subset;
it does not waive smoke or another required gate. `full` requires the full suite;
`selected_tests` is supplemental information, not a full-suite inventory.
Valid plans, including full-suite fallback, exit 0. Invalid CLI input/state exits
2, emits no stdout, and prints a content-free error. Library errors raise
`CITestPlan::Error`. The planner never reports that any tests passed.

## Risk levels

- 0 `static`: static checks; documentation-only chores can remain here.
- 1 `affected`: conventionally mapped specs.
- 2 `smoke`: features and user/API bug fixes require smoke coverage.
- 3 `full`: unknown change types, high-risk paths, and uncertain selection.
- 4 `full_e2e`: complete browser E2E coverage.
- 5 `performance`: performance/regression coverage; release changes require this.

Change types: `chore`, `bugfix`, `feat`, `unknown` (default), `release`.
Escalation labels: `ci:static`, `ci:affected`, `ci:smoke`, `ci:full`,
`ci:full_e2e`, `ci:performance`. Labels cannot reduce required coverage.
The caller must classify the event: use `release` for release/promotion policy;
the gem does not infer GitHub branch or event semantics.

Dependencies, database/configuration, CI, and shared test infrastructure escalate
to full coverage. Unmapped source changes, missing conventional specs,
non-document deletions/renames, symlinks, and unsafe paths also require full.
This is filename-based selection, not a transitive Ruby dependency graph. Shared
application components can affect tests outside their conventional directory;
mark them high-risk and retain periodic and release full-suite runs.

## Configuration

Configuration is opt-in and must be a committed, regular, non-symlink file inside
the checkout. Unknown keys, duplicate keys, aliases, unsafe patterns, and invalid
values fail closed. Limits: 64 KiB and YAML nesting depth 32.

```yaml
preset: rails_rspec
high_risk:
  - app/services/billing/**
mappings:
  - source: app/models/*.rb
    tests:
      - spec/integration/*_spec.rb
```

The preset maps conventional `app/models`, `app/services`, `app/jobs`, and other
Rails component directories to equivalent `spec/` paths; controller changes
select existing controller/request/feature counterparts. `lib/PATH.rb` maps to
`spec/lib/PATH_spec.rb`; Rake tasks map to task specs. Changed
`spec/**/*_spec.rb` files select themselves. Documentation skipping is limited
to `.md`/`.txt` files under `docs/` and the root README, CHANGELOG, CONTRIBUTING,
LICENSE, and CODE_OF_CONDUCT names (bare or `.md`/`.txt`). Other files under
`docs/` are not automatically safe to skip.

Mappings **add** tests; they cannot rescue an otherwise unmapped change from full
fallback. `high_risk` only escalates, and edits to the configuration itself force
full coverage. Patterns are relative paths with `*`, `**`, or `?`; no regular
expressions, interpolation, executable Ruby, parent traversal, or shell syntax.
Test patterns must begin `spec/` and end `_spec.rb`.

## CI integration

Start in shadow mode: keep existing full validation and archive the plan.
A planning step can run after Ruby/gem installation and checkout with full history:

```sh
# CI_BASE_SHA and CI_HEAD_SHA come from trusted event metadata, not shell source.
bundle exec ci-test-plan plan --base "$CI_BASE_SHA" --head "$CI_HEAD_SHA" \
  --type unknown > "$RUNNER_TEMP/test-plan.json"
```

Check the exit status before consuming JSON. Do not convert planner failure into
success or an empty test list. Check `head_sha` against the executor checkout.
Pass selected tests as separate argv values, never evaluate them as shell code.
Keep lint/security gates and independently enforce smoke/E2E/performance levels.
No GitHub Action wrapper or automatic CI replacement is shipped in this version.

See [adoption guidance](docs/adoption.md). REX and Turtle are candidate consumers,
not certified integrations; this repository does not change their workflows.

## Development and license

```sh
bundle install
bundle exec rake test
```

Tests use synthetic Git repositories, including real gem build/install/CLI
execution. CI tests Ruby 3.2, 3.3, 3.4, and 4.0. See
[CONTRIBUTING.md](CONTRIBUTING.md). Licensed under [MIT](LICENSE).
