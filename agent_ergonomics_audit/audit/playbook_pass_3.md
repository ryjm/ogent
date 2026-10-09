# Pass 3 implementation playbook — final 5d07d80

The user's second full implementation batch lands directly on `master` inside
`/workspace/ogent`. Baseline is `b3caf9300c7336ef812ed061158f851c5a47ccf7`. The final
verified production source is `5d07d807bc85a093725db24e33996b4af690ec0f`; local source checks are complete.
Eleven primary commits implement eleven tested external behaviors. Followup
repairs do not increase that count. No branch, PR, provider login or inference
was used.

## Implemented recommendations

| ID | Implemented behavior | Primary commit | Regression wrapper |
|---|---|---|---|
| R013 | Named approval-aware calls with typed outcomes | `2fbc156` | `audit/regression_tests/R013__named_calls.test.sh` |
| R014 | Bounded file pages with exact long-line continuation | `0829b08` | `audit/regression_tests/R014__structured_reads.test.sh` |
| R015 | Complete discovery through structured file pagination | `a1793a8` | `audit/regression_tests/R015__complete_glob_pages.test.sh` |
| R016 | Follow guarded tool continuations in one call | `e9c9af4` | `audit/regression_tests/R016__continuation_calls.test.sh` |
| R017 | Familiar exact verbs with collision-safe policy resolution | `a2b3922` | `audit/regression_tests/R017__common_verbs.test.sh` |
| R018 | Structured search and bounded real process outcomes | `1cde7ab` | `audit/regression_tests/R018__structured_processes.test.sh` |
| R019 | Async agent calls with one precise terminal callback and ledger | `3ced858` | `audit/regression_tests/R019__async_sdk.test.sh` |
| R020 | Preflighted batches of declared read-only calls | `974eb31` | `audit/regression_tests/R020__read_only_batches.test.sh` |
| R021 | Live callable contracts, executable examples and result schema | `d6263d1` | `audit/regression_tests/R021__live_contracts.test.sh` |
| R022 | Structured JSON contracts for registered model tools | `66bc5e8` | `audit/regression_tests/R022__model_json_contract.test.sh` |
| R023 | Actual build/test JSON with typed failures and recovery | `b974cd7` | `audit/regression_tests/R023__actual_build_reports.test.sh` |

The applied ledger preserves **33 exact selected primary source hunks** plus
full followup SHAs/hunks. Primary hunks compare each commit to its parent.
Retrospective `priority: 0` is explicitly unranked; empty expected-uplift maps
avoid inventing ex ante estimates.

## Paired measurements

Paired aggregation at `5d07d80` is **complete through incremental validation of
retained independent A/B/third readings**, rather than new blind full readings.
Across 19 original surfaces, mean **605.26 → 656.21**, all-surface median **+11**,
ten positively changed originals have median **+77.5**, and nine originals gain
at least 100 points on a dimension. No paired composite regressed. Six new APIs
remain unpaired; eleven overlapping upgrades do not establish eleven unique
causal numeric gains.

`evidence/pass_3/triangulation/aggregation.json` pins source/input hashes.
`evidence/pass_3/scorerA/incremental_query_guard/validation.json` distinguishes
`a2fa8ce` judgments from the verified `5d07d80` target. All 59 scorer numerical
vectors are retained. Two successful fresh probes produce 20 records (16 behavior,
four identity guards); 34 prior `ff4e96c` and 18 `b7b966c` execution records are
explicitly reused. Actual-gptel nested Unicode serialization was tested offline
on both runtimes in the reused `ff4e96c` evidence. Two initial query-probe harness
failures used empty fixture files; their transcripts/prefix records are preserved
and excluded from passing conclusions. Only the evidence fixture was corrected.
219 source citations are checked/refreshed; 353 prior runtime citations and 27
old build reports are reused with unchanged Makefile/makem bytes.

This is same-model rubric evidence with floored medians/equal-weight composites;
provider throughput/latency was not measured. Historical passes 1/2 retain all
38 original row values and historical scorecard/heatmap bytes. Build JSON credit
covers historical help/compile/recompile and lint/test/runner extensions. The
unchanged `make offline-test` target receives no build-JSON output credit.

## Behavioral proof

`verification/pass_3/regression_proof.json` is **complete at `5d07d80`**: all
11 wrappers genuinely exit 1 on `b3caf93` and exit 0 on the final source, with no
timeouts or skipped current ERT tests. It preserves source/fixture identities,
expected selections, actual counts and full transcript hashes.

