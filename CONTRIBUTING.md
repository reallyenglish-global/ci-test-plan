# Contributing

Use Ruby 3.2 or newer and Git. Run `bundle install`, then `bundle exec rake test`.

Add a failing regression before changing behavior. Tests should use temporary,
synthetic Git repositories; do not commit private application code, secrets,
customer information, internal logs, or production fixtures.

Selection is conservative, not a proof of dependency coverage. New mappings
must not silently weaken high-risk escalation or unknown-file fallback. Plans
must be deterministic, tied to the tested commit, and distinguish requested
coverage from tests that actually ran. Avoid application boot and runtime gems.

Please report security issues privately to the maintainers through GitHub's
private vulnerability reporting if enabled; do not post credentials in issues.
