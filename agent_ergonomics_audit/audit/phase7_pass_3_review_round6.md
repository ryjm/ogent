# Phase 7, pass 3: independent fresh-eyes round 6

**Result: one concrete P2 finding.** This round is not clean. Reviewed exact
production freeze `9ac13b23032f40eccb9a627a824be45656292056` against baseline
`b3caf9300c7336ef812ed061158f851c5a47ccf7`. Start and end SHA agree, and the
production status and diff records are empty. This reviewer changed only this
report and `evidence/pass_3/review_round6/`; no source/test/doc edits, staging,
commits, provider requests, or authentication.

## Finding: equivalent directory filters change symbolic-link search scope

**P2 — `lisp/ogent-tool-process.el:550` and `:567`.** A directory containing
`source.txt` with `needle\n` and a symbolic link `link.txt -> source.txt`
produces inconsistent results through the same real ripgrep engine:

```elisp
(ogent-tool-process-grep "needle" DIRECTORY "link.txt")
;; total_matches = 0; matches = []
(ogent-tool-process-grep "needle" DIRECTORY "l?nk.txt")
;; total_matches = 1; matches includes link.txt
(ogent-tool-process-grep "needle" DIRECTORY "l[ia]nk.txt")
;; total_matches = 1; matches includes link.txt
```

These filters select the same file in the fixture. GNU fallback includes the
linked file for all three filters. With no filter or `*.txt`, GNU returns both
`link.txt` and `source.txt`, while ordinary ripgrep returns only `source.txt`.

The Unicode-aware candidate branch for `?`/`[` uses
`ogent-tool-process--grep-files`, whose `file-regular-p` accepts file symbolic
links, followed by `ogent-tool-process--rg-selected-script` with `--follow`
at line 341. The ordinary ripgrep directory argument vector at lines 567–589
omits `--follow`. Consequently, equivalent glob spellings change the actual
search domain and reported counts. This is a silent omitted match, not a
choice of regex dialect or an approval limitation.

Use one declared directory candidate/link policy across these branches and
GNU fallback. Merely adding unrestricted `--follow` to recursive ripgrep can
also traverse linked directories, which is broader than the current GNU
enumeration; preserve the intended directory-link policy when repairing it.
Add a regression covering linked regular files through ordinary and
Unicode-aware filters and both engines.

Reproduced independently on **Emacs 30.2 and 29.1**, using actual ripgrep
15.2.0 and GNU grep/xargs. Exact probes, commands, statuses, and full outputs:
`evidence/pass_3/review_round6/boundary-probe.el`,
`boundary-final-30.{json,stdout,stderr}`, and
`boundary-final-29.{json,stdout,stderr}`. The integration owner was notified
immediately; this reviewer did not change production code.

## Scope and method

Read `AGENTS.md`, the installed agent ergonomics skill's `SKILL.md`, Phase 7
of `references/methodology/PHASES.md`, and the project style, architecture,
gptel integration, and feature playbooks. Reviewed changed SDK discovery,
argument validation, registry snapshots, text/JSON wrappers, synchronous and
asynchronous execution, structured reads/globs/search/processes, approval,
debug history/replay, UI execution, Make integration, and build reporting.
Traced surrounding project-root resolution, mutable argument copying,
effects/approval ownership, ledger delivery, and cancellation bookkeeping.

Applied the calibrated prompts verbatim. The explicit review-only assignment
delegates any source fixes to the integration owner:

1. "Carefully read over all of the new code you just wrote and other existing code you just modified with 'fresh eyes' looking super carefully for any obvious bugs, errors, problems, issues, confusion, etc. Carefully fix anything you uncover."
2. "Sort of randomly explore the code files in this project, choosing code files to deeply investigate and trace their functionality and execution flows through the related code files which they import or which they are imported by. Once you understand the purpose of the code in the larger context of the workflows, do a super careful, methodical, and critical check with 'fresh eyes' to find any obvious bugs, problems, errors, silly mistakes. Comply with ALL rules in AGENTS.md and ensure that any code you write or revise conforms to the best practice guides referenced in AGENTS.md."
3. "Turn your attention to reviewing the code written by your fellow agents and checking for any issues, bugs, errors, problems, inefficiencies, security problems, reliability issues. Diagnose underlying root causes using first-principle analysis. Don't restrict yourself to the latest commits — cast a wider net and go super deep."

## Verification and provenance

- The focused source-forced SDK/process/debug suites passed **188/188** on
  each Emacs runtime, with zero unexpected results or skips. The test helper
  was loaded by explicit `.el` path first, excluding project bytecode and
  guarding real stores. `OGENT_PROCESS_TEST_RG=/tmp/ogent-test-rg` selects the
  actual executable. Evidence: `focused-ert-30-source.*` and
  `focused-ert-29-source.*`.
- Four independent ERT probes passed **4/4** on both runtimes: JSON glob
  continuation retains the original project root after the live root changes;
  search pagination with a zero-character output budget preserves all five
  matching identifiers in three pages through both engines; read/search
  continuation rejects a changed later page; and shell timeout retains both
  stdout/stderr, delivers one result, and removes its active process.
- The symbolic-link comparison is printed outside ERT assertions so the
  successful four-test run is not misrepresented as proof of search parity.
  Its full stdout is the finding's direct evidence.
- The first focused-suite launch supplied a PATH that omitted the container's
  `/nix/store/emacs/bin` and exited 127 before Emacs ran. Corrected runs
  preserve the original PATH. These failed attempts remain as
  `focused-ert-29.*` and `focused-ert-30.*`.
- Initial independent probe runs returned one failed assertion because the
  fixture used a symbol allow-list entry `'(bash)` instead of the documented
  string entry `'("bash")`, causing `invalid_arguments` before shell launch.
  Only that fixture assumption was corrected. Initial transcripts remain as
  `boundary-29.*` and `boundary-30.*`; final transcripts are separate. The
  initial link comparison was already the same production behavior.
- `record.py` preserves each actual argv, working directory, exit code,
  duration, stdout, and stderr. `probe-sha256.txt` identifies the final probe
  and recorder. Start/end provenance files certify the reviewed production
  SHA and clean production working tree.

No additional concrete production bugs were established. Repository-wide
test/lint/compile and audit regressions were left to the integration owner,
as requested. This finding resets the clean-round sequence; two consecutive
clean reviews are required at the corrected freeze before the final checks.
