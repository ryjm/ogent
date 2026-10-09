# Phase 7 pass 3 fresh review — round 13

**Verdict: NOT_CLEAN.** One substantive contract defect, zero trivial findings, zero production fixes by this reviewer. The raw-root repair succeeds, but structured search can still copy a non-Unicode filter into continuation arguments. No clean streak starts. The root agent owns repairs and commits.

Reviewed `/workspace/ogent` on `master`, frozen HEAD `b7b966c6ac5acc15d15c8ea0c70d81653072cae9`, against genuine baseline `b3caf9300c7336ef812ed061158f851c5a47ccf7`. The latest repair was `ff4e96c..b7b966c`, touching three paths. Start/end guards cover 241 tracked non-audit/non-Beads files, including production, tests, documentation, specifications, CI and build files. HEAD and every hash stayed identical. Staged and unstaged production path lists were empty at both boundaries. Existing audit staging was preserved. The final guard was captured at `2026-10-08T23:36:08.082960+00:00`, before the root agent was released to repair. Evidence is in `audit/evidence/pass_3/review_round13/`.

## Applied calibrated prompts

1. "Carefully read over all of the new code you just wrote and other existing code you just modified with 'fresh eyes' looking super carefully for any obvious bugs, errors, problems, issues, confusion, etc. Carefully fix anything you uncover."

   Read the latest three-file repair and traced validation through read/glob/search results, SDK sync/async execution, typed error mapping, and JSON normalization. Independently verified empty, excluded-only, and nonexistent raw roots in explicit and default forms, for both tools, transports and delivery modes. All are refused as `unsupported_output`; valid Unicode roots, unusual filenames and symlink identity remain usable. The repair validates roots before enumeration/classification and glob patterns before matching.

2. "Sort of randomly explore the code files in this project, choosing code files to deeply investigate and trace their functionality and execution flows through the related code files which they import or which they are imported by. Once you understand the purpose of the code in the larger context of the workflows, do a super careful, methodical, and critical check with 'fresh eyes' to find any obvious bugs, problems, errors, silly mistakes. Comply with ALL rules in AGENTS.md and ensure that any code you write or revise conforms to the best practice guides referenced in AGENTS.md."

   Traced argument normalization/copying, approval, registry snapshots and captured gptel format, UI execution and ledger ownership, terminal result construction and `ogent-agent-next`. Examined every built-in file continuation string: read paths and glob roots/patterns are checked, but search pattern/filter strings can enter `next.args` without a Unicode check. This yields finding F13-01 below. Read AGENTS.md, architecture, style and feature-playbook specifications, gptel integration/overview, the invoked SKILL.md, Phase 7 methodology and fresh-eyes instructions. The explicit review-only assignment overrides the skill's source-edit/commit instructions.

3. "Turn your attention to reviewing the code written by your fellow agents and checking for any issues, bugs, errors, problems, inefficiencies, security problems, reliability issues. Diagnose underlying root causes using first-principle analysis. Don't restrict yourself to the latest commits — cast a wider net and go super deep."

   Expanded to baseline-to-freeze execution/caching changes, preapproval validation, batch preflight, read line/column continuations, glob component matching and raw-path filtering, ripgrep/GNU grep candidate selection and wire decoding, binary and symlink rules, timeout/cancellation/draining and callback-once behavior, captured ledger configuration and storage failures, replay/history, Makefile/CI integration and makem report events, task status and diagnostics. Focused existing suites execute these contracts in both runtimes. No further finding emerged from this bounded wider review. Native extension values retain their documented native contracts; shell data does not reflect its command or working directory, and its output replacement is explicit.

## F13-01: a raw search filter poisons otherwise valid continuation results

**Severity: medium.** `ogent-tool-process--search-options` checks the filter's type and validates the resolved target path, but does not validate the Unicode representability of `pattern` or `glob-filter`. `ogent-tool-execution--success` copies the canonical arguments into `next.args` when `has_more` is true. A raw byte inside a bracket glob can match an ordinary Unicode filename while making that continuation non-serializable.

Minimal reproduction: create `a.el` containing `needle\nneedle\n`, then call:

```elisp
(ogent-agent-call
 "search"
 (list :pattern "needle" :path root :limit 1
       :glob_filter
       (concat "[a" (decode-coding-string (unibyte-string 255) 'utf-8-unix) "]*.el")))
```

The `a` branch matches the valid filename. The first page has two total matches, one retained match and a continuation. On **both Emacs 30.2 and 29.1**, source and explicitly loaded bytecode exhibit this behavior:

| Format | Sync and async status | Continuation | JSON representability |
| --- | --- | --- | --- |
| plist | `ok`, no error | One entry carrying the raw filter | Cannot serialize the envelope |
| json | `error`, `unsupported_output` | Empty; matched data discarded by fallback | Valid error JSON |

