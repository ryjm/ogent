# ogent agent ergonomics audit

This in-repository audit applies JSM's agent ergonomics skill to 19 primary
Emacs Lisp SDK and Make surfaces. It covers the six built-in tools, their
registry/execution boundary, local doctor APIs and build/test commands.
It is a focused pass; Armory UI flows and provider inference are outside scope.

Read [the handoff](audit/HANDOFF.md), [scorecard](audit/scorecard.md),
[paired changes](audit/uplift_diff.md), and [review log](audit/phase7_fresh_eyes_log.md).
The [manifest](audit/manifest.json) distinguishes the implementation pass from
its post-change measurement. Scores are qualitative same-model peer judgments,
with explicit applicability reconciliation and archived original measurements.

The machine-readable trail includes the surface inventory, scores, observed
intent corpus, twelve recommendations and applied-change commit references.
`audit/verification/` contains actual native exit codes and genuine
baseline-fail/post-pass regression proofs. `audit/triangulation/` preserves
historical scorer records; `audit/evidence/` archives decisive probes.
Temporary fixtures, baseline source extraction and scaffolding templates are
ignored. No credentials are needed for the workflows below.

With Emacs and the supported dependencies available, use `make lint`,
`make test`, `make test-isolation`, and
`OGENT_ELPA_DIR=/path/to/elpa make offline-test`. To replay a targeted
improvement, run `bash audit/regression_tests/R-001__grep-errors.test.sh`
from this directory, selecting `EMACS` when needed. The regression runner
accepts `OGENT_AUDIT_SOURCE` for an extracted historical source root.

The exact rubric hash and skill version are recorded in the manifest/scope.
The installed skill's Bash scripts aggregate, validate, render and diff the
audit files; there is no standalone ogent binary. Future passes should retain
the SDK adaptation, work on `master`, and preserve the historical evidence.
