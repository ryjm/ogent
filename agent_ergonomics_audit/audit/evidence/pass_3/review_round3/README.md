# Independent round-three evidence

Reviewed production SHA: `3cb0cd721c58c34550c6e01a04bb13f62241ad83`.
`source_sha.txt` and `source_sha_end.txt` agree. Both production-diff files are
empty; audit artifacts were concurrently writable under the review assignment.

All commands below ran from `/workspace/ogent`. Commands loaded the explicit
test helper source first to exclude stale project bytecode and protect stores.
No provider calls or authentication was used.

Focused suites, recorded in the corresponding `focused-ert-30.out` and
`focused-ert-29.out`:

```sh
docker exec -e OGENT_PROCESS_TEST_RG=/tmp/ogent-test-rg ogent-fixes \
  /nix/store/emacs/bin/emacs -Q --batch \
  -l /work/test/ogent-test-helper.el \
  -l /work/test/ogent-agent-execution-tests.el \
  -l /work/test/ogent-tool-process-tests.el \
  -l /work/test/ogent-debug-tests.el \
  --eval '(ert-run-tests-batch-and-exit "ogent-\\(agent-execution\\|tool-process\\|debug\\)")'
```

The Emacs 29 command substitutes container `ogent-fixes-29`. Both completed
with exit 0 and 174 expected results. The containers expose actual ripgrep at
the named path; ordinary GNU and additional selected ripgrep tests run real
subprocesses.

Independent flow probes, recorded separately in `flow-probe-30.stdout` and
`flow-probe-30.stderr` (exit 0):

```sh
docker exec ogent-fixes /nix/store/emacs/bin/emacs -Q --batch \
  -l /work/test/ogent-test-helper.el \
  -l /work/agent_ergonomics_audit/audit/evidence/pass_3/review_round3/flow-probe.el
```

`flow-probe-30.out` preserves an earlier identical run that combined stdout
and stderr; the later separated transcripts are easier to inspect.

Earlier in-place registry-mutation reproduction, recorded separately in
`inplace-registry-fixed.stdout` and `.stderr` (exit 0):

```sh
docker exec ogent-fixes /nix/store/emacs/bin/emacs -Q --batch \
  -l /work/test/ogent-test-helper.el \
  -l /work/agent_ergonomics_audit/audit/evidence/pass_3/review_round2/inplace-registry-probe.el
```

Actual isolated build fixture, recorded in `makem-real-fixture-30.out` (exit 0):

```sh
docker exec -e EMACS=/nix/store/emacs/bin/emacs ogent-fixes \
  bash /work/test/makem-report-tests.sh
```

The tracked script copies the actual runner and Makefile into its own small
Git fixture, compiles actual Lisp and executes actual ERT; it does not run
the repository-wide compile/lint/test targets.