| ID | Baseline executed / exit | Current executed / exit | Unit |
|---|---:|---:|---|
| R013 | 58 / 1 | 58 / 0 | ERT tests |
| R014 | 4 / 1 | 4 / 0 | ERT tests |
| R015 | 5 / 1 | 5 / 0 | ERT tests |
| R016 | 3 / 1 | 3 / 0 | ERT tests |
| R017 | 2 / 1 | 2 / 0 | ERT tests |
| R018 | 51 / 1 | 55 / 0 | ERT tests |
| R019 | 10 / 1 | 10 / 0 | ERT tests |
| R020 | 7 / 1 | 7 / 0 | ERT tests |
| R021 | 3 / 1 | 3 / 0 | ERT tests |
| R022 | 10 / 1 | 10 / 0 | ERT tests |
| R023 | 1 / 1 | 23 / 0 | Shell runner cases |

R018 baseline stops after the 51 process tests; current runs those plus four SDK
integrations. R023 fails on its first baseline report case and completes 23 real
current shell-runner cases. ERT/shell counts are separate units, and overlapping
selectors do not establish unique totals or causal score attribution.

Proof integrity and recorder controls are **complete at `5d07d80`**.
`verification/pass_3/regressions/integrity_check.json` validates 22 transcripts,
47 input hashes, Git source/fixture identity, exact executed selections and zero
skips/timeouts. `recorder_validation.json` records all six negative controls
rejected. Historical proof bytes remain unchanged. Earlier snapshot proofs stay
separate under `interim-b7b966c/`, `interim-ff4e96c/` and `interim-021cca4/`.

## Correctness repairs

`967eb05` aligns GNU/ripgrep candidate ordering, file-link and directory-link
scope, raw-NUL binary classification and Unicode glob filtering. Classifier and
text reads remain under the existing process timeout/cancel/cleanup owner.

`10f86bb` retains completed data through terminal ledger storage failure, delivers
one callback, preserves an existing `error.tool_error` and exposes recovery that
warns against rerunning completed effects. `a2fa8ce` captures each call's copied
absolute ledger destination and enabled state, binding only recording. Tools and
callbacks retain ambient context; changed settings apply to future calls. Real
completion faults at the captured path retain data and streaming cleanup; failed
start recording prevents effects. Filesystem failure does not guarantee durable
terminal persistence. Focused `a2fa8ce` evidence records 213+4 passing tests per
supported runtime in `evidence/pass_3/ledger_context/results.json`.

`021cca4` fixes batch docstring/checkdoc hygiene and consumes the Unicode
validation serializer result so compiled code retains validation. `ff4e96c`
validates matching structured glob paths before regular-file metadata filtering;
physical undecodable filenames now produce `unsupported_output` instead of an
empty list. Legacy glob behavior keeps its existing optional validation policy.
A shared JSON text helper decodes UTF-8 serializer bytes when Emacs returns an
unibyte string, preserving nested Unicode through result/model transport and
doctor JSON output.

`evidence/pass_3/raw_filename_glob/repair_summary.json` pins scoped strict
compilation, checkdoc, canonical indentation and **5/5 compiled boundary ERT tests
on both Emacs 29.1 and 30.2**, with zero skips/unexpected results. Physical byte-FF
glob reproduction fails against real `021cca4` on both versions. The initial
new-test indentation validation failure remains recorded. Two SDK regressions
cover raw glob sync plist/JSON and callback-once flat/recursive/excluded-Unicode
behavior, plus nested Unicode tool/doctor JSON. An actual-gptel offline regression
covers the tool FSM and provider-request serializer. Offline probes exercise
constructor/process-call/parser/encoder behavior with **zero provider traffic,
authentication or inference**; they do not certify live provider transport.

`b7b966c` validates resolved structured glob/search roots before enumeration or
target classification, including explicit/default empty or excluded raw-byte
directories. Glob also validates its reflected pattern. Unsupported values now
produce the same typed refusal in native plist, JSON and async callback-once
paths, while valid Unicode roots retain actual nonempty counts. Two new SDK
regressions fail on real `ff4e96c` on both runtimes. Scoped strict compilation,
checkdoc, canonical indentation and **9/9 compiled boundary tests pass on both
Emacs versions**; `evidence/pass_3/raw_root_contract/` preserves before/after
source evidence and logs. These remain scoped checks, not full native gates.

`5d07d80` validates structured search patterns and non-null filters as Unicode
before target/query execution, keeping reflected continuation arguments usable
in native and JSON formats. A new SDK regression covers matching/nonmatching raw
queries in sync plist/JSON and async callback-once paths with no process started;
a valid Unicode pagination control still works. The actual before-query test
fails on `b7b966c` on both runtimes. Scoped strict compilation, checkdoc, canonical
indentation and **10/10 compiled boundary tests pass per runtime**. The initial
new-test syntax harness failure is preserved separately and excluded from product
proof. See `evidence/pass_3/raw_query_contract/`.

## Review and native gates

Rounds 14 and 15 are **two consecutive CLEAN independent reviews on `5d07d80`**,
with no intervening source edits and unchanged hashes of all 241 guarded tracked
files. Round 14 records 54 passing ERT invocations across Emacs 29.1/30.2,
including explicitly loaded warning-strict bytecode and actual current/minimum
gptel probes. Round 15 records 68 passing ERT invocations and two actual build
discovery/invalid-task contracts. Both have zero unexpected/skipped final ERT
results. Actual gptel serialization probes send no provider/loopback requests.

