# Phase 7 pass 3 fresh review — round 12

**Verdict: NOT_CLEAN.** One substantive contract defect, zero trivial findings, zero production fixes by this reviewer. The previous round was NOT_CLEAN; this round therefore does not start a clean streak. The root agent owns all production fixes and commits.

Reviewed `/workspace/ogent` on `master`, frozen HEAD `ff4e96c21d5fb3ffe79843fbce8392390d1c8bf4`, against baseline `b3caf9300c7336ef812ed061158f851c5a47ccf7`. The latest repair reviewed was `021cca4..ff4e96c`. Start/end integrity snapshots cover 241 tracked non-audit/non-Beads files, including source, tests, docs, specs and build files. HEAD and all hashes stayed identical; staged and unstaged production path lists were empty at both boundaries. Existing audit staging was left intact. Evidence lives in `audit/evidence/pass_3/review_round12/`.

## Applied prompts

1. "Carefully read over all of the new code you just wrote and other existing code you just modified with 'fresh eyes' looking super carefully for any obvious bugs, errors, problems, issues, confusion, etc. Carefully fix anything you uncover."

   Read the seven-file repair, traced the private glob validator and shared JSON normalization through structured results, SDK execution, doctor rendering and real gptel serialization. No additional defect in these repaired matched-file and Unicode serialization cases. Matching raw files now fail before `file-regular-p` can omit them, excluded raw names leave valid Unicode results intact, and legacy text calls do not invoke the new validator. Native and nested JSON Unicode probes pass in both source and explicitly loaded bytecode.

2. "Sort of randomly explore the code files in this project, choosing code files to deeply investigate and trace their functionality and execution flows through the related code files which they import or which they are imported by. Once you understand the purpose of the code in the larger context of the workflows, do a super careful, methodical, and critical check with 'fresh eyes' to find any obvious bugs, problems, errors, silly mistakes. Comply with ALL rules in AGENTS.md and ensure that any code you write or revise conforms to the best practice guides referenced in AGENTS.md."

   Traced `ogent-agent-call` and async calls through contract validation, approval, captured registry metadata, UI execution, structured glob/search, terminal rendering and ledger recording. Found the raw-root contract gap below. Read AGENTS.md, architecture/style/feature-playbook specs, gptel integration/overview, the invoked SKILL.md, Phase 7 methodology and fresh-eyes subagent instructions. Production edit/commit instructions in the skill were overridden by the explicit review-only ownership assignment.

3. "Turn your attention to reviewing the code written by your fellow agents and checking for any issues, bugs, errors, problems, inefficiencies, security problems, reliability issues. Diagnose underlying root causes using first-principle analysis. Don't restrict yourself to the latest commits — cast a wider net and go super deep."

   Expanded to the baseline-to-freeze changes in execution, approval, model tool caching, argument copying, batch preflight, read continuations, ripgrep/GNU grep candidate selection and wire parsing, process termination/draining, callback-once delivery, ledger context/failure handling, replay history, Makefile/CI reporting and makem event/diagnostic rendering. The raw-root gap also affects search, which was outside the latest repair. No additional finding after this bounded wider review.

## Substantive finding F12-01: empty raw directory targets violate the plist result contract

**Severity: medium.** `ogent-tool-results-glob` validates only matching file paths. `ogent-tool-process-grep-async` validates candidate and match paths. Both return their resolved root/target as `:data :path`, even when no candidates exist, without checking that this reflected path is Unicode.

Create an empty directory whose last name component is `(decode-coding-string (unibyte-string 255) 'utf-8-unix)`, then call `files` with `:pattern "*.el"` or `search` with `:pattern "needle"`, using that directory as `:path`. On both Emacs 30.2 and 29.1:

| Transport | Sync result | Async result | Returned data path |
| --- | --- | --- | --- |
| plist | `status: ok`, no error | `status: ok`, one callback | Cannot be represented by `json-serialize` |
| json | `status: error`, `unsupported_output` | `status: error`, one callback | Serialization fallback removes invalid data |

This conflicts with `docs/agent-ergonomics.org:30-31`: "Structured file paths must be Unicode; unsupported raw filename bytes return unsupported_output". The result status changes solely with requested serialization. A native client can receive a success envelope that fails when forwarded to JSON. The matched-filename repair does not cover this because an empty candidate list never invokes its validator.