Async delivery occurs once. This contradicts the documented statement that JSON serializes the same result (`docs/agent-ergonomics.org`, “Handle outcomes without parsing prose”). It also makes success depend on whether a page needs a continuation. A native consumer cannot forward the successful result through JSON, while a model-facing JSON call loses valid matches to a serialization error.

**Root cause:** validating only output paths leaves retained query arguments outside the structured-output boundary. Glob now validates its reflected pattern; structured search does not apply that check to its query/filter.

**Suggested repair:** after the existing type checks, validate both structured search pattern and non-nil glob filter as Unicode before candidate enumeration or process startup. Preserve typed `unsupported_output`, legacy text behavior, and valid Unicode filters. Cover native/JSON sync/async calls with this bracket-filter reproduction and raw pattern refusal, including cases with and without continuation. The root agent accepted the finding and owns the repair.

**Evidence:** `filter-contract.el` has independent sync and async assertions. `filter_contract30`, `filter_contract29`, `filter_bytecode30`, and `filter_bytecode29` each select two tests, fail both with exit 1, and preserve complete backtraces. `filter_observe30_retry.stdout` and `filter_observe29_retry.stdout` record all four format/delivery outcomes per runtime without trying to encode the offending filter itself. `filter-observe.el` is the minimal runnable observation.

## Actual bounded verification

Each invocation has a JSON record containing exact argv, host cwd, UTC start/end, elapsed seconds and exit, plus complete separate stdout and stderr files. Docker cwd is explicitly `/work`. Load paths are `/work/lisp`, `/work/lisp/ui`, `/work/test`, `/work/test/ui`; `boot.el` explicitly loads `/work/test/ogent-test-helper.el`. Real dependencies load before test helper doubles, and source-first loading removes `.elc` from suffixes. Compiled runs load owned `.elc` files explicitly and assert five bytecode function identities.

Actual containers: `ogent-fixes` running Emacs 30.2 and `ogent-fixes-29` running Emacs 29.1. Actual dependency roots: `/tmp/ogent-fixdeps/30.2/elpa` and `/tmp/ogent-ergonomics-elpa`. Installed gptel is 0.9.9.6; `/tmp/gptel-minimum` loads 0.9.9.5. Both use Org 9.8.10 and transient 0.13.8. Process suites use `OGENT_PROCESS_TEST_RG=/tmp/ogent-test-rg`; engine tests execute with no skips.

| Records | Work | Emacs 30.2 | Emacs 29.1 |
| --- | --- | --- | --- |
| `source30_retry`, `source29` | 57 execution, 51 process, 35 ergonomics, 3 independent boundary tests | 146/146; exit 0 | 146/146; exit 0 |
| `compiled30`, `compiled29` | 11 changed Lisp modules compiled with warnings as errors into owned evidence paths; explicit bytecode load; 57 execution + 3 independent tests | 60/60; exit 0 | 60/60; exit 0 |
| `ui30`, `ui29` | Four UI terminal/ledger and four replay/history tests | 8/8; exit 0 | 8/8; exit 0 |
| `actual_min30`, `actual_min29` | Three independent tests using actual minimum gptel 0.9.9.5 | 3/3; exit 0 | 3/3; exit 0 |
| `filter_contract30`, `filter_contract29` | Independent raw-filter native/JSON contract assertions, source | 0/2; two unexpected; exit 1 | 0/2; two unexpected; exit 1 |
| `filter_bytecode30`, `filter_bytecode29` | Same assertions after explicit frozen bytecode load | 0/2; two unexpected; exit 1 | 0/2; two unexpected; exit 1 |
| `filter_observe30_retry`, `filter_observe29_retry` | Four native/JSON sync/async observations | Four observations; exit 0 | Four observations; exit 0 |

**ERT totals:** 442 selected invocations, 434 expected results, eight unexpected results, zero skipped. All eight unexpected results are the two raw-filter contract assertions repeated across two runtimes and source/bytecode. Source and bytecode runs include the actual current gptel probe; minimum runs independently exercise the same actual gptel construction, tool processing, result parsing and JSON encoder. The unresolved second call keeps the real FSM from advancing to transport. No provider or loopback HTTP was sent by these probes.

**Preserved evidence harness mistakes:** initial `source30` exited 255 before ERT selection because its argv named nonexistent `test/ogent-agent-tests.el`; `source30_retry` uses the actual ergonomics suite and passes 146 selected tests. Initial observation records used the parser's default null/false sentinels when checking whether parsed error JSON could be reserialized, incorrectly reporting that secondary representability flag as false. The original observation script is retained as `filter-observe-initial.el`, both initial records remain, and the separate `_retry` records use the contract sentinels. Native nonrepresentability and differing statuses were reproduced correctly throughout. Neither harness mistake counts as a production finding or a passing test.

This review did not run a full native/make matrix, full suite, lint gate or all audit regression scripts. Build integration received static review and the existing focused ergonomics fixture checks; the root's final matrix remains required after two consecutive clean reviews. No source/test/doc/build edits, staging, commits, branches or provider calls were performed by this reviewer. Phase 7 remains open.
