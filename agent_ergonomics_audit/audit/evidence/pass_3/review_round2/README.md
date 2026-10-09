# Review round 2 evidence

All applicable probes load source archived from
`895bed7a8446b3a57769ac0dd737bf32c9feea4b`. The initial review target was
`7c0d9d82f53dc0a236d753d17fb201edaefcfd81`; the owner advanced the active
freeze before these probes ran.

The source archive was extracted into `/tmp/ogent-review-round2-source` and
copied into the `ogent-fixes` container. Reproduce its construction with:

```sh
mkdir -p /tmp/ogent-review-round2-source
git archive 895bed7a8446b3a57769ac0dd737bf32c9feea4b \
  lisp test/ogent-test-helper.el test/ogent-agent-execution-tests.el \
  test/ogent-tool-process-tests.el test/makem-report-tests.sh makem.sh Makefile \
  | tar -x -C /tmp/ogent-review-round2-source
docker cp /tmp/ogent-review-round2-source ogent-fixes:/tmp/ogent-review-round2-source
```

For each probe file in this directory, use actual protected source Emacs:

```sh
docker exec ogent-fixes /nix/store/emacs/bin/emacs -Q --batch \
  -l /tmp/ogent-review-round2-source/test/ogent-test-helper.el \
  -l /work/agent_ergonomics_audit/audit/evidence/pass_3/review_round2/inplace-registry-probe.el
```

`search-config-probe.el` additionally expects actual ripgrep 15.2 at
`/tmp/ogent-review-bin/rg`, which was already available in the review container.
Its executable lookup override only selects the actual engine; grep, xargs,
process execution, output parsing, and the SDK remain real.

Focused GNU-path suite command:

```sh
docker exec ogent-fixes /nix/store/emacs/bin/emacs -Q --batch \
  -l /tmp/ogent-review-round2-source/test/ogent-test-helper.el \
  -l /tmp/ogent-review-round2-source/test/ogent-agent-execution-tests.el \
  -l /tmp/ogent-review-round2-source/test/ogent-tool-process-tests.el \
  --eval '(ert-run-tests-batch-and-exit "ogent-\\(agent-execution\\|tool-process\\)")'
```

Real ripgrep-focused command:

```sh
docker exec -e OGENT_PROCESS_TEST_RG=/tmp/ogent-review-bin/rg ogent-fixes \
  /nix/store/emacs/bin/emacs -Q --batch \
  -l /tmp/ogent-review-round2-source/test/ogent-test-helper.el \
  -l /tmp/ogent-review-round2-source/test/ogent-tool-process-tests.el \
  --eval '(ert-run-tests-batch-and-exit "ogent-tool-process-ripgrep")'
```

Actual independent build fixture:

```sh
docker exec -e EMACS=/nix/store/emacs/bin/emacs ogent-fixes \
  bash /tmp/ogent-review-round2-source/test/makem-report-tests.sh
```

Every `.out` corresponds to its adjacent probe, except the three named suite
logs. `makem-mixed-test-version.out` is a discarded attempt using a newer test
script with the frozen runner; it is explicitly excluded from validation.
