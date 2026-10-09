# Phase 7, pass 3: fresh-eyes review round 2

**Result: not clean.** Six concrete correctness findings require production
changes. The integration owner accepted the findings and owns the corrections;
this report does not claim to validate those later corrections.

Review started against `7c0d9d82f53dc0a236d753d17fb201edaefcfd81`. The owner
advanced the active freeze to `895bed7a8446b3a57769ac0dd737bf32c9feea4b` after
a fresh simulator found the batch envelope inconsistency. All probes and tests
reported below loaded an independent archive of **895bed7**, not the changing
working tree. The batch envelope correction is included in that active freeze
and is not counted as a new finding here.

## Scope and method

Read `AGENTS.md`, `specs/style-guide.org`, `specs/architecture.org`,
`specs/gptel-integration.org`, `specs/feature-playbooks.org`, the pass-3 scope
decision, the initial review, and the agent/build interface documentation.
Reviewed production changes since `b3caf9300c7336ef812ed061158f851c5a47ccf7`:
the SDK and schemas, structured file/process results, argument and alias
contracts, registry registration and gptel JSON wrappers, approval integration,
UI ledger/history recording, `makem.sh`, Makefile, README, and CI integration.
Traced the surrounding debug replay, tool policy, process cancellation,
continuation, gptel pending-call, and Armory native execution flows.

Production source and tests were read only. Probes ran with source-loaded
Emacs 30.2 in `ogent-fixes`, after explicitly loading the protected test helper.
Real GNU grep/xargs and real ripgrep 15.2 exercised the search paths. Build
report checks used an independent tracked Git fixture and actual Emacs. No
provider requests, network access, commits, or Beads mutations were performed.

Evidence is under [evidence/pass_3/review_round2](evidence/pass_3/review_round2/).
File/line references below refer to the active frozen source, so subsequent
corrections may move them.

## Concrete findings

1. **P1: in-place registry mutation bypasses the JSON approval snapshot and
   read-only batch preflight.**

   `lisp/ogent-tool-execution.el:136` retains the live registry spec. Its
   post-approval comparison at line 163 compares that same mutable object to
   the current registry entry. During the approval boundary, changing the
   existing plist's function and effects in place therefore remains equal.
   The JSON wrapper's outer copied snapshot is only checked before it enters
   this dispatcher.

   `inplace-registry-probe.el` changes the live function to a replacement and
   adds critical network effects during the approval prompt. The text wrapper
   correctly returns unavailable and does not execute the replacement. The
   JSON wrapper returns status `ok`, value `"in-place replacement ran"`, and
   the replacement execution flag is `t`.

   The batch has the same root cause at `lisp/ogent-agent.el:109`: prepared
   entries retain live specs, and line 113 compares those live references.
   A first declared read fixture changes the second entry from read effects
   and a read function to write effects and a write function. With an existing
   permissive approval policy, the batch executes the write fixture and reports
   `ok`. Batch read-only eligibility is a separate contract from approval.

   Capture genuine metadata snapshots before approval/preflight, preserving
   callable identity, then reject both replacement and in-place mutation
   before dispatch. Evidence: `inplace-registry-probe.el` and `.out`.

2. **P2: an undecodable filename breaks JSON results and suppresses the async
   terminal callback.**

   Create an existing text file with a raw-byte name using
   `(concat directory "/" (unibyte-string 255) ".txt")`. Native
   `(ogent-agent-call "read" (list :file_path file))` succeeds and returns
   exact text, but its `:path` contains an unibyte string which
   `lisp/ogent-agent.el:19` cannot serialize. The JSON call signals
   `(wrong-type-argument json-value-p PATH)` instead of returning a versioned
   error. The corresponding immediate `ogent-agent-call-async` JSON call
   invokes the user's callback **zero times** because serialization fails
   before it reaches that callback.

   Choose an explicit JSON-safe unsupported-output result for undecodable
   filenames, or another exact supported representation; do not silently alter
   the filename. Ensure serialization failures still produce one terminal
   envelope. Structured search already has a deliberate unsupported-filename
   rule. Evidence: `boundary-probe.el` and `.out`.

