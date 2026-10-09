# Independent round-five evidence

Frozen production SHA: `9ac13b23032f40eccb9a627a824be45656292056`.
`start-sha.txt` and `end-sha.txt` agree. Both production-diff files are empty.
The reviewer wrote only the round-five report and this directory, with no
staging or commits. `container-identity.txt`, `emacs-*-version.txt`, and
`ripgrep-version.txt` preserve runtime provenance.

All commands below ran from `/workspace/ogent`. The helper was explicitly
loaded before project/test sources to exclude stale project bytecode and
protect real stores. There were no provider requests or authentication.
Every final check exited 0; `*.exit` records each status. Full stdout/stderr
is preserved, without truncation. The sole initial nonzero calibration check
is separately identified below.

## Focused suites

```sh
docker exec -e OGENT_PROCESS_TEST_RG=/tmp/ogent-test-rg ogent-fixes \
  /nix/store/emacs/bin/emacs -Q --batch \
  -l /work/test/ogent-test-helper.el \
  -l /work/test/ogent-agent-execution-tests.el \
  -l /work/test/ogent-tool-process-tests.el \
  -l /work/test/ogent-debug-tests.el \
  --eval '(ert-run-tests-batch-and-exit "ogent-\\(agent-execution\\|tool-process\\|debug\\)")'
```

For Emacs 29, substitute `ogent-fixes-29`. The complete transcripts are
`focused-ert-30.out` and `focused-ert-29.out`: each is 188/188 expected,
zero unexpected.

## Independent probes

```sh
docker exec ogent-fixes /nix/store/emacs/bin/emacs -Q --batch \
  -l /work/test/ogent-test-helper.el \
  -l /work/agent_ergonomics_audit/audit/evidence/pass_3/review_round5/independent-probe.el
```

For Emacs 29, substitute `ogent-fixes-29`. Complete separate streams are
`independent-probe-30.stdout` / `.stderr` and
`independent-probe-29.stdout` / `.stderr`. The probe compares every returned
match and context object, verifies all 560 matches across multiple groups
and pages, reassembles Unicode read fragments, and cancels two live local
shell processes through the global process owner.

The initial Emacs 30 invocation used the same search/read probes followed by
the short-search cancellation check preserved in
`cancellation-race-probe.el`. It exited 255 because one search finished
naturally during cancellation of its peer. Its complete original transcript
is retained as `independent-probe-30.race.stdout` / `.stderr` / `.exit`.
That check's assumption that every initially live short search must still be
running by its turn in the cancellation loop was invalid. The final fixture
uses two `printf partial; sleep 10` processes and passes on both runtimes.
`cancellation-race-probe.el` is a manual reproducible check, not part of the
native test/feature discovery; neither manual probe provides a feature.

## Earlier independent reproductions

```sh
docker exec ogent-fixes /nix/store/emacs/bin/emacs -Q --batch \
  -l /work/test/ogent-test-helper.el \
  -l /work/agent_ergonomics_audit/audit/evidence/pass_3/review_round4/independent-probe.el
docker exec ogent-fixes /nix/store/emacs/bin/emacs -Q --batch \
  -l /work/test/ogent-test-helper.el \
  -l /work/agent_ergonomics_audit/audit/evidence/pass_3/review_round3/flow-probe.el
docker exec ogent-fixes /nix/store/emacs/bin/emacs -Q --batch \
  -l /work/test/ogent-test-helper.el \
  -l /work/agent_ergonomics_audit/audit/evidence/pass_3/review_round2/inplace-registry-probe.el
```

Round 4 also ran on `ogent-fixes-29`. Complete stdout/stderr and exits:
`previous-independent-30.*`, `previous-independent-29.*`,
`previous-flow-30.*`, `previous-registry-30.*`.

## Actual build-report fixture

```sh
docker exec -e EMACS=/nix/store/emacs/bin/emacs ogent-fixes \
  make -C /work test-build-report
```

`makem-real-fixture-30.out` and `.exit` preserve the successful result. This
copies the actual runner and Makefile into an independent small tracked Git
fixture and runs real compiler/ERT commands. It does not run full-repository
compile, lint, or tests; the integration owner owns those after the gate.

## Source provenance

```sh
git rev-parse HEAD
git diff -- . ':!agent_ergonomics_audit/**'
git status --short
```

The start/end records preserve these checks. Runtime identity commands:

```sh
docker exec ogent-fixes /nix/store/emacs/bin/emacs --version
docker exec ogent-fixes-29 /nix/store/emacs/bin/emacs --version
docker exec ogent-fixes /tmp/ogent-test-rg --version
docker inspect --format '{{.Name}} {{.Id}} {{.Config.Image}}' ogent-fixes ogent-fixes-29
```
