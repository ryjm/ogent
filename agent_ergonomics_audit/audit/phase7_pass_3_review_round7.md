# Pass 3 fresh-eyes review, round 7

Verdict: **NOT_CLEAN — one substantive P2 finding.** Review only; no source, test, documentation, staging, or commit changes were made by this reviewer.

Reviewed `b3caf9300c7336ef812ed061158f851c5a47ccf7..967eb054e13104d05e818656a2b78f037cc0effd`. HEAD was the latter SHA at both the beginning and end. The staged plus unstaged production diff against HEAD was empty at both checks. Evidence is in `audit/evidence/pass_3/review_round7/`.

## Calibrated prompts applied verbatim

1. "Carefully read over all of the new code you just wrote and other existing code you just modified with 'fresh eyes' looking super carefully for any obvious bugs, errors, problems, issues, confusion, etc. Carefully fix anything you uncover."
2. "Sort of randomly explore the code files in this project, choosing code files to deeply investigate and trace their functionality and execution flows through the related code files which they import or which they are imported by. Once you understand the purpose of the code in the larger context of the workflows, do a super careful, methodical, and critical check with 'fresh eyes' to find any obvious bugs, problems, errors, silly mistakes. Comply with ALL rules in AGENTS.md and ensure that any code you write or revise conforms to the best practice guides referenced in AGENTS.md."
3. "Turn your attention to reviewing the code written by your fellow agents and checking for any issues, bugs, errors, problems, inefficiencies, security problems, reliability issues. Diagnose underlying root causes using first-principle analysis. Don't restrict yourself to the latest commits — cast a wider net and go super deep."

The explicit review-only assignment overrides the prompts' edit instructions: the confirmed finding was routed to the main agent for repair.

Read repository `AGENTS.md`, `specs/style-guide.org`, `specs/architecture.org`, `specs/feature-playbooks.org`, the gptel integration specifications, and the installed agent-ergonomics skill with its Phase 7 methodology. Traced discovery, named and model-facing execution, schema normalization, approval and registry snapshots, structured file and process results, pagination, batch execution, debug replay/import/export, ledger recording, cancellation, process-group cleanup, and makem reporting/exit propagation. Inspected the complete new process lifecycle and selected-file search scripts, plus the related focused tests and actual-runner shell fixtures.

## P2: terminal ledger failure drops an asynchronous SDK callback

Location: `lisp/ogent-tool-execution.el:164`, within `ogent-tool-execution--start`'s `complete` closure; the ledger call at lines 168–171 precedes callback delivery at line 172. The older model-facing `ogent-tool-execution--async` closure has the same ordering at lines 335–338.

Trigger: start recording succeeds, a real asynchronous shell command finishes successfully, and the terminal ledger write encounters a filesystem error. The terminal closure sets `finished` to true before recording the ledger. A ledger error escapes before the caller is invoked. For actual process tools, `ogent-tool-process--callback` catches this error and reports it only in Messages; the process has already completed and been removed from the active table. The SDK caller receives no terminal envelope and can wait indefinitely, contradicting the documented exactly-once callback contract. Retrying completion cannot help because `finished` is already true.

Independent reproduction on **both GNU Emacs 30.2 and 29.1**, using the real shell/process runner and real ledger writer:

1. Enable the ledger with a writable fixture file and start `shell` with `sleep 0.05; printf success`, timeout 1.
2. Before completion, set the ledger target to the fixture directory itself, causing a real terminal append error without deleting files or touching user stores.
3. Wait with a one-second deadline, then inspect the caller callback count and process state.

Both versions returned the same observed result:

```text
ogent: process callback failed: Opening output file: Is a directory, .../ledger-probe/
process=exit exit=0 callbacks=0 result=nil callback_error=(file-error ...) active=nil
```

Evidence: `ledger_failure_probe.el`, `ledger_failure_emacs30.log`, `ledger_failure_emacs29.log`, and the retained ledger fixture. Suggested repair: guard terminal result construction and ledger recording so their errors become one terminal failure result while retaining any completed process data. Keep the once-only guard around actual callback delivery, and prevent duplicate execution. Cover a real or boundary-injected terminal ledger failure for both the SDK and model-facing asynchronous owners.

## Verification

- Source-forced focused ERT on Emacs **30.2**: **193/193 passed**, zero unexpected, process exit 0; `focused_emacs30.log`.
- Source-forced focused ERT on Emacs **29.1**: **193/193 passed**, zero unexpected, process exit 0; `focused_emacs29.log`.
- Each run used `OGENT_PROCESS_TEST_RG=/tmp/ogent-test-rg`, verified as real ripgrep **15.2.0**, and explicitly loaded `ogent-test-helper.el` before the agent execution, process, and debug suites so stale `.elc` files could not be selected.
- Independent search fixture on both Emacs versions and both engines: **268 matches**, pages of **200 + 68**, identical cross-engine match objects, stable page snapshots, correct before/after context, preserved regular-file symlink identity, and exclusion of a late-NUL binary, `.git` data, and a directory-symlink loop. Includes 132 ordered files plus a newline/colon/Unicode filename, crossing the 128-file process batch boundary. Both probe processes exited 0; `search_probe_emacs30.log` and `search_probe_emacs29.log`.
- No other substantive findings in this bounded review. No full repository compile, test, lint, provider request/login, network probe, push, or PR operation was performed.

The finding was sent to the main agent. This round does **not** contribute a clean result to the two-consecutive-clean gate.
