# Tool completion ledger recovery

Source-only commit: `10f86bb12a03f3122a60ba085be7289eb5277f5e` (`fix: preserve tool completion when ledger writes fail`). Baseline: `967eb054e13104d05e818656a2b78f037cc0effd`. Source was frozen immediately after the commit. No production edits or commits followed.

The round 7 probe in `../review_round7/ledger_failure_probe.el` confirmed that a real async shell exited successfully after its ledger start was written, but a subsequent directory-valued `ogent-ledger-file` caused finish recording to throw before terminal callback delivery. Both Emacs versions reported zero callbacks and no retained result. Native/JSON async, legacy async and streaming UI callbacks shared this coupling. The sync owner also retried finish recording after the first storage exception and lost completed output.

The fix attempts terminal ledger recording once and reports its failure through the result. SDK and JSON results retain tool data with `ledger_write_failed`; an existing tool error is preserved as `error.tool_error`. Recovery says the tool already completed, directs the caller to inspect retained data and configure a writable ledger file for future calls, and explicitly forbids rerunning tool effects merely to repair storage. Legacy text results and streaming drawers retain output and display the same warning. Streaming terminal events are guarded against duplicate delivery and release drawer markers. Successful ledger events retain their behavior; a failed finish never creates a false completion proof. Start recording still must succeed before effects run.

Terminal result construction errors also deliver one typed result with retained data. Immediate native async completions return nil, matching the public process-or-nil return contract; real process handles are preserved.

Only these paths were committed:

- `lisp/ogent-tool-execution.el`
- `lisp/ui/ogent-ui-toolcalls.el`
- `test/ogent-agent-execution-tests.el`
- `test/ui/ogent-ui-toolcalls-tests.el`

The existing UI suite remains in `test/ui/ogent-ui-tests.el`; the new focused file mirrors `lisp/ui/ogent-ui-toolcalls.el` as specified by the style guide. All four committed paths were clean after the commit. Staged audit work and Beads were not committed by this worker.

## Validation

Both Docker runtimes bind `/workspace/ogent` at `/work`. The helper was loaded by explicit `.el` path before tests, disabling stale `.elc` loading. The focused runs use the real ripgrep executable through `OGENT_PROCESS_TEST_RG=/tmp/ogent-test-rg`.

| Check | Emacs 30.2 (`ogent-fixes`) | Emacs 29.1 (`ogent-fixes-29`) |
| --- | --- | --- |
| SDK, process, debug, ledger and new UI completion suites | 210/210, zero skips | 210/210, zero skips |
| Existing UI execute-tool / ledger tests | 4/4 | 4/4 |
| Scoped warning-as-error byte compilation | Pass | Pass |
| Scoped checkdoc | Pass | Pass |
| Canonical indentation, with test macros loaded | Pass | Pass |
| `git diff --check` for owned source/test files | Pass | Pass |

Actual IO tests write a valid real ledger start and then set the finish target to an owned directory. Real shell processes emit stdout/stderr and append an effect marker. Assertions verify exactly one callback, retained stdout/stderr/exit code, typed or text-visible storage failure, one effect marker, no process callback exception, active-process cleanup, drawer finalization and marker cleanup, and absence of a false `tool-finish` in the successfully started ledger. Additional cases cover successful real ledger completion, duplicate terminal events, synchronous result retention, simultaneous tool and ledger errors, result construction errors, immediate native completion, and start-write failure preventing tool effects.

No provider login or provider API calls were made by this worker. The gptel JSON cases invoke registered local wrapper functions directly. The source-loaded test helper provides an erroring, non-network `gptel-request` stub; suites that exercise request behavior supply local mocks. Approval policy, auto-grant behavior and edit review owners were not changed.

Focused command, once per container:

```sh
docker exec -e OGENT_PROCESS_TEST_RG=/tmp/ogent-test-rg -w /work CONTAINER \
  emacs -Q --batch -L test -l test/ogent-test-helper.el \
  -l test/ogent-agent-execution-tests.el \
  -l test/ogent-tool-process-tests.el \
  -l test/ogent-debug-tests.el \
  -l test/ogent-ledger-tests.el \
  -l test/ui/ogent-ui-toolcalls-tests.el \
  --eval '(ert-run-tests-batch-and-exit t)'
```

Existing UI command, once per container:

```sh
docker exec -w /work CONTAINER emacs -Q --batch -L test \
  -l test/ogent-test-helper.el -l test/ui/ogent-ui-tests.el \
  --eval '(ert-run-tests-batch-and-exit "ogent-ui-execute-tool")'
```

Static validation command, once per container:

```sh
docker exec -w /work CONTAINER emacs -Q --batch -L test \
  -l test/ogent-test-helper.el \
  -l agent_ergonomics_audit/audit/evidence/pass_3/ledger_recovery/scoped-validation.el
```

Compilation writes retained bytecode into a helper-provisioned fixture directory, avoiding production `.elc` mutation. Raw logs and source hashes accompany this report. No full `make test`, `make lint` or broad compile was run by this worker; final broad gates belong to the root after independent review.
