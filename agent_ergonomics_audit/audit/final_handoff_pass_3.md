# Pass 3 handoff — final 5d07d80

Ogent now supports named approval-aware calls with typed outcomes, bounded complete
read/search pages, guarded continuations, exact familiar aliases, callback-once
async calls and preflighted batches of up to 20 declared read-only calls. Live
schemas/examples describe callable shapes; registered model tools can return
structured JSON; actual makem build/test tasks expose typed JSON failures.

Completion ledger faults retain completed tool data and an existing tool error,
deliver one storage warning and advise against rerunning completed effects. Each
call records to its captured absolute ledger destination/enabled setting, while
tools and callbacks retain ambient context. Structured glob/search refuse raw-byte
names, roots, reflected patterns and filters consistently across native plist,
JSON and async paths. Nested Unicode survives actual gptel request serialization.

The second full implementation batch contains **eleven tested behavior upgrades,
R013–R023**. Baseline is `b3caf9300c7336ef812ed061158f851c5a47ccf7`; final production
source is `5d07d807bc85a093725db24e33996b4af690ec0f` on `master`. Followup repairs
remain part of these eleven recommendations. Local source verification is
complete. Direct push and remote CI remain pending and must be verified after push.

## Completed verification

The [native matrix](verification/pass_3/native_checks.json) is **8/8 PASS**, completed
2026-10-08 23:59:45.035719 UTC on the identical frozen source and fingerprint.
It records exact argv and sixteen lossless gzip transcripts with raw/gzip hashes.

| Actual check | Total ERT | Expected | Unexpected | Skipped |
|---|---:|---:|---:|---:|
| Emacs 30.2 `make test` | 3236 | 3218 | 0 | 18 |
| Emacs 30.2 store isolation | 3236 | 3218 | 0 | 18 |
| Emacs 29.1 store isolation | 3236 | 3217 | 0 | 19 |
| Emacs 30.2 offline, current gptel | 206 | 204 | 0 | 2 |
| Emacs 30.2 offline, minimum gptel | 206 | 204 | 0 | 2 |
| Emacs 29.1 offline, current gptel | 206 | 203 | 0 | 3 |
| Emacs 29.1 offline, minimum gptel | 206 | 203 | 0 | 3 |

The eighth check, Emacs 30.2 warning-strict lint, passes. Full `make test` uses
`--no-compile` after successful lint compiled the same source, retaining the full
ERT selection. Isolation shows no real-store drift. Offline runs use actual
gptel 0.9.9.6/current and 0.9.9.5/minimum, Org 9.8.10 and transient 0.13.8.
Native skips above remain distinct from zero-skipped focused proofs/reviews.

[All eleven regression wrappers](verification/pass_3/regression_proof.json)
genuinely exit 1 on the baseline and 0 on final source, without timeouts or
skipped current ERT tests. Current ERT counts are 58, 4, 5, 3, 2, 55, 10, 7,
3 and 10 for R013–R022; R023 completes 23 actual shell-runner cases. R018 baseline
stops after its failing 51-test process suite; current also executes four SDK
integrations. R023 baseline stops at its first failing case. Selectors overlap;
ERT and shell counts are separate units, with no invented unique total.
[Integrity checks](verification/pass_3/regressions/integrity_check.json) validate
22 transcripts and 47 input hashes; [recorder controls](verification/pass_3/regressions/recorder_validation.json)
reject all six corrupted/false-proof controls. Twelve source/fixture archives
with 408 members have verified hashes; original historical proof bytes remain intact.

Independent [round 14](phase7_pass_3_review_round14.md) and
[round 15](phase7_pass_3_review_round15.md) are consecutive **CLEAN** reviews on
this same source, with all 241 guarded tracked file hashes unchanged. Their
54 and 68 passing ERT invocations span Emacs 29.1/30.2, explicit warning-strict
bytecode and actual current/minimum gptel; round 15 also executes two real build
discovery/invalid-task contracts. Final selected tests have zero skips/unexpected
results. Initial evidence-harness parse errors are retained separately and
excluded from passing/product conclusions.

## Measured outcome

[Paired scoring](evidence/pass_3/triangulation/aggregation.json) covers 19 original
surfaces: mean **605.26 → 656.21**, all-surface median **+11**, ten positively
changed originals median **+77.5**, and nine originals gaining at least 100 on
a dimension. No paired composite regressed. Six new APIs are current-only;
eleven shared-surface upgrades do not establish eleven unique causal numeric gains.
The all-surface median remains below the ambition bar's 50-point trigger; the
mandatory larger apply round is complete with that limit stated explicitly.

The [incremental validation](evidence/pass_3/scorerA/incremental_query_guard/validation.json)
retains all 59 numerical A/B/third-reader vectors from `a2fa8ce`, with fresh
behavior/identity probes and explicit reuse of prior unchanged executions.
It is not a new blind full scoring. It refreshes/checks 219 source citations and
explicitly reuses 353 runtime citations/27 build reports under byte identity.
Original passes 1/2 preserve all 38 row values and scorecard/heatmap bytes.
Build JSON credit covers help/compile/recompile and lint/test/runner extensions;
unchanged `make offline-test` receives no build-JSON output credit.

The [known-task final replay](agent_simulations/post_pass_3/final_freeze/summary.json)
completes **9/9** tasks in **89** defined known-workflow round trips, with ten
actual command records and clean source guards. Intentional compiler/ERT failures
produce the expected typed positions. Original fresh source-blind evidence
remains 9/9 tasks, 7/9 first strategy and 94 round trips at earlier source.
Reused tasks provide no fresh first-strategy or comparative efficiency claim.
GNU fallback and protected gptel doubles are disclosed; actual independent
makem fixtures and actual offline gptel serialization are also exercised.

## Evidence and scope

[Recommendations](recommendations_pass_3.jsonl) and
[applied changes](applied_changes_pass_3.jsonl) preserve all eleven IDs, primary
commits, Beads, dimensions, regression evidence and exact source hunks.
[Readable hunks](recommendation_hunks_pass_3.md) retain 33 primary and 20 distinct
correctness followup hunks. [Playbook](playbook_pass_3.md) documents call shapes
and repair evidence; [ambition record](ambition_bar_pass_3.md) preserves the
mandatory verbatim self-prompt and numeric limits.

Earlier native `a2fa8ce` 7/8 lint failure and genuine raw filename/root/query
findings in unclean rounds 11/12/13 remain archived. Their warning hygiene and
Unicode consistency repairs are included in final source. Original evidence,
including corrected harness mistakes, remains inspectable.

No provider traffic, login, authentication or inference was used. Actual gptel
constructor/FSM/parser/encoder work is tested offline. Provider throughput/latency,
persistent crash-resume tokens, dependent batches and transport redesign remain
outside the completed scope. Snapshot guards detect changed pages without
promising filesystem transactions; exact aliases preserve registered-name
precedence and never execute fuzzy guesses automatically.
