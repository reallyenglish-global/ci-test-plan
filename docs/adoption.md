# Adoption and validation

## Scope

This package plans CI test selection. It does not execute tests, prove complete
transitive dependency coverage, or certify a successful CI run. A requested
smoke, E2E, or performance level is not evidence that those suites exist or ran.
The initial mapping preset targets Rails and RSpec; other stacks require their
own reviewed mappings.

Application repositories retain ownership of CI jobs, required status checks,
service setup, environment secrets, deployment, test execution, and release
policy. There is no automatic release or deployment workflow in this project.

## Safe rollout

1. Pin an immutable gem source revision or released version. Run the planner
   against exact base and checked-out head commits with complete Git history.
2. Start in shadow mode: archive the JSON plan while continuing the existing
   full suite. Compare planned selections with full-suite outcomes.
3. Exercise representative changes to models, controllers, shared code,
   dependencies, migrations, CI, test infrastructure, and documentation.
4. Independently review policy changes and unknown-path behavior. Direct file
   mappings alone can miss callers of shared code; add high-risk patterns for
   application-specific shared components. Keep release validation full.
5. Only then wire selective execution, retaining periodic full runs and an
   always-reporting required check. A planner error must fail the gate or
   explicitly trigger the full suite, never turn into a successful skip.

A planner change cannot make existing CI disappear: preserve security and
lint jobs and validate the job dependency graph before adoption. Treat JSON
fields as data, not shell commands; invoke selected paths as separate arguments.
Reject stale plans whose tested commit differs from the executor checkout.

## Initial consumer candidates

REX and Turtle both use RSpec. They are suitable pilot candidates, not certified
integrations. Publishing this gem does not modify either application's CI.
REX's existing planner and escalation policy should be compared against the
gem before replacement; Turtle needs its own policy inventory and shadow run.
Retry handling and result-cache reuse are intentionally outside this package.