3. **P2: configuring a smaller file-read maximum makes default structured
   reads fail.**

   `lisp/ogent-tool-results.el:28` always defaults the limit to 200, then
   line 33 rejects that limit if `ogent-tools-max-file-lines` is smaller.
   With a valid configured maximum of 2, a normal named read without `:limit`
   returns `execution_failed` and `"Use a positive limit no larger than 2
   lines"`. The same read with `:limit 2` succeeds and produces a continuation.
   The default should honor a valid smaller configured maximum while retaining
   explicit oversized-limit validation. Evidence: `search-config-probe.el`
   and `.out`.

4. **P2: installing ripgrep changes explicit-file glob-filter results.**

   `lisp/ogent-tool-process.el:262` filters an explicitly named file through
   the GNU candidate-file matcher. Real ripgrep ignores `-g` for explicit file
   arguments. Search a three-line `data.txt` containing `needle` with the
   same pattern, explicit path, and `glob_filter="*.el"`: the GNU fallback
   returns zero matches; real ripgrep returns all three. This is a concrete
   behavior difference in the same public call, not regex-dialect variation.

   Apply one deliberate explicit-file filtering rule in both engines and state
   that rule in the contract. Evidence: `search-config-probe.el` and `.out`.

5. **P2: new structured pagination arguments cannot be replayed from real
   debug history.**

   `lisp/ui/ogent-ui-toolcalls.el:258` records the structured arguments but
   does not retain execution mode. `ogent-debug-replay-tool` at
   `lisp/ogent-debug.el:515` replays through the legacy executor/schema.
   A successful named read with `:column 3` is recorded, then replay returns
   `Tool error: read-file has no argument :column`. Structured glob/search
   `:offset` and `:limit` have the same mismatch.

   Preserve the recorded execution mode and replay through the matching
   approval-aware execution path so pagination and result shape survive.
   Evidence: `history-probe.el` and `.out`.

6. **P2: failed structured shell calls still appear successful in debug
   history.**

   `lisp/ui/ogent-ui-toolcalls.el:272` now computes the process failure for
   the ledger, but line 276 sends an unmodified history-call without `:error`
   to `ogent-debug-log-tool-call`. A real structured shell call `exit 7`
   returns typed `command_failed` and records a failed ledger terminal, but
   its real history entry has `:error nil`. The history UI selects `SUCCESS`
   whenever this field is nil (`lisp/ogent-debug.el:472`).

   Carry the same failure classification into the history entry while retaining
   process data. Evidence: `history-probe.el` and `.out`.

All six findings were reported promptly to the integration owner. Items 1 and
2 affect approval/reliability contracts; the remaining items affect supported
configuration or integration behavior. None is an optional style preference.

## Verification and non-findings

- Frozen-source agent/process ERT suites: **66 tests, 64 expected, zero
  unexpected, two ripgrep availability skips**. GNU fallback ran for those
  ordinary process cases. `focused-ert.out` records the full run.
- Separately supplied actual ripgrep executable: **three tests, three expected,
  zero unexpected**, covering the real JSON protocol and hidden-file behavior.
  See `ripgrep-ert.out`.
- Actual frozen makem report fixture: **all real-runner checks passed**,
  including compilation, ERT failure/success, Make integration, bootstrap
  failures, diagnostics, Unicode, and cancellation. See
  `makem-real-fixture.out`.
- Existing repairs for descendant stderr draining, GNU empty-candidate invalid
  regexes, registry replacement during approval, sync/async failed process
  ledger classification, component-safe recursive globbing, and final-newline
  metadata remain present and pass the focused tests. Item 1 identifies the
  additional in-place mutation case missed by the existing replacement test.
- Stateful structured extension closures completed successive sync and async
  wrapper calls successfully. No copied-closure malfunction was established;
  `closure-probe.el` and `.out` preserve that negative result.
- Binary search behavior differs between GNU and ripgrep in the logged probe.
  It is not counted as a correctness finding here because the text/binary
  scope does not establish a required uniform result in the reviewed contract.
  A deliberately malformed custom structured extension returning scalar data
  is also outside the declared result-object contract and is not counted.

One initial build-fixture attempt accidentally paired the frozen runner with
the owner's newer, in-flight compiler-location tests. Its expected parser
assertion failed; `makem-mixed-test-version.out` preserves that discarded
mixed-version attempt. The passing build result above reran the exact tracked
fixture from 895bed7 and is the applicable frozen-source evidence.

This round requires a new clean review after the accepted corrections. Later
working-tree changes were neither edited nor certified by this reviewer.
