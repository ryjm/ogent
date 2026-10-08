# Pass 1 Simulation Summary

Stage: **pre**. Tool: **ogent Emacs Lisp SDK**, Emacs 30.2 in Docker container `ogent-fixes`.

| Task | Status | First-try? | Round-trips | Stuck? | Notes |
|------|--------|------------|-------------|--------|-------|
| task-01 | COMPLETE | NO | 3 | no | Three discovery queries; unknown name returns nil. |
| task-02 | COMPLETE | NO | 3 | no | Advertised recursive glob incomplete; SDK shell workaround. |
| task-03 | COMPLETE | YES | 4 | no | Offsets inferred; trailing numbered blank line; EOF probe. |
| task-04 | COMPLETE | NO | 4 | no | Leading dash fails; errors labeled matches; diagnostics distinguish cases. |
| task-05 | COMPLETE | YES | 2 | no | Unique context safe; explicit all verified. |
| task-06 | COMPLETE | YES | 2 | no | SDK plist-to-JSON; 19 local probes. |
| task-07 | COMPLETE | YES | 1 | no | Integer async exit 1 propagated. |

**Median round-trips:** 3
**Tasks completed:** 7/7
**Tasks where first-try succeeded:** 4/7
**Tasks where I got stuck:** 0/7
**Captured command invocations:** 19 total; 17 Emacs SDK invocations.

**Actual failure counts.** 0 failed tasks; 2 unexpected SDK operation failures (incomplete recursive glob and leading-dash grep option parsing); 2 deliberate negative outcomes (invalid regex and compile syntax error). Of the 19 captured outer command invocations, 1 exited nonzero: the intended compiler failure, propagated as exit 1. No unexpected outer command exited nonzero. The grep errors returned outer exit 0 and are counted as semantic failures rather than silently treated as success. The expected no-match grep child exit 1 is not counted as a failure. Local doctor reported 3 dependency errors and 3 warnings; producing and parsing the requested JSON succeeded.

**Counting method.** Round-trips count every captured command invocation, including mount inspection and the JSON parse validator. SDK-only counts by task are 3, 2, 4, 4, 2, 1, 1, with median 2. First-try means the initial functional strategy completed without correction; normal pagination, the separately requested replace-all operation, and verification are not retries. Discovery did not meet the optional one-query target.

**Evidence.** Each JSONL records exact Docker/timeout/Emacs argv, SDK expression, actual stdout, stderr, outer exit status, timestamps, and duration. The JSONL streams are capped at 4 KiB per stdout/stderr field; adjacent per-step stdout/stderr files preserve complete raw output. Fixtures and probes were written only under this transcript directory. Only the designated simulator instructions, in-tool help/introspection, and this simulator's own captured outputs were read. No source, README, AGENTS.md, audit findings, credentials, provider logins, outbound inference, tracker, production, or test files were accessed or modified.
