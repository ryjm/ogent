# Captured tool ledger context

Source-only commit: `a2fa8ce0533b4a508fb641f343fa55b15fd6fc60` (`fix: retain each tool call ledger destination`). Baseline: `10f86bb12a03f3122a60ba085be7289eb5277f5e`. The four owned source/test paths were clean after the commit and frozen immediately. No later production edits or commits were made by this worker.

Round 8's `../review_round8/relative-ledger-probe.el` demonstrated a real successful async shell whose start was written under project A and finish under ambient project B. `ogent-ledger--file` resolves a relative path from the current project/default directory for each event, so deferred callbacks could silently split the trail. Native SDK/JSON async, legacy async, streaming UI and synchronous tools changing `default-directory` shared the issue.

Each execution now captures the enabled state and a copied absolute ledger destination once before tool start. Start and finish helpers bind only those captured ledger settings while recording. Tool execution and caller callbacks retain their ambient context. Ledger configuration changes apply to future calls: disabling after an enabled start still records that call's finish at its original destination; enabling after a disabled start creates no orphan finish. A subsequent call uses the new configuration and its new origin. Resolving the path only when enabled preserves disabled-ledger behavior.

The prior completion recovery remains intact: finish recording is attempted once, storage errors retain completed tool data and typed/text-visible diagnostics, caller callbacks deliver once, streaming drawers finalize and release markers, start storage failure prevents effects, and successful ledger behavior remains unchanged. No change to `lisp/ogent-ledger.el` was needed.

Existing completion IO tests now fault the actual captured destination: rename the successfully started ledger to a retained `.started` file and create a directory at its original file path. They no longer use a mutable configuration change as a surrogate for storage failure. All filesystem fixtures remain retained.

The source-only commit contains exactly:

- `lisp/ogent-tool-execution.el`
- `lisp/ui/ogent-ui-toolcalls.el`
- `test/ogent-agent-execution-tests.el`
- `test/ui/ogent-ui-toolcalls-tests.el`

Audit work and Beads were not committed by this worker. The earlier `ledger_recovery/` provenance was preserved unchanged.

## Validation

| Check | Emacs 30.2 (`ogent-fixes`) | Emacs 29.1 (`ogent-fixes-29`) |
| --- | --- | --- |
| Source-loaded SDK, process, debug, ledger and focused UI suites | 213/213, zero skips | 213/213, zero skips |
| Existing UI execute-tool / ledger tests | 4/4 | 4/4 |
| Scoped warning-as-error byte compilation | Pass | Pass |
| Scoped checkdoc and canonical indentation, test macros loaded | Pass | Pass |
| Three new context regressions against retained 10f production sources | All 3 fail, expected exit 1 | All 3 fail, expected exit 1 |
| Same three regressions against the fixed source | 3/3 pass | 3/3 pass |
| Owned source/test `git diff --check` | Pass | Pass |

The three new tests contain 32 execution cases: 16 async SDK/JSON/gptel/legacy cases, 12 synchronous SDK/JSON/text cases and 4 streaming UI cases. They cover initially enabled/disabled recording and both unchanged settings and mid-call configuration changes while moving from A to B. They assert paired events only at the original enabled destination, no orphan events for disabled-start calls, exactly one effect marker, retained output, preserved ambient callback/tool context, cleanup, and future-call configuration behavior. Existing real IO fault and start-failure regressions are included in the 213-test focused run.

Baseline production copies were read from the exact 10f Git objects into this evidence directory and loaded explicitly before the current tests. They did not replace working source. Baseline logs show actual missing paired ledger events, not missing helper/function failures. `results.json` records current and baseline source hashes.

No provider login or provider API calls were made by this worker. The gptel cases invoke local wrapper functions directly; the explicit source-loaded test helper supplies a non-network `gptel-request` stub and request suites use local mocks. Approval, auto-grant and edit review owners were unchanged. No full `make test`, `make lint` or broad compile was run by this worker.

The Docker containers bind `/workspace/ogent` at `/work`. Each command loads `test/ogent-test-helper.el` explicitly before suites, excluding stale bytecode. Focused tests use the real ripgrep executable through `OGENT_PROCESS_TEST_RG=/tmp/ogent-test-rg`.

Focused command, once per container:

```sh
docker exec -e OGENT_PROCESS_TEST_RG=/tmp/ogent-test-rg -w /work CONTAINER \
  emacs -Q --batch -L test -l test/ogent-test-helper.el \
  -l test/ogent-agent-execution-tests.el -l test/ogent-tool-process-tests.el \
  -l test/ogent-debug-tests.el -l test/ogent-ledger-tests.el \
  -l test/ui/ogent-ui-toolcalls-tests.el \
  --eval '(ert-run-tests-batch-and-exit t)'
```

Existing UI command, once per container:

```sh
docker exec -w /work CONTAINER emacs -Q --batch -L test \
  -l test/ogent-test-helper.el -l test/ui/ogent-ui-tests.el \
  --eval '(ert-run-tests-batch-and-exit "ogent-ui-execute-tool")'
```

Scoped static validation command, once per container:

```sh
docker exec -w /work CONTAINER emacs -Q --batch -L test \
  -l test/ogent-test-helper.el \
  -l agent_ergonomics_audit/audit/evidence/pass_3/ledger_context/scoped-validation.el
```

The static script writes bytecode to a retained helper-provisioned store, preserving production `.elc` files. The standalone context regression command uses the two current test files and selector `ledger-context`. The baseline command additionally loads `baseline-tool-execution.el` and `baseline-ui-toolcalls.el` from this evidence directory before those tests. Ten raw logs accompany this report.