**Evidence:** `root-path-probe.el`, `root_path30.stderr` and `root_path29.stderr` each show two unexpected ERT failures. `root_observe30_retry.stdout` and `root_observe29_retry.stdout` record all eight sync/async plist/JSON combinations per Emacs version and the returned path's representability, without attempting to JSON-encode the raw path itself.

**Suggested repair:** validate the explicitly supplied/resolved result root in structured glob and search before candidate enumeration, retaining each module's typed unsupported-output condition. Keep candidate validation after glob-filter matching so excluded filenames remain uninspected. Cover empty and excluded-only raw roots through sync plist/JSON and async callback-once calls. The root agent was notified; this reviewer did not edit production code.

## Actual bounded verification

Every command has a JSON record containing exact argv, host cwd `/workspace/ogent`, Docker cwd `/work`, UTC start/end, elapsed time and exit, plus complete separate stdout/stderr files. Commands use explicit `/work/test/ogent-test-helper.el` via `boot.el` and load paths `/work/lisp`, `/work/lisp/ui`, `/work/test`, `/work/test/ui`. Real dependencies load before helper doubles. The helper's exclusion of `.elc` is preserved.

Actual containers were `ogent-fixes` (verified Emacs 30.2) and `ogent-fixes-29` (29.1). ELPA roots were `/tmp/ogent-fixdeps/30.2/elpa` and `/tmp/ogent-ergonomics-elpa`. Actual installed gptel was 0.9.9.6; `/tmp/gptel-minimum` was 0.9.9.5. Both used Org 9.8.10 and transient 0.13.8. Ripgrep regression tests were given `OGENT_PROCESS_TEST_RG=/tmp/ogent-test-rg` and the real engine-specific tests executed without skips.

| Evidence records | Work | Emacs 30.2 | Emacs 29.1 |
| --- | --- | --- | --- |
| `source30`, `source29` | Source suites: 55 execution, 51 process, 35 ergonomics, 4 UI ledger and 4 replay/history tests | 149/149; exit 0 | 149/149; exit 0 |
| `compiled30`, `compiled29` | Warning-strict compilation of all 11 baseline-changed Lisp modules into owned `compiled/<version>/`; explicit `.elc` load; five bytecode identity assertions; 55 execution + 3 independent tests | 58/58; exit 0 | 58/58; exit 0 |
| `actual_current30`, `actual_current29` | Three independent tests + both structured offline tests, actual gptel 0.9.9.6 | 5/5; exit 0 | 5/5; exit 0 |
| `actual_min30`, `actual_min29` | Same five selected tests, actual minimum gptel 0.9.9.5 | 5/5; exit 0 | 5/5; exit 0 |
| `root_path30`, `root_path29` | Independent empty raw-root contract assertions | 0/2; two unexpected; exit 1 | 0/2; two unexpected; exit 1 |
| `root_observe30_retry`, `root_observe29_retry` | Eight native/JSON sync/async observations per version | 8 observations; exit 0 | 8 observations; exit 0 |

**ERT totals:** 438 selected invocations, 434 expected results, four unexpected results, zero skipped. The unexpected results are the two root-path assertions repeated on two Emacs versions. All compile calls returned success with warnings treated as errors. The successful source runs include meaningful build integration fixture tests that preserve Make failure status and verify clean/help/offline prerequisite contracts; makem machine-report/CI integration also received static review. No broad native/make matrix or full suite was run by this reviewer.

**Initial evidence harness failures retained:** `root_observe30` and `root_observe29` exited 255 before observations because the reviewer-authored observation script had a missing closing parenthesis. The original script is preserved as `root-path-observe-initial.el`; the error stdout/stderr and argv records remain. Only that owned script was corrected, and separate `_retry` records preserve the successful reruns. Those failures are evidence harness errors, not additional production findings or passing tests.

The actual gptel probes create an FSM with a second unresolved call, preventing transport advancement; no provider or loopback HTTP was sent. The selected production offline test uses an owned port fixture solely to construct a local backend. Serialization and tool processing use actual gptel functions. Sources/tests/docs/build files remained untouched. No staging, commits, branches, provider calls or root gate claims were made.

**Phase 7 remains open.** This is a bounded independent review with a reproducible substantive defect, not a full native, lint, test or regression gate verdict.