See `phase7_pass_3_review_round14.md`, `phase7_pass_3_review_round15.md` and
`evidence/pass_3/review_round15/verification-summary.json`. Round 15 preserves two
initial harness parse failures that selected no ERT tests; these are excluded
from passing/product conclusions and required only evidence-fixture correction.
Earlier raw filename/root/query findings remain recorded in unclean rounds
11/12/13; earlier CLEAN rounds 9/10 remain historical at `a2fa8ce`.
Round 10 preserves its two initial evidence-fixture allow-rule failures and all
218 final passing executions; these were not product defects or source repairs.

The final native matrix is **8/8 PASS on `5d07d80`**, completed
2026-10-08 23:59:45.035719 UTC after the two clean reviews. Start/end source SHA
and fingerprints match. [Native check records](verification/pass_3/native_checks.json)
preserve exact argv and sixteen lossless gzip transcripts with raw/gzip hashes.

| Actual native check | Total ERT | Expected | Unexpected | Skipped |
|---|---:|---:|---:|---:|
| Emacs 30.2 `make test` | 3236 | 3218 | 0 | 18 |
| Emacs 30.2 store isolation | 3236 | 3218 | 0 | 18 |
| Emacs 29.1 store isolation | 3236 | 3217 | 0 | 19 |
| Emacs 30.2 offline, current gptel | 206 | 204 | 0 | 2 |
| Emacs 30.2 offline, minimum gptel | 206 | 204 | 0 | 2 |
| Emacs 29.1 offline, current gptel | 206 | 203 | 0 | 3 |
| Emacs 29.1 offline, minimum gptel | 206 | 203 | 0 | 3 |

The eighth check, Emacs 30.2 warning-strict lint, passes. Actual `make test` uses
`--no-compile` after successful strict lint compiled the same frozen source;
the complete ERT selection remains intact. Both isolation runs show no real-store
drift. Offline runs use actual gptel 0.9.9.6/current and 0.9.9.5/minimum, Org
9.8.10 and transient 0.13.8. These native skips are disclosed separately from
the zero-skipped focused proofs/reviews. Provider requests, authentication and
inference remain zero.

The earlier `a2fa8ce` **7/8** result and lint failure remain intermediate evidence
in `verification/pass_3/native_checks_interim_a2fa8ce.json` and
`native_interim_a2fa8ce/`. Local source verification is complete. Direct push and
remote CI remain pending; their actual outcomes must be verified after push.

## Practical task evidence

The original fresh source-blind exercise completed **9/9** tasks, **7/9** with
the first strategy, in **94** defined public round trips, mostly at `07f775a` with
batch `895bed7`. The seven-line README exercise accounts for 63 calls. Its
preserved summary supports no comparative efficiency claim.

The familiar `5d07d80` replay is complete **9/9** in **89** known-workflow round
trips, with ten actual command records, identical source SHA and clean start/end
path guards. It reuses tasks/fixtures, so has no fresh first-strategy or comparative
efficiency metric. `agent_simulations/post_pass_3/final_freeze/summary.json`
records actual SDK/build calls, including expected compiler/ERT failure exits
with typed source positions. The prior `b7b966c` replay is preserved with all
40 files, and 343 historical artifacts remain byte-identical. GNU fallback and
protected gptel doubles were observed; minimal independent fixtures execute real
makem compilation/ERT. This does not certify native gates or live providers.

## Using the implemented surfaces

Use live describe/schema/capabilities and the guide for call shapes. Use
`ogent-agent-call` for named policy-aware execution, `ogent-agent-next` for returned
guarded continuations, `ogent-agent-call-async` for callback delivery and
`ogent-agent-batch` for up to 20 declared read-only calls. Select JSON explicitly.
Actual build JSON uses `makem.sh --json` or `make TASK format=json`; doctor remains
a separate surface. Read the regression recorder's help, bind exact freeze/tool
paths from its manifests and use actual supported Emacs/local dependencies.

Prior `10f86bb` and `a2fa8ce` scoring/audit snapshots remain archived with hash
indexes in `evidence/pass_3/interim_*_archive.json`. The `021cca4` proof archive
records its complete files and hashes. `evidence/pass_3/source_fixture_archives.json`
records 12 archives/408 source and fixture members. Raw `.el` copies stay ignored
because makem discovers tracked files with `git ls-files`. Ledger-context old
modules remain losslessly archived with `baseline-source-archive.json` hashes.

Persistent crash-resume tokens, dependent batches and transport redesign remain
future feature work. Exact aliases do not execute fuzzy guesses automatically;
structured results reject undecodable selected filenames explicitly. Snapshot guards reject changed
pages without promising filesystem transactions. Provider-backed throughput or
latency was not measured. Any substantive review finding requires a corrected
freeze and rerunning dependent verification.
