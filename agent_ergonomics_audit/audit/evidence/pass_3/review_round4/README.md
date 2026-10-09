# Independent round-four evidence

Frozen production SHA: `90818f808bee4f9ff26f84c3f1235e24d469d927`.
`start-sha.txt` and `end-sha.txt` agree. Both production-diff files are empty.
The reviewer wrote only the round-four report and this directory.

All commands ran from `/workspace/ogent`; each completed with exit 0. Source
test helper loading explicitly excludes stale project bytecode and protects
real stores. No provider requests or authentication occurred.

Focused SDK/process/debug suites, each 180/180 expected results:

```sh
docker exec -e OGENT_PROCESS_TEST_RG=/tmp/ogent-test-rg ogent-fixes \
  /nix/store/emacs/bin/emacs -Q --batch \
  -l /work/test/ogent-test-helper.el \
  -l /work/test/ogent-agent-execution-tests.el \
  -l /work/test/ogent-tool-process-tests.el \
  -l /work/test/ogent-debug-tests.el \
  --eval '(ert-run-tests-batch-and-exit "ogent-\\(agent-execution\\|tool-process\\|debug\\)")'
```

The Emacs 29 command substitutes container `ogent-fixes-29`. Transcripts:
`focused-ert-30.out` and `focused-ert-29.out`.

Independent contract and real-engine probes:

```sh
docker exec ogent-fixes /nix/store/emacs/bin/emacs -Q --batch \
  -l /work/test/ogent-test-helper.el \
  -l /work/agent_ergonomics_audit/audit/evidence/pass_3/review_round4/independent-probe.el
```

The Emacs 29 command substitutes `ogent-fixes-29`. Separate stdout/stderr
transcripts are `independent-probe-30.stdout` / `.stderr` and
`independent-probe-29.stdout` / `.stderr`. Both reproduce the two findings.

Earlier independent reproductions rerun at the current freeze:

```sh
docker exec ogent-fixes /nix/store/emacs/bin/emacs -Q --batch \
  -l /work/test/ogent-test-helper.el \
  -l /work/agent_ergonomics_audit/audit/evidence/pass_3/review_round3/flow-probe.el
docker exec ogent-fixes /nix/store/emacs/bin/emacs -Q --batch \
  -l /work/test/ogent-test-helper.el \
  -l /work/agent_ergonomics_audit/audit/evidence/pass_3/review_round2/inplace-registry-probe.el
```

Transcripts are `previous-flow-30.stdout` / `.stderr` and
`previous-registry-30.stdout` / `.stderr`.

Actual compiler/ERT/Make report fixture:

```sh
docker exec -e EMACS=/nix/store/emacs/bin/emacs ogent-fixes \
  make -C /work test-build-report
```

Transcript: `makem-real-fixture-30.out`. The tracked script copies the real
runner and Makefile into an independent small Git fixture and compiles/runs
actual Lisp/ERT there. It does not run repository-wide compile/lint/test.
