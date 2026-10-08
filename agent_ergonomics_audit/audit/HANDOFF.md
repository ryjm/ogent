# Agent ergonomics handoff

The focused pass implemented twelve tested recommendations on master. It
adds JSON capabilities, a built-in agent guide, local triage, versioned JSON
doctor reports, safer argument/edit contracts and honest build/tool failures.
The SDK/build audit covers nineteen surfaces; Armory UI, live providers and
production-security certification are outside its scope. No provider login
or inference request was required.

Baseline: `72016bb66928a20a49238266645abde583fa595d`. Final verified production
source: `390a25c2c4cd874b0f665500a9fc6842ff3472ec`.
The subsequent handoff commit adds audit/tracker artifacts;
production remains at that freeze. This is implementation pass 1 followed by
measurement pass 2, not two separate development branches.

## What changed

- Grep quotes individual arguments, accepts literal leading-dash patterns,
  distinguishes invalid regex/path failures from no matches, and reports stable
  result counts with diagnostics kept apart.
- Recursive glob includes zero and deeper directory levels, matches exact case,
  and resolves equal-mtime ordering by path. Reads reject invalid bounds and
  state exact next-page arguments and truncation.
- Edits require nonempty exact context and reject ambiguous matches unless
  replace_all is explicitly true. UI review/accept failures preserve an error
  state with recovery; reviewed relative paths retain their original target.
- Shared validation rejects missing, unknown, duplicate, mistyped or out-of-range
  arguments before approval/execution. Native false, MCP JSON false, omitted
  optional values, zero, nested objects and exact declared field names retain
  their intended meaning. Registry wire aliases honor exact custom names and
  the same approval rules. Typos produce corrections without fuzzy execution.
- Shell calls validate before process creation, retain bounded callback prefixes
  and complete terminal output/status. Recompile respects selected Emacs and
  propagates failure; clean removes source and test bytecode. Offline tests
  explain missing prerequisites before creating fixtures.

[Applied changes](applied_changes.jsonl) contain primary/follow-up commits,
actual before/after diff excerpts and a regression wrapper for every fix.

## Measured outcome

The mean of nineteen surface scores changes from **513.6 to 676.9**;
median surface uplift is **143 points**. Every paired surface improves
at least one dimension by 100 points. These are qualitative same-model peer
scores, not statistically independent measurements or a readiness certificate.
Scores remain below 750 on many surfaces; text output and absent direct SDK
method aliases remain visible deficiencies.

Two independent scorers assessed each state; third reviews resolve large
disagreements. Per-dimension medians and weighted means are floored to integers.
All original/interim raw partials and original baseline aggregate are archived.
Final paired calibration changes baseline compile composability 500→250 to match
actual unchanged makem, lowering the baseline mean from 514.8 to 513.6. That is a
disclosed scoring correction, not product improvement. See
[rubric reconciliation](rubric_reconciliation_post.md) and
[regression investigation](regression_alerts.md).

Fresh-context simulations completed all seven canonical goals before and after,
with first-strategy successes 4→5 and median round trips 3→2. Different batching
and a build fixture workaround limit the comparison. The simulation ran during
review repairs and is not exact-final-SHA proof. Native checks below cover the
final source. [Comparison and limits](simulation_comparison.md) link transcripts.

## Verification

All twelve recommendation wrappers genuinely fail on archived original source
and pass on the final source. The baseline empty-context edit loop is bounded
by an eight-second timeout; other negative tests record actual failing
assertions. [Proof](verification/regression_proof.json) retains argv, statuses
and complete logs; it does not confuse a collector's exit 0 with SDK success.

Final local checks use Emacs 29.1 and 30.2. Full suites run 3,119 tests each, with
3,100/3,101 expected results and 19/18 explicit environment-dependent skips;
zero unexpected failures and no real-store drift. Required make lint and
make test pass. Four actual-dependency offline runs pass on current gptel
0.9.9.6 and minimum v0.9.9.5: 204 tests each, 202 expected results on Emacs 30
and 201 on Emacs 29, with 2/3 skips. [Native records](verification/native_checks.json)
include actual process exit codes, dependency versions and transcripts.

Ten fresh-eyes rounds fixed five reviewer findings and root follow-ups.
Rounds 9 and 10 are consecutively clean on the final production freeze, with
critical contracts verified on both Emacs versions. The
[review log](phase7_fresh_eyes_log.md) contains all three calibrated prompts,
findings and evidence. The [ambition self-check](ambition_bar_check.md) records
the expanded application batch and remaining limits.

The first remote run on 0e4e901 exposed a locale-dependent error-advice bug:
Emacs rendered the apostrophe in the doctor correction as a Unicode curly quote.
Local LC_ALL=C checks had not exposed this default rendering difference. The
follow-up uses the quote-free `(quote json)` form and pins curve, straight and
grave styles. Historical numerical score anchors are retained; final native
and fresh-eyes verification is repeated at the updated production freeze.
The failed-job evidence is preserved in evidence/ci-quote-style-failure.log.

Publication uses a direct master push; the exact pushed SHA's CI must pass
before the session ends, as required by AGENTS.md. The final conversation
records that remote result after the handoff commit exists.

## Remaining scope and rubric cautions

Tool read/search/shell results still use existing text contracts. New JSON
interfaces describe discovery and doctor/triage data, not arbitrary subprocess
output. The makem logger retains human colors/timestamps and lacks complete
machine reporting; a replacement stub proves forwarding only. Low-level
mutators are trusted private APIs; registered execution owns approval. Async
metadata describes the primary registered call shape; streaming helper
variants are not separately enumerated. Pure unknown lookup can still return
nil, and Make typos may yield generic inherited failures.

Future rubric work should distinguish SDK method aliases from parameter
correction, regenerable bytecode from irreversible user state, raw trusted
helpers from policy-owning wrappers, and actual delegated logging from stub
recipes. Always calibrate both snapshots and retain scorer coverage/history.

## Pass N+1 focus

Two nonblocking feature follow-ups are tracked separately from the completed
twelve-fix epic: ogent-v2fp defines versioned structured read/search results
and consumer migration; ogent-lkvs defines machine-readable build/test reports
and actual logger stream discipline. Both require coordinated output-contract
work, so the focused pass preserves existing consumers and records the limits.
Use this manifest, the SDK extension and archived evidence to resume on master.
