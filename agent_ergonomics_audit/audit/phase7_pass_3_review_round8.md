# Phase 7, pass 3, independent review round 8

**Verdict: NOT_CLEAN — one substantive finding, zero trivial findings.**

Inputs: target `/workspace/ogent`, sibling `/workspace/ogent/agent_ergonomics_audit`, branch `master`, baseline `b3caf9300c7336ef812ed061158f851c5a47ccf7`, frozen source `10f86bb12a03f3122a60ba085be7289eb5277f5e`.

Source review was read-only. This reviewer owns this report and `audit/evidence/pass_3/review_round8/` only; no source, tests, documentation, index, or commits were changed. The finding was routed to root for sole repair. Historical clean rounds do not count toward the current clean streak.

## Calibrated prompts applied verbatim

1. "Carefully read over all of the new code you just wrote and other existing code you just modified with 'fresh eyes' looking super carefully for any obvious bugs, errors, problems, issues, confusion, etc. Carefully fix anything you uncover."
2. "Sort of randomly explore the code files in this project, choosing code files to deeply investigate and trace their functionality and execution flows through the related code files which they import or which they are imported by. Once you understand the purpose of the code in the larger context of the workflows, do a super careful, methodical, and critical check with 'fresh eyes' to find any obvious bugs, problems, errors, silly mistakes. Comply with ALL rules in AGENTS.md and ensure that any code you write or revise conforms to the best practice guides referenced in AGENTS.md."
3. "Turn your attention to reviewing the code written by your fellow agents and checking for any issues, bugs, errors, problems, inefficiencies, security problems, reliability issues. Diagnose underlying root causes using first-principle analysis. Don't restrict yourself to the latest commits — cast a wider net and go super deep."

Instructions read: target `AGENTS.md`; `specs/architecture.org`, `specs/feature-playbooks.org`, `specs/style-guide.org`, and `specs/gptel-integration.org`; installed skill `SKILL.md`, methodology `PHASES.md` Phase 7, and `subagents/fresh-eyes.md`. The assignment's sole-repair coordination overrides the skill's reviewer-edit/commit steps.

## Substantive finding

**F8-1: Relative ledger destinations drift between asynchronous start and finish.**

Location at freeze: `lisp/ogent-tool-execution.el:201` (`ogent-tool-execution--start`, terminal recording at lines 216–219; start at line 223), with destination resolution in `lisp/ogent-ledger.el:44`. The legacy async completion owner at `lisp/ogent-tool-execution.el:382` and streaming owner at `lisp/ui/ogent-ui-toolcalls.el:144` also invoke finish recording without retaining the start destination.

The native SDK reproducer provisions two real sanctioned storage directories A and B, enables the ledger with relative `ogent-ledger-file` `"ledger.org"`, starts a real bash command from A, and waits for its completion with `default-directory` B. The shell executes once and returns `stdout = "complete"`, exit code 0, status `ok`, and exactly one callback. Nevertheless, A's ledger contains only `tool-start` and B's ledger contains only `tool-finish`. No warning indicates that the original proof trail is incomplete.

This reproduced identically on Emacs 30.2 and 29.1. It also applies to the shipped relative default `.ogent/ledger.org`: the ledger resolver uses the project/default directory at each recording call. Switching projects while a process runs can silently leave an incomplete origin ledger and write the completion event into an unrelated project. This is substantive reliability and storage-routing behavior, even though callback/output retention itself succeeds in the probe.

Root cause: the asynchronous closure retains call metadata, effects, and start time but does not retain the resolved ledger destination. Its finish call resolves the relative path again using the ambient directory when the sentinel runs. Root accepted the finding and will repair a stable per-execution destination while preserving the new completion-failure delivery behavior. No repair was made by this reviewer.

Exact reproducer: `evidence/pass_3/review_round8/relative-ledger-probe.el`. Full commands and exits: `ogent-fixes-relative.json` and `ogent-fixes-29-relative.json`. Full observed result envelopes and both ledger contents: their corresponding `.stdout` files; `.stderr` records the real fixture locations. The probe substitutes neither ledger functions nor the process boundary and uses no provider login/inference.

## Review coverage and focused verification

Read the complete production change set from baseline to freeze: shared named execution and result construction, async callback ownership, native and gptel wrapper conventions, argument/call snapshots, approval aliases, model tool cache regeneration, structured read/glob/search/shell data, continuation guards, process startup/drain/cancel/cleanup, UI terminal recording, debug replay/history, and the actual build runner/reporting changes. Traced related ledger resolution/writer and streaming drawer functions. Read changed Make/CI, SDK documentation, build reporting documentation, and relevant tests. Read `10f86bb` in detail, including the new real-storage failure regressions.

The frozen focused ERT selector source-loads `/work/test/ogent-agent-execution-tests.el`, `/work/test/ogent-tool-process-tests.el`, and `/work/test/ui/ogent-ui-toolcalls-tests.el` after explicitly loading `/work/test/ogent-test-helper.el` under `-Q --batch` and all four requested load paths. Both container runs set `OGENT_PROCESS_TEST_RG=/tmp/ogent-test-rg`; the real executable reports ripgrep 15.2.0.

| Run | Selected | Expected | Unexpected | Skipped | Exit |
| --- | ---: | ---: | ---: | ---: | ---: |
| Focused ERT, `ogent-fixes`, Emacs 30.2 | 21 | 21 | 0 | 0 | 0 |
| Focused ERT, `ogent-fixes-29`, Emacs 29.1 | 21 | 21 | 0 | 0 | 0 |

These are 42 ERT executions of 21 distinct tests, with zero skips. The selector covers native plist/JSON and model JSON callbacks, legacy async text results, successful real ledger completion, real finish-write failure with retained process data and side effects, start-write failure before effects, preservation of tool errors, malformed async result construction, immediate completion, duplicate-terminal guards, streaming drawer finalization/cleanup, and process callback failure/startup/cancel/descendant-drain behavior plus the real ripgrep JSON protocol.

There were additionally exactly two real-process relative-ledger probe runs, one per Emacs version, each with command exit 0 and one terminal callback, each demonstrating F8-1. These are manual behavior probes, not ERT tests or a skipped-test claim. The full/native make suites, broad duplicate probes, and provider workflows were not run in this review; root owns the final full gate after repairs and clean reviews.

Evidence: `focused.el`, `run_focused.py`, `ogent-fixes.json/stdout/stderr`, and `ogent-fixes-29.json/stdout/stderr` under `evidence/pass_3/review_round8/`. Each JSON record preserves the exact executed argv and the parsed ERT counts. Passing focused tests do not make this round clean because the independent storage-routing probe exposes F8-1.

## Source guards

`evidence/pass_3/review_round8/source_start.json` and `source_end.json` both identify `10f86bb12a03f3122a60ba085be7289eb5277f5e`. Both staged and unstaged diffs were empty for `lisp`, `test`, `docs`, `specs`, `Makefile`, `makem.sh`, and CI. SHA-256 hashes of all 23 baseline-to-freeze changed files outside the audit workspace are identical at start and end. The source guards were captured before any root repair.

The round remains **NOT_CLEAN** and resets the clean streak. Completion of Phase 7 still requires repaired source, two subsequent clean independent rounds, and root's final verification gates.
