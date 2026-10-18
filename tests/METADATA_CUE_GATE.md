# Metadata and CUE non-writing release gate (v0.1)

This is an original, public, stdlib-only **validator**, not a metadata editor.
The gate accepts only opaque `synthetic:` artifact IDs, never media paths.
Its three mutually exclusive scopes are `physical_tags`, `embedded_cue`,
and `external_cue`. The scope in a decision authorizes **no other scope**.

Consumers construct a change plan containing SHA-256 before/after digests,
explicit boolean `intended_write` and `approved`, and provenance with
`source` (`user_review` or `licensed_public`), nonempty `reference`,
and `license_cleared: true`. Unchanged bytes MUST be `NO_OP` and
`intended_write: false`. Changed bytes require approval; a passing plan
returns `REVIEWED_CHANGE`, but **does not perform or authorize a real write**.

Run `python3 -m unittest discover -s tests -p 'test_*.py'`.
These synthetic tests are not a substitute for product-specific CUE parsing,
tag preservation, real DB backup, third-party license audits, or Windows UI
qualification. Integration into consumers requires separate review.
